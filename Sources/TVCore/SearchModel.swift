import Foundation
import Perception

@MainActor @Perceptible public final class SearchModel {
    public var draft = ""
    public var selectedSource: String? { didSet { cardsInvalid = true } }
    public var results: [SearchSourceResult] = [] { didSet { invalidateResults() } }
    public var busy = false
    public var completed = 0
    public var total = 0
    public var keyword = ""
    public var stopped = false
    /// A quick search stops presenting immediately, even if a runtime still holds its
    /// admission permit while cancellation finishes.
    public private(set) var deadlineReached = false
    /// Kept for older result views. Health cooldowns no longer omit searchable sources.
    public private(set) var paused: [Site] = []
    /// Keys of the sources this search asks: searchable and selected by the active settings.
    public private(set) var asking: Set<String> = []
    /// Paused because the viewer left the results, not by Stop; `resumeSuspended` continues it.
    public private(set) var suspended = false
    /// A restoration bookmark, not presentation state. iOS 16 writes it as visible
    /// card geometry changes; observing those writes redraws the whole result page.
    /// Source/group/query changes already request scrolling explicitly in the view.
    @PerceptionIgnored public var scrollID: String?
    /// Later result pages, in the order they arrived, so the grid only ever grows at its end.
    public private(set) var batches: [SearchBatch] = [] { didSet { invalidateResults() } }
    public private(set) var loadingMore = false
    /// A failed later page is retryable and never consumes its page number.
    public private(set) var pageErrors: [String: String] = [:]
    public private(set) var groups: [LocalSearchPreferences.Group] = [] { didSet { groupsInvalid = true; cardsInvalid = true } }
    public private(set) var selectedGroup: String? { didSet { invalidateResults() } }
    private var runSites: [Site] = []
    /// The next page to ask each source for; `Int.max` once a source has no more.
    private var nextPage: [String: Int] = [:]
    private var lastPagedSource: String?
    private(set) var moreTask: Task<Void, Never>?
    private var pageGeneration = UUID()
    private var resultsVisible = true
    /// Changes only with a new search, unlike `generation`, which pausing also changes.
    private var runID = UUID()
    /// When the current run began and how many sources were already done, for a time estimate.
    public private(set) var runStart: (date: Date, completed: Int)?
    private var generation = UUID()
    private(set) var task: Task<Void, Never>?
    @PerceptionIgnored private var deadlineTask: Task<Void, Never>?
    @PerceptionIgnored private var deadline: ContinuousClock.Instant?
    @PerceptionIgnored private var runPreferences = LocalSearchPreferences()
    @PerceptionIgnored private var includesManga = true
    @PerceptionIgnored private var runCacheKey = ""
    @PerceptionIgnored private var mangaNext: [String: MangaCursor] = [:]
    @PerceptionIgnored private var laterComics: [String: [MangaComic]] = [:]
    @PerceptionIgnored private var pageFingerprints: [String: String] = [:]
    @PerceptionIgnored private var arrivalPages: [SearchBatch] = []
    @PerceptionIgnored private var retainedCost = SearchResultCache.Cost()
    @PerceptionIgnored private var firstPageCost = SearchResultCache.Cost()
    @PerceptionIgnored private var sourceCosts: [String: SearchResultCache.Cost] = [:]
    @PerceptionIgnored private var receivedSources: Set<String> = []
    @PerceptionIgnored private var exceededResultBudget = false
    private static let maximumResultBytes = 32 << 20
    private static let maximumResultItems = 24_000

    private let http: HTTPClient
    @PerceptionIgnored private var cache = SearchResultCache()
    private struct CatalogIdentity: Equatable {
        let origin: URL
        let imported: Date
        let spider: URL?
        let sites: [Site]
        let manga: [Site]
        static func == (left: Self, right: Self) -> Bool {
            guard left.origin == right.origin, left.imported == right.imported, left.spider == right.spider else { return false }
            func same(_ left: [Site], _ right: [Site]) -> Bool {
                guard left.count == right.count else { return false }
                return zip(left, right).allSatisfy { lhs, rhs in
                    lhs.key == rhs.key && lhs.name == rhs.name && lhs.api == rhs.api && lhs.type == rhs.type
                        && lhs.provenance == rhs.provenance && lhs.detectedRuntime == rhs.detectedRuntime && lhs.raw == rhs.raw
                }
            }
            return same(left.sites, right.sites) && same(left.manga, right.manga)
        }
    }
    @PerceptionIgnored private var subscriptionID: CatalogIdentity?
    /// Each source's position in the settings list (group order followed by settings
    /// order within a group). Runtime warmth never changes this rank.
    private var rank: [String: Int] = [:] { didSet { invalidateResults() } }
    @PerceptionIgnored private var resultIndexInvalid = true
    @PerceptionIgnored private var groupsInvalid = true
    @PerceptionIgnored private var cardsInvalid = true
    @PerceptionIgnored private var orderedMatches: [SearchSourceResult] = []
    @PerceptionIgnored private var errorResults: [SearchSourceResult] = []
    @PerceptionIgnored private var sourceVideos: [String: [Video]] = [:]
    @PerceptionIgnored private var sourceCounts: [String: Int] = [:]
    @PerceptionIgnored private var sourceComics: [String: [MangaComic]] = [:]
    @PerceptionIgnored private var groupMembers: [String: Set<String>] = [:]
    @PerceptionIgnored private var visibleCards: [SearchVideoResult] = []
    @PerceptionIgnored private var pendingResults: [SearchSourceResult] = []
    @PerceptionIgnored private var publicationTask: Task<Void, Never>?
    private var excluded: @MainActor (Site) -> Bool = { _ in false }
    /// Kept for older callers; search follows the catalog shown in search settings.
    public var order: SourceOrder?
    /// Store supplies its current enabled catalog, so a retained results page cannot restart an
    /// older source list after subscription/Python changes. Nil keeps standalone model callers.
    public var currentCatalog: (@MainActor () -> Subscription?)?
    public init(http: HTTPClient = HTTPClient()) { self.http = http }

    private func catalog(_ proposed: Subscription) -> Subscription? {
        let current: Subscription?
        if let currentCatalog { current = currentCatalog() } else { current = proposed }
        #if os(iOS)
        return current.map(LocalEditionPolicy.importedCatalog)
        #else
        return current
        #endif
    }

    /// Source keys can be reused after a subscription update, and importedAt may remain the
    /// timestamp of another enabled source. Include provenance and execution data in the cache.
    private static func identity(_ config: Subscription, includeManga: Bool) -> CatalogIdentity {
        // Dictionary equality retains a cheap shared-storage fast path. Compare execution
        // metadata explicitly: Site's presentation equality intentionally omits provenance.
        // No plugin raw configuration is serialized on search/page/resume.
        CatalogIdentity(origin: config.origin, imported: config.importedAt, spider: config.spiderURL,
                        sites: config.sites, manga: includeManga ? LocalSearchManga.sites : [])
    }

    private func invalidateResults() { resultIndexInvalid = true; cardsInvalid = true }

    /// Observe the original collections while retaining derived arrays between UI reads.
    /// A 400-source run used to sort and scan every source again for each counter and card.
    private func indexResults() {
        _ = results; _ = batches; _ = rank; _ = selectedGroup
        guard resultIndexInvalid else { return }
        resultIndexInvalid = false
        errorResults = results.filter { $0.error != nil }
        let matches = results.filter { $0.page?.videos.isEmpty == false }
        let shownRank = selectedGroup.flatMap { id in groups.first { $0.id == id } }
            .map { Dictionary($0.siteIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: min) } ?? rank
        orderedMatches = runPreferences.resultOrder == .arrival ? matches : matches.enumerated().sorted { lhs, rhs in
            let left = shownRank[lhs.element.id] ?? .max, right = shownRank[rhs.element.id] ?? .max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
        sourceVideos = Dictionary(results.map { ($0.id, $0.page?.videos ?? []) }, uniquingKeysWith: { first, _ in first })
        for batch in batches { sourceVideos[batch.source, default: []].append(contentsOf: batch.videos) }
        sourceCounts = sourceVideos.mapValues { Set($0.map(\.id)).count }
        sourceComics = Dictionary(results.compactMap { result in result.mangaPage.map { (result.id, $0.comics) } }, uniquingKeysWith: { first, _ in first })
        for (source, comics) in laterComics { sourceComics[source, default: []].append(contentsOf: comics) }
    }
    private func indexGroups() {
        _ = groups
        guard groupsInvalid else { return }
        groupsInvalid = false
        groupMembers = Dictionary(groups.map { ($0.id, Set($0.siteIDs)) }, uniquingKeysWith: { first, _ in first })
    }
    public var failures: [SearchSourceResult] { indexResults(); return errorResults }
    public var matches: [SearchSourceResult] { indexResults(); return orderedMatches }

    /// The All Sources choice is the current group's total, even while one source is selected.
    public var videoCount: Int {
        indexResults(); indexGroups()
        return orderedMatches.filter { includesInSelectedGroup($0.id) }.reduce(0) { $0 + sourceCounts[$1.id, default: 0] }
    }
    public func videoCount(for source: String) -> Int { indexResults(); return sourceCounts[source, default: 0] }
    public func videos(for source: String) -> [Video] { indexResults(); return sourceVideos[source] ?? [] }
    public func isManga(sourceKey: String) -> Bool { runSites.contains { $0.id == sourceKey && LocalSearchManga.key(for: $0) != nil } }
    public func comic(for item: SearchVideoResult) -> MangaComic? {
        indexResults()
        return sourceComics[item.site.id]?.first { $0.id == item.video.id }
    }

    /// Default mode keeps each source in settings order; arrival mode appends every page.
    /// Repeated view reads
    /// share this array until a result, filter, group, rank or later page actually changes.
    public var items: [SearchVideoResult] {
        indexResults(); indexGroups(); _ = selectedSource; _ = selectedGroup
        guard cardsInvalid else { return visibleCards }
        cardsInvalid = false
        let shown = orderedMatches.filter { includesInSelectedGroup($0.id) && (selectedSource == nil || $0.id == selectedSource) }
        let sites = Dictionary(shown.map { ($0.id, $0.site) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        visibleCards = []
        func append(_ site: Site, _ videos: [Video]) {
            for video in videos {
                let item = SearchVideoResult(site: site, video: video)
                if seen.insert(item.id).inserted { visibleCards.append(item) }
            }
        }
        if runPreferences.resultOrder == .arrival {
            for batch in arrivalPages { if let site = sites[batch.source] { append(site, batch.videos) } }
        } else {
            for result in shown { append(result.site, sourceVideos[result.id] ?? []) }
        }
        return visibleCards
    }

    /// Shows one source's results (nil: every source). New queries always start at All.
    public func select(_ source: String?) {
        selectedSource = source; scrollID = nil
    }
    public func selectGroup(_ id: String?) { selectedGroup = id; selectedSource = nil; scrollID = nil }
    public func includesInSelectedGroup(_ source: String) -> Bool {
        guard let selectedGroup else { return true }
        indexGroups()
        return groupMembers[selectedGroup]?.contains(source) == true
    }
    public var visiblePageErrors: [String: String] {
        pageErrors.filter { includesInSelectedGroup($0.key) && (selectedSource == nil || selectedSource == $0.key) }
    }

    private func paginationCandidates(_ source: String?, excludingFailed: Bool) -> [SearchSourceResult] {
        matches.filter {
            includesInSelectedGroup($0.id) && (source == nil || source == $0.id)
                && (!excludingFailed || pageErrors[$0.id] == nil)
        }
    }

    /// Whether a source (nil: any matching source) has another page of results.
    public func canLoadMore(_ source: String?, excludingFailed: Bool = false) -> Bool {
        let candidates = paginationCandidates(source, excludingFailed: excludingFailed)
        return candidates.contains { hasNextPage($0) }
    }
    private func hasNextPage(_ result: SearchSourceResult) -> Bool {
        if LocalSearchManga.key(for: result.site) != nil { return mangaNext[result.id] != nil }
        return (nextPage[result.id] ?? 2) <= (result.page?.pageCount ?? 1)
    }

    /// Fetches the next page of a source (nil: of every matching source that has one) and appends
    /// what is new; a source that answers nothing new is done.
    public func loadMore(_ source: String?, config: Subscription, excludingFailed: Bool = false) {
        guard resultsVisible, !loadingMore, !suspended, !keyword.isEmpty else { return }
        guard let config = catalog(config) else { reset(); return }
        if subscriptionID != Self.identity(config, includeManga: includesManga) {
            restart(config: config)
            return
        }
        let targets = paginationCandidates(source, excludingFailed: excludingFailed)
            .filter { hasNextPage($0) }
        guard !targets.isEmpty else { return }
        let scheduled: [SearchSourceResult]
        if source == nil, let last = lastPagedSource, let index = targets.firstIndex(where: { $0.id == last }) {
            scheduled = Array((Array(targets.dropFirst(index + 1)) + targets.prefix(index + 1)).prefix(6))
        } else { scheduled = Array(targets.prefix(6)) }
        loadingMore = true
        let run = runID, pageToken = pageGeneration, keyword = keyword, http = http, keywordMode = runPreferences.keywordMode
        moreTask = Task {
            // Pagination is one queue, not a second burst of six plugin requests.
            for result in scheduled {
                guard !Task.isCancelled, self.pageGeneration == pageToken else { break }
                let page = self.nextPage[result.id] ?? 2
                let response: SearchSourceResult
                if LocalSearchManga.key(for: result.site) != nil {
                    let cursor = self.mangaNext[result.id]
                    do {
                        response = try await GlobalSearch.withAdmission(site: result.site) {
                            await LocalSearchManga.page(site: result.site, keyword: keyword, cursor: cursor)
                        }
                    } catch { response = SearchSourceResult(site: result.site, page: nil, error: error.localizedDescription) }
                } else {
                    response = await GlobalSearch.page(site: result.site, origin: config.origin, jarURL: config.spiderURL,
                                                      query: keyword, page: page, http: http)
                }
                guard !Task.isCancelled, self.runID == run, self.pageGeneration == pageToken else { break }
                if source == nil { self.lastPagedSource = result.id }
                guard let answer = response.page else {
                    self.pageErrors[result.id] = response.error ?? "站点下一页没有返回结果，可重试。"
                    continue
                }
                let processed = await Task.detached(priority: .userInitiated) {
                    let filtered = SearchResultPolicy.filtered(response, keyword: keyword, mode: keywordMode)
                    return (filtered, SearchResultCache.cost([filtered]))
                }.value
                let filtered = processed.0
                guard !Task.isCancelled, self.runID == run, self.pageGeneration == pageToken else { break }
                let known = Set(self.videos(for: result.id).map(\.id))
                var seen = known
                let fresh = (filtered.page?.videos ?? []).filter { seen.insert($0.id).inserted }
                guard self.reserve(processed.1) else {
                    self.pageErrors[result.id] = "搜索结果已达到内存上限，可缩小关键词或选择单个站点后重试。"
                    self.nextPage[result.id] = Int.max; self.mangaNext[result.id] = nil
                    continue
                }
                let fingerprint = Self.fingerprint(answer.videos)
                let repeated = self.pageFingerprints[result.id] == fingerprint
                self.pageFingerprints[result.id] = fingerprint
                self.pageErrors[result.id] = nil
                self.nextPage[result.id] = answer.videos.isEmpty || repeated ? Int.max : page + 1
                if let manga = filtered.mangaPage {
                    let current = self.mangaNext[result.id]
                    self.mangaNext[result.id] = repeated || manga.next == current ? nil : manga.next
                    let freshIDs = Set(fresh.map(\.id))
                    self.laterComics[result.id, default: []].append(contentsOf: manga.comics.filter { freshIDs.contains($0.id) })
                }
                if !fresh.isEmpty {
                    let batch = SearchBatch(source: result.id, page: page, videos: fresh)
                    self.arrivalPages.append(batch)
                    self.batches.append(batch)
                }
            }
            if self.runID == run, self.pageGeneration == pageToken {
                self.loadingMore = false; self.moreTask = nil
            }
        }
    }

    private func cancelPages() {
        pageGeneration = UUID()
        moreTask?.cancel(); moreTask = nil; loadingMore = false
    }

    private func clearPages() {
        cancelPages()
        batches = []; nextPage = [:]; lastPagedSource = nil; pageErrors = [:]; loadingMore = false; runID = UUID()
        mangaNext = [:]; laterComics = [:]; pageFingerprints = [:]; arrivalPages = []
        retainedCost = .init(); firstPageCost = .init()
        sourceCosts = [:]; receivedSources = []; exceededResultBudget = false
    }

    public func stop() {
        flushResults(token: generation)
        publicationTask?.cancel(); publicationTask = nil
        pendingResults.removeAll(keepingCapacity: true)
        deadlineTask?.cancel(); deadlineTask = nil
        generation = UUID()
        task?.cancel(); task = nil
        cancelPages()
        stopped = stopped || busy; busy = false
        suspended = false
    }

    /// Pauses a running search while the viewer is on another page (a result's detail, another
    /// section), so its plugin calls stop competing with what they are looking at. Sources that
    /// already answered keep their results; the rest run again on `resumeSuspended`.
    public func suspend() {
        resultsVisible = false
        let unfinished = busy || suspended
        let wasStopped = stopped
        stop()
        stopped = wasStopped || unfinished
        suspended = unfinished
    }

    public func resumeSuspended(config: Subscription) {
        guard let config = catalog(config) else { reset(); return }
        if subscriptionID != Self.identity(config, includeManga: includesManga) {
            restart(config: config)
            return
        }
        resultsVisible = true
        guard suspended else { return }
        suspended = false
        resume(config: config)
    }

    public func reset() {
        stop()
        draft = ""; keyword = ""; results = []; completed = 0; total = 0; paused = []; asking = []
        selectedSource = nil; selectedGroup = nil; groups = []; runSites = []; scrollID = nil; stopped = false
        clearPages()
        cache.removeAll(); subscriptionID = nil
        deadline = nil; deadlineReached = false; runCacheKey = ""
        excluded = { _ in false }
    }

    public static func eligible(_ sites: [Site], jarURL: URL?, excluding hidden: (Site) -> Bool) -> [Site] {
        var seen = Set<String>()
        return sites.filter { $0.searchable && $0.canBrowse(jarURL: jarURL) && !hidden($0) && seen.insert($0.id).inserted }
    }

    public static func visible(_ results: [SearchSourceResult], excluding hidden: (Site) -> Bool) -> [SearchSourceResult] {
        results.filter { !hidden($0.site) }
    }

    public func search(_ query: String, config: Subscription, preferences: LocalSearchPreferences? = nil,
                       excluding hidden: @escaping @MainActor (Site) -> Bool = { _ in false },
                       deadlineSeconds: Double? = nil, includeManga: Bool = true) {
        let began = ContinuousClock.now
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard let config = catalog(config) else { reset(); return }
        let identity = Self.identity(config, includeManga: includeManga)
        if subscriptionID != identity { reset(); subscriptionID = identity }
        let preferences = preferences ?? LocalSearchPreferences.load(config: config)
        let effectiveHidden: @MainActor (Site) -> Bool
        if preferences.mode == .default { effectiveHidden = hidden }
        else { effectiveHidden = { _ in false } }
        excluded = effectiveHidden
        stop()
        resultsVisible = true
        runPreferences = preferences; includesManga = includeManga
        deadlineReached = false
        deadline = deadlineSeconds.flatMap { $0.isFinite ? began.advanced(by: .seconds(max(0, $0))) : nil }
        keyword = value; draft = value; results = []; completed = 0
        clearPages()
        let catalogSites = config.sites + (includeManga ? LocalSearchManga.sites : [])
        runSites = preferences.sites(from: catalogSites)
        groups = preferences.mode == .groups ? preferences.resolvedGroups(sites: catalogSites)
            : [.init(id: preferences.mode.rawValue, name: preferences.mode.title, siteIDs: runSites.map(\.id))]
        selectedGroup = nil; selectedSource = nil; scrollID = nil
        let sites = Self.eligible(runSites, jarURL: config.spiderURL, excluding: effectiveHidden)
        // A health cooldown shortens the transport deadline; it must not omit a source
        // from an All search or make completion appear faster by hiding unfinished work.
        paused = []
        asking = Set(sites.map(\.id))
        rank = Dictionary(sites.enumerated().map { ($1.id, $0) }, uniquingKeysWith: min)
        total = sites.count
        let parts = [value, preferences.mode.rawValue, preferences.resultOrder.rawValue, preferences.keywordMode.rawValue] + sites.map(\.id)
        runCacheKey = (try? JSONEncoder().encode(parts)).map(PluginChecksum.sha256) ?? value
        if let hit = cache.value(for: runCacheKey) {
            results = Self.visible(hit, excluding: effectiveHidden).filter { asking.contains($0.id) }
            for result in results { recordFirstPage(result) }
            firstPageCost = cache.cost(for: runCacheKey); retainedCost = firstPageCost
            sourceCosts = cache.sourceCosts(for: runCacheKey)
            receivedSources = Set(results.map(\.id))
            completed = results.count
            stopped = false
            let answered = Set(results.map(\.id))
            run(sites.filter { !answered.contains($0.id) }, config: config)
            return
        }
        run(sites, config: config)
    }

    public func resume(config: Subscription, retryFailures: Bool = false) {
        guard let config = catalog(config) else { reset(); return }
        if subscriptionID != Self.identity(config, includeManga: includesManga) {
            restart(config: config)
            return
        }
        guard !busy, !keyword.isEmpty else { return }
        let finished = Set(results.map(\.id))
        let failed = Set(failures.map(\.id))
        let sites = Self.eligible(runSites, jarURL: config.spiderURL, excluding: excluded).filter {
            retryFailures ? failed.contains($0.id) : !finished.contains($0.id)
        }
        if retryFailures {
            for source in failed {
                let removed = sourceCosts.removeValue(forKey: source) ?? .init()
                firstPageCost = firstPageCost - removed; retainedCost = retainedCost - removed
                receivedSources.remove(source)
            }
            results.removeAll { failed.contains($0.id) }; completed = results.count
        }
        asking.formUnion(sites.map(\.key))
        run(sites, config: config, retryFailures: retryFailures)
    }

    private func run(_ sites: [Site], config: Subscription, retryFailures: Bool = false) {
        let token = generation
        let keyword = keyword, keywordMode = runPreferences.keywordMode, http = http
        stopped = false; busy = !sites.isEmpty
        guard busy else { return }
        if let deadline {
            guard ContinuousClock.now < deadline else { expire(token: token); return }
            deadlineTask = Task { [weak self] in
                do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                guard !Task.isCancelled else { return }
                self?.expire(token: token)
            }
        }
        runStart = (Date(), completed)
        task = Task {
            guard self.generation == token else { return }
            await GlobalSearch.search(sites: sites, origin: config.origin, jarURL: config.spiderURL, query: keyword,
                                      http: self.http, retryFailures: retryFailures, customSearch: { site in
                guard LocalSearchManga.key(for: site) != nil else { return nil }
                return await LocalSearchManga.firstPage(site: site, keyword: keyword)
            }) { result in
                // Filtering runs on the response task before any state, cache or UI sees it.
                let filtered = await SearchResultPolicy.firstMatch(result, keyword: keyword, mode: keywordMode, config: config, http: http)
                let cost = SearchResultCache.cost([filtered])
                await self.receive(filtered, cost: cost, token: token)
            }
            guard self.generation == token else { return }
            self.flushResults(token: token)
            self.busy = false; self.task = nil
            self.deadlineTask?.cancel(); self.deadlineTask = nil
            if self.completed == self.total && !self.exceededResultBudget {
                self.cache.insert(self.results, for: self.runCacheKey, cost: self.firstPageCost, sourceCosts: self.sourceCosts)
            }
        }
    }

    private func restart(config: Subscription) {
        guard !keyword.isEmpty else { reset(); return }
        let remaining = deadline.map { ContinuousClock.now.duration(to: $0).seconds }
        search(keyword, config: config, preferences: runPreferences, excluding: excluded,
               deadlineSeconds: remaining, includeManga: includesManga)
    }
    private func expire(token: UUID) {
        guard generation == token, busy else { return }
        stop()
        deadlineReached = true
    }
    private static func fingerprint(_ videos: [Video]) -> String {
        PluginChecksum.sha256((try? JSONEncoder().encode(videos.map(\.id))) ?? Data())
    }
    private func recordFirstPage(_ result: SearchSourceResult) {
        if let page = result.page {
            arrivalPages.append(SearchBatch(source: result.id, page: result.pageNumber, videos: page.videos))
            pageFingerprints[result.id] = result.unfilteredPageFingerprint ?? Self.fingerprint(page.videos)
            nextPage[result.id] = result.pageNumber + 1
        }
        mangaNext[result.id] = result.mangaPage?.next
    }

    private func reserve(_ cost: SearchResultCache.Cost) -> Bool {
        let next = retainedCost + cost
        guard next.bytes <= Self.maximumResultBytes, next.items <= Self.maximumResultItems else { return false }
        retainedCost = next
        return true
    }
    private func receive(_ result: SearchSourceResult, cost: SearchResultCache.Cost, token: UUID) {
        guard generation == token, receivedSources.insert(result.id).inserted else { return }
        if reserve(cost) {
            pendingResults.append(result); firstPageCost = firstPageCost + cost; sourceCosts[result.id] = cost
        }
        else {
            exceededResultBudget = true
            pendingResults.append(SearchSourceResult(site: result.site, page: nil,
                                                     error: "搜索结果已达到内存上限，可缩小关键词或单独搜索该站点。"))
        }
        if results.isEmpty || (matches.isEmpty && result.page?.videos.isEmpty == false) { flushResults(token: token); return }
        guard publicationTask == nil else { return }
        publicationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.publicationTask = nil
            self.flushResults(token: token)
        }
    }
    private func flushResults(token: UUID) {
        guard generation == token, !pendingResults.isEmpty else { return }
        publicationTask?.cancel(); publicationTask = nil
        var seen = Set(results.map(\.id))
        let pending = pendingResults.filter { seen.insert($0.id).inserted }
        pendingResults.removeAll(keepingCapacity: true)
        for result in pending { recordFirstPage(result) }
        results.append(contentsOf: pending)
        completed += pending.count
    }
}
