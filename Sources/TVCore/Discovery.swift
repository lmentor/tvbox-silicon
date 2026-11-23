import Foundation

extension Site {
    public var searchable: Bool {
        let enabled: Bool
        switch raw["searchable"] {
        case .bool(let value): enabled = value
        case .number, .string: enabled = raw["searchable"]?.int == 1 || raw["searchable"] == .string("true")
        default: enabled = true
        }
        return enabled && !Self.disabledSearch(raw["supportSearch"])
            && !isIndexSource
    }
    private static func disabledSearch(_ value: JSONValue?) -> Bool {
        value == .bool(false) || value == .number(0) || value == .string("0") || value == .string("false")
    }
    /// TVBox's `hide: 1` keeps a search-only source out of the source lists.
    public var hidden: Bool { raw["hide"]?.int == 1 }
    public func canBrowse(jarURL: URL?) -> Bool {
        if isCloudFiles { return true }
        let jarURL = spider(or: jarURL)
        if native { return true }
        if runsLitePort { return true }
        #if os(macOS)
        let hasPlugin = jarURL != nil || raw["jar"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        switch runtime {
        case .javascript, .python: return LocalJarHost.available(runtime)
        case .jar: return hasPlugin && EmbeddedJarHost.available
        case .api, .unsupported: return false
        }
        #elseif os(iOS) || os(tvOS)
        if runtime == .javascript { return ScriptRuntime.available }
        if runtime == .python { return EmbeddedPythonHost.available }
        return runtime == .jar && EmbeddedJarHost.available && (jarURL != nil || raw["jar"]?.string?.isEmpty == false)
        #else
        return false
        #endif
    }
}

/// One later page of a source's search results.
public struct SearchBatch: Identifiable, Sendable {
    public let source: String
    public let page: Int
    public let videos: [Video]
    public var id: String { "\(source)#\(page)" }
}

public struct SearchSourceResult: Identifiable, Sendable {
    public let site: Site
    public let page: CatalogPage?
    public let error: String?
    public let mangaPage: MangaPage?
    /// The first retained match may come from a later page after title filtering.
    public let pageNumber: Int
    public let unfilteredPageFingerprint: String?
    public var id: String { site.id }
    public init(site: Site, page: CatalogPage?, error: String?, mangaPage: MangaPage? = nil,
                pageNumber: Int = 1, unfilteredPageFingerprint: String? = nil) {
        self.site = site; self.page = page; self.error = error; self.mangaPage = mangaPage
        self.pageNumber = pageNumber; self.unfilteredPageFingerprint = unfilteredPageFingerprint
    }
}

/// A materialized video card. IDs are scoped to a source, so equal IDs from different
/// sources remain separate results.
public struct SearchVideoResult: Identifiable, Sendable {
    public let site: Site
    public let video: Video
    public let id: String
    public init(site: Site, video: Video) {
        self.site = site; self.video = video
        id = "\(site.id.utf8.count):\(site.id)\(video.id)"
    }
}

public enum GlobalSearch {
    /// Native HTTP, embedded Python, QuickJS and Node have independent limits inside one
    /// global memory/network budget. Pending sources are data, not hundreds of running tasks.
    public static func search(sites: [Site], origin: URL, jarURL: URL?, query: String,
                              http: HTTPClient = HTTPClient(), retryFailures: Bool = false, concurrency: Int = 30,
                              deadlineSeconds: Double? = nil,
                              customSearch: (@Sendable (Site) async -> SearchSourceResult?)? = nil,
                              onResult: @escaping @Sendable (SearchSourceResult) async -> Void) async {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, !Task.isCancelled else { return }
        let eligible = sites.filter { $0.searchable && $0.canBrowse(jarURL: jarURL) }
        let began = ContinuousClock.now
        let runtimeCounts = Dictionary(grouping: eligible, by: lane).mapValues(\.count)
        Diagnostics.shared.record(.info, "search", "begin sources=\(eligible.count) skipped=\(sites.count - eligible.count) runtimes=\(runtimeCounts)")
        defer { Diagnostics.shared.record(.info, "search", "end elapsed=\(began.duration(to: .now)) cancelled=\(Task.isCancelled)") }
        let width = min(SearchScheduler.maximumConcurrent, max(1, concurrency))
        let limits = SearchScheduler.runtimeLimits.mapValues { min($0, width) }
        await SearchScheduler.search(sites: eligible, maximumConcurrent: width, limits: limits,
                                     lane: lane, operation: { site in
            if let custom = await customSearch?(site) { return custom }
            return await fetchPage(site: site, origin: origin, jarURL: jarURL, keyword: keyword, page: 1,
                                   http: http, retryFailures: retryFailures, deadlineSeconds: deadlineSeconds)
        }, onResult: onResult)
    }

    /// Detail and manga work use the same cross-query budget as automatic searches.
    /// The operation must await its real runtime completion even after cancellation.
    public static func withAdmission<Value: Sendable>(site: Site? = nil,
                         operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await SearchScheduler.withPermit(lane: site.map(lane) ?? .native, operation: operation)
    }

    /// Pagination shares the same admission budget as first-page and replacement searches.
    static func page(site: Site, origin: URL, jarURL: URL?, query: String, page: Int, http: HTTPClient) async -> SearchSourceResult {
        await SearchScheduler.request(site: site, lane: lane(site)) {
            await fetchPage(site: site, origin: origin, jarURL: jarURL, keyword: query, page: page, http: http, retryFailures: true)
        }
    }

    private static func lane(_ site: Site) -> SearchScheduler.Lane {
        if site.raw["localMangaSource"] != nil { return .quickJS }
        if site.native { return .native }
        switch site.preferredRuntime {
        case .python: return .python
        case .javascript: return site.raw["catPawOpen"] != nil ? .node : .quickJS
        case .jar: return .jar
        case .api, .unsupported: return .native
        }
    }

    private enum Answer: Sendable {
        case page(CatalogPage), failure(any Error), expired, cancelled
    }
    private static func fetchPage(site: Site, origin: URL, jarURL: URL?, keyword: String, page: Int, http: HTTPClient,
                                  retryFailures: Bool, deadlineSeconds: Double? = nil) async -> SearchSourceResult {
        let began = ContinuousClock.now
        // A first plugin answer includes its local module preparation. HTTP sources need less.
        // Automatic searches probe a recent failure briefly; an explicit retry gets the full budget.
        let recentlyFailed = await SourceHealth.shared.failedRecently(site, origin: origin)
        let standardSeconds: Double = !retryFailures && recentlyFailed ? 8 : (lane(site) == .native ? 15 : 25)
        let seconds = deadlineSeconds.flatMap { $0.isFinite ? min(standardSeconds, max(0.05, $0)) : nil } ?? standardSeconds
        let answer = await withTaskGroup(of: Answer.self) { group in
            group.addTask {
                do {
                    try Task.checkCancellation()
                    let page = try await CatalogClient(site: site, origin: origin, http: http, jarURL: jarURL)
                        .list(category: nil, query: keyword, page: page, recordHealth: false)
                    try Task.checkCancellation()
                    return .page(page)
                } catch {
                    if Task.isCancelled { return .cancelled }
                    return .failure(error)
                }
            }
            group.addTask {
                do { try await Task.sleep(for: .seconds(seconds)); return .expired }
                catch { return .cancelled }
            }
            let first = await group.next() ?? .cancelled
            group.cancelAll()
            // Leaving the group waits for the source's cancellation fence. It does not detach
            // a timed-out runtime and then start more work behind its occupied worker slot.
            return first
        }
        let elapsed = began.duration(to: .now)
        // A user stop/replacement can arrive while native cancellation unwinds. It is never
        // a source failure, even if the deadline won just before that cancellation.
        guard !Task.isCancelled else {
            return SearchSourceResult(site: site, page: nil, error: CancellationError().localizedDescription)
        }
        switch answer {
        case .page(let page):
            await SourceHealth.shared.record(site, origin: origin, seconds: elapsed.seconds, error: nil)
            Diagnostics.shared.record(.debug, "search", "source=\(site.key) ok videos=\(page.videos.count) elapsed=\(elapsed)")
            return SearchSourceResult(site: site, page: page, error: nil)
        case .expired:
            await SourceHealth.shared.record(site, origin: origin, seconds: elapsed.seconds, error: URLError(.timedOut))
            Diagnostics.shared.record(.warning, "search", "source=\(site.key) deadline=\(seconds)s elapsed=\(elapsed)")
            return SearchSourceResult(site: site, page: nil, error: "站点搜索超过 \(seconds) 秒，可单独重试。")
        case .failure(let error):
            await SourceHealth.shared.record(site, origin: origin, seconds: elapsed.seconds, error: error)
            let message = error.localizedDescription
            Diagnostics.shared.record(.warning, "search", "source=\(site.key) failed elapsed=\(elapsed) error=\(message)")
            return SearchSourceResult(site: site, page: nil, error: message)
        case .cancelled:
            return SearchSourceResult(site: site, page: nil, error: CancellationError().localizedDescription)
        }
    }
}
