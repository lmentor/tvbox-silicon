import Foundation

/// Installed comics share search selection, order and admission, while retaining the
/// source key required by the existing manga detail and image pipelines.
public enum LocalSearchManga {
    public static let origin = URL(string: "manga://installed/")!

    public static func site(_ source: MangaInstalledSource) -> Site {
        Site(key: "manga:" + source.key, name: source.name, type: 1,
             api: "manga://installed/" + source.key,
             raw: ["localMangaSource": .string(source.key), "revision": .string(source.revision),
                   "searchable": .bool(source.canSearch != false)],
             provenance: SourceProvenance(origin: origin, spider: nil))
    }
    public static func key(for site: Site) -> String? { site.raw["localMangaSource"]?.string }
    public static var sites: [Site] { MangaSources.shared.installed.filter { $0.canSearch != false }.map(site) }
    /// Global search remains usable when the installed library contains only comics.
    public static var catalog: Subscription? {
        guard !MangaSources.shared.installed.isEmpty else { return nil }
        return Subscription(origin: origin, importedAt: Date(timeIntervalSince1970: 0), sites: [], lives: [], raw: [:])
    }
    static func video(_ comic: MangaComic) -> Video {
        Video(id: comic.id, name: comic.title, poster: URL(string: comic.cover), remarks: comic.subtitle,
              synopsis: comic.description, category: "漫画")
    }
    static func result(site: Site, page: MangaPage) -> SearchSourceResult {
        SearchSourceResult(site: site, page: CatalogPage(videos: page.comics.map(video), pageCount: page.next == nil ? 1 : Int.max),
                           error: nil, mangaPage: page)
    }

    private enum Answer: Sendable { case page(MangaPage), failed(String), cancelled }
    /// The caller owns a shared QuickJS permit. Structured cancellation waits for the
    /// source's actual runtime return before releasing that permit.
    static func firstPage(site: Site, keyword: String) async -> SearchSourceResult {
        await page(site: site, keyword: keyword, cursor: nil)
    }
    static func page(site: Site, keyword: String, cursor: MangaCursor?) async -> SearchSourceResult {
        guard let key = key(for: site) else { return SearchSourceResult(site: site, page: nil, error: "漫画来源不可用。") }
        let answer = await withTaskGroup(of: Answer.self) { group in
            group.addTask {
                do {
                    try Task.checkCancellation()
                    let page = try await MangaRuntime.shared.searchGlobal(key, keyword: keyword, cursor: cursor)
                    try Task.checkCancellation()
                    return .page(page)
                } catch {
                    return Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
                }
            }
            group.addTask {
                do { try await Task.sleep(for: .seconds(25)); return .failed("漫画站点搜索超过 25 秒，可单独重试。") }
                catch { return .cancelled }
            }
            let answer = await group.next() ?? .cancelled
            group.cancelAll()
            return answer
        }
        guard !Task.isCancelled else { return SearchSourceResult(site: site, page: nil, error: CancellationError().localizedDescription) }
        switch answer {
        case .page(let page): return result(site: site, page: page)
        case .failed(let error): return SearchSourceResult(site: site, page: nil, error: error)
        case .cancelled: return SearchSourceResult(site: site, page: nil, error: CancellationError().localizedDescription)
        }
    }
}
