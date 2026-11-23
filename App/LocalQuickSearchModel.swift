import Foundation
import Perception
import TVCore

/// One page owns one search and at most one actual catalog request. A replacement
/// waits for the previous native call to release its admission permit.
@MainActor @Perceptible final class LocalQuickSearchModel {
    struct ResourceGroup: Identifiable, Sendable {
        let selection: SearchVideoResult
        var videos: [Video] = []
        var page = 0
        var pageCount = 1
        var loaded = false
        var hasMore = false
        var id: String { selection.id }
    }

    let search = SearchModel()
    /// SearchModel.matches follows global search settings; these tabs keep the
    /// raw first-result arrival order, including multiple arrivals in one update.
    private(set) var sources: [SearchSourceResult] = []
    private(set) var selectedSourceID: String?
    private(set) var selected: SearchVideoResult?
    private(set) var groups: [ResourceGroup] = []
    private(set) var detail: Video?
    private(set) var selectedFlag: String?
    private(set) var flags: [String] = []
    private(set) var episodes: [Episode] = []
    private(set) var loadingDetail = false
    private(set) var detailError: String?
    private(set) var resourceNotice: String?
    private(set) var deadlineReached = false
    private(set) var selectionRevision = UUID()
    @PerceptionIgnored private var config: Subscription?
    @PerceptionIgnored private var allowsAutomaticSelection = false
    @PerceptionIgnored private var receivedSources = Set<String>()
    @PerceptionIgnored private var generation = UUID()
    @PerceptionIgnored private var pending: Request?
    @PerceptionIgnored private var retryRequest: Request?
    @PerceptionIgnored private var detailWorker: Task<Void, Never>?
    @PerceptionIgnored private var operation: Task<Answer, Error>?
    @PerceptionIgnored private var deadlineTask: Task<Void, Never>?
    @PerceptionIgnored private var expiredRequest: UUID?
    @PerceptionIgnored private var searchDeadline: ContinuousClock.Instant?
    @PerceptionIgnored private var searchDeadlineTask: Task<Void, Never>?
    private(set) var hasOutstandingDetailWork = false

    private struct Request: Sendable {
        let selection: SearchVideoResult
        /// nil is a title detail; a number is this folder's category page.
        let page: Int?
    }
    private enum Answer: Sendable { case detail(Video), resources(CatalogPage) }
    private static let maximumDepth = 8
    private static let maximumResources = 1_000
    private static let maximumResourceBytes = 8 << 20

    var rootSelectionID: String? { groups.first?.selection.id ?? selected?.id }
    var canGoBack: Bool { !groups.isEmpty }

    func start(_ query: String, config: Subscription,
               excluding hidden: @escaping @MainActor (Site) -> Bool = { _ in false }) {
        reset()
        self.config = config
        allowsAutomaticSelection = true
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        searchDeadline = deadline
        search.search(query, config: config, excluding: hidden, deadlineSeconds: 15, includeManga: false)
        reconcile()
        searchDeadlineTask = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            guard let self, !Task.isCancelled else { return }
            if self.search.busy || self.loadingDetail {
                self.deadlineReached = true
                self.search.stop()
                self.reconcile()
                self.expireDetails()
            }
            self.searchDeadlineTask = nil
        }
    }

    /// Runs on the containing page even when the result section is below the viewport.
    func reconcile() {
        for result in search.results where result.page?.videos.isEmpty == false {
            if receivedSources.insert(result.id).inserted { sources.append(result) }
        }
        guard allowsAutomaticSelection, !deadlineReached, !search.deadlineReached, selectedSourceID == nil,
              let result = sources.first, let video = result.page?.videos.first else { return }
        choose(SearchVideoResult(site: result.site, video: video))
    }

    func chooseSource(_ source: String) {
        guard selectedSourceID != source || selected == nil,
              let result = sources.first(where: { $0.id == source }),
              let video = result.page?.videos.first else { return }
        choose(SearchVideoResult(site: result.site, video: video))
    }

    /// Selects a card from the root search results. Child cards use chooseChild.
    func choose(_ value: SearchVideoResult) {
        if selected?.id == value.id {
            if loadingDetail || detail != nil { return }
            if let retryRequest { begin(retryRequest); return }
            if groups.last?.id == value.id, groups.last?.loaded == true { return }
        }
        cancelDetails()
        selectedSourceID = value.site.id; selected = value; groups = []
        clearDetail()
        open(value)
    }

    func chooseChild(_ video: Video) {
        guard let group = groups.last, group.videos.contains(where: { $0.id == video.id }) else { return }
        let value = SearchVideoResult(site: group.selection.site, video: video)
        if selected?.id == value.id, loadingDetail || detail != nil { return }
        guard allowsOpening(value) else { return }
        cancelDetails()
        selected = value
        clearDetail()
        open(value)
    }

    /// Returning from a title keeps its loaded parent cards. Returning from a
    /// group pops one frame and never starts an implicit recursive traversal.
    func goBack() {
        guard let last = groups.last else { return }
        selectionRevision = UUID()
        let wasGroup = selected?.id == last.id
        cancelDetails(); clearDetail()
        if wasGroup { groups.removeLast() }
        if let parent = groups.last {
            selected = parent.selection
            if !parent.loaded { begin(Request(selection: parent.selection, page: 1)) }
        }
        else { selected = nil }
    }

    func loadMoreResources() {
        guard !loadingDetail, let group = groups.last, group.loaded, group.hasMore else { return }
        selected = group.selection
        begin(Request(selection: group.selection, page: group.page + 1))
    }

    func retry() {
        if let retryRequest { begin(retryRequest) }
        else if let selected { open(selected) }
    }

    func selectFlag(_ flag: String) {
        guard flags.contains(flag) else { return }
        selectedFlag = flag
        episodes = detail?.episodes.filter { $0.flag == flag } ?? []
    }

    func stop() {
        allowsAutomaticSelection = false
        searchDeadlineTask?.cancel(); searchDeadlineTask = nil; searchDeadline = nil
        search.stop()
        if loadingDetail, detail == nil { detailError = "资源读取已暂停，可重试或选择其它资源。" }
        cancelDetails()
    }

    /// Catalog changes invalidate retained presentation as well as the network
    /// search, even when the page is inactive or no subscription remains.
    func reset() {
        stop(); search.reset()
        config = nil; selectionRevision = UUID()
        sources = []; receivedSources = []
        selectedSourceID = nil; selected = nil; groups = []
        clearDetail(); deadlineReached = false
    }

    func expireDetails() {
        deadlineReached = true
        reconcile()
        guard loadingDetail else { return }
        cancelDetails()
        detailError = "资源搜索已达到 15 秒，已保留找到的资源；可选择资源继续读取。"
    }

    private func clearDetail() {
        detail = nil; selectedFlag = nil; flags = []; episodes = []
        detailError = nil; resourceNotice = nil; retryRequest = nil
    }

    private func allowsOpening(_ value: SearchVideoResult) -> Bool {
        guard value.video.isFolder else { return true }
        guard groups.count < Self.maximumDepth else {
            resourceNotice = "分类层级过多，请返回上一级选择其它资源。"; return false
        }
        guard !groups.contains(where: {
            $0.selection.site.id == value.site.id && $0.selection.video.folderCategoryID == value.video.folderCategoryID
                && $0.selection.video.folderFilters == value.video.folderFilters
        }) else {
            resourceNotice = "这个分类指向已打开的分类，请选择其它资源。"; return false
        }
        return true
    }

    private func open(_ value: SearchVideoResult) {
        if value.video.isFolder {
            guard allowsOpening(value) else { return }
            groups.append(ResourceGroup(selection: value))
        }
        begin(Request(selection: value, page: value.video.isFolder ? 1 : nil))
    }

    private func begin(_ request: Request) {
        selectionRevision = UUID()
        cancelDetails(); clearDetail()
        expiredRequest = nil
        selectedSourceID = request.selection.site.id; selected = request.selection
        pending = request; retryRequest = request; loadingDetail = true
        let token = generation
        // Initial details share the automatic search budget. A later explicit tap
        // gets its own 15 seconds, including cancelled native work still retiring.
        let deadline = searchDeadline.flatMap { $0 > .now ? $0 : nil }
            ?? ContinuousClock.now.advanced(by: .seconds(15))
        deadlineTask = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            guard let self, self.generation == token, !Task.isCancelled else { return }
            self.expiredRequest = token
            self.pending = nil; self.loadingDetail = false
            self.detailError = "资源读取超过 15 秒，请重试或选择其它资源。"
            self.operation?.cancel()
            self.deadlineTask = nil
        }
        startWorker()
    }

    private func cancelDetails() {
        generation = UUID(); pending = nil
        deadlineTask?.cancel(); deadlineTask = nil
        operation?.cancel()
        loadingDetail = false
    }

    private func startWorker() {
        guard detailWorker == nil, config != nil else { return }
        hasOutstandingDetailWork = true
        detailWorker = Task { [weak self] in
            guard let self else { return }
            while let next = self.pending, let config = self.config {
                self.pending = nil
                let token = self.generation
                let client = CatalogClient(site: next.selection.site, origin: config.origin, jarURL: config.spiderURL)
                let current = Task {
                    try await GlobalSearch.withAdmission(site: next.selection.site) {
                        let answer: Answer
                        if let page = next.page {
                            let folder = next.selection.video
                            answer = .resources(try await client.list(category: folder.folderCategoryID, query: "", page: page, filters: folder.folderFilters))
                        } else {
                            let value = try await client.detail(next.selection.video.id, cached: true)
                            answer = .detail(value.keepingCategory(next.selection.video.category)
                                .keepingPoster(next.selection.video.poster, headers: next.selection.video.posterHeaders))
                        }
                        try Task.checkCancellation()
                        return answer
                    }
                }
                self.operation = current
                let answer = await current.result
                self.operation = nil
                guard self.generation == token, self.expiredRequest != token else { continue }
                switch answer {
                case .success(.detail(let value)) where value.isFolder:
                    // Some sources only mark the folder in their detail answer.
                    // Keep the original deadline across that extra lookup.
                    let folder = SearchVideoResult(site: next.selection.site, video: value)
                    guard self.allowsOpening(folder) else { self.finishRequest(); continue }
                    self.selected = folder
                    self.groups.append(ResourceGroup(selection: folder))
                    let request = Request(selection: folder, page: 1)
                    self.pending = request; self.retryRequest = request
                    continue
                case .success(.detail(let value)):
                    self.detail = value
                    var seen = Set<String>()
                    self.flags = value.episodes.map(\.flag).filter { seen.insert($0).inserted }
                    self.selectedFlag = self.flags.first
                    self.episodes = value.episodes.filter { $0.flag == self.selectedFlag }
                    self.retryRequest = nil
                case .success(.resources(let page)):
                    self.accept(page, for: next)
                    self.retryRequest = nil
                case .failure(let error):
                    if !(error is CancellationError) { self.detailError = error.localizedDescription }
                }
                self.finishRequest()
            }
            self.detailWorker = nil
            self.hasOutstandingDetailWork = false
        }
    }

    private func finishRequest() {
        deadlineTask?.cancel(); deadlineTask = nil
        loadingDetail = false
    }

    private func accept(_ page: CatalogPage, for request: Request) {
        guard let index = groups.indices.last, groups[index].id == request.selection.id, let number = request.page else { return }
        var group = groups[index]
        var seen = Set(group.videos.map(\.id))
        var count = groups.reduce(0) { $0 + $1.videos.count }
        var bytes = groups.reduce(0) { $0 + Self.resourceBytes($1.selection.video) + $1.videos.reduce(0) { $0 + Self.resourceBytes($1) } }
        var additions = 0, bounded = false
        for video in page.videos where seen.insert(video.id).inserted {
            let cost = Self.resourceBytes(video)
            // A full parent listing must not make every child look empty. Keep
            // the folder identity, evict older cards and reload that frame on Back.
            for ancestor in 0..<index where count >= Self.maximumResources || bytes + cost > Self.maximumResourceBytes {
                guard !groups[ancestor].videos.isEmpty else { continue }
                count -= groups[ancestor].videos.count
                bytes -= groups[ancestor].videos.reduce(0) { $0 + Self.resourceBytes($1) }
                groups[ancestor].videos = []; groups[ancestor].loaded = false
                groups[ancestor].page = 0; groups[ancestor].hasMore = false
            }
            guard count < Self.maximumResources, bytes + cost <= Self.maximumResourceBytes else { bounded = true; break }
            group.videos.append(video); count += 1; bytes += cost; additions += 1
        }
        group.page = number; group.pageCount = max(group.pageCount, page.pageCount); group.loaded = true
        // A repeated page is exhausted even if its provider advertises more pages.
        group.hasMore = !bounded && additions > 0 && number < group.pageCount
        groups[index] = group
        if bounded { resourceNotice = "当前分类资源较多，已保留可浏览的结果；可返回选择其它分类。" }
    }

    private static func resourceBytes(_ video: Video) -> Int {
        var bytes = video.id.utf8.count + video.name.utf8.count + video.remarks.utf8.count + video.synopsis.utf8.count
        bytes += video.poster?.absoluteString.utf8.count ?? 0
        bytes += video.folderCategoryID.utf8.count + (video.category?.utf8.count ?? 0)
        for (key, value) in video.folderFilters { bytes += key.utf8.count + value.utf8.count }
        for (key, value) in video.posterHeaders { bytes += key.utf8.count + value.utf8.count }
        for episode in video.episodes { bytes += episode.id.utf8.count + episode.name.utf8.count + episode.address.utf8.count + episode.flag.utf8.count }
        return bytes + 256
    }
}
