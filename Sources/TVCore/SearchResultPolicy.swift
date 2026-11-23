import Foundation

enum SearchResultPolicy {
    static func filtered(_ result: SearchSourceResult, keyword: String, mode: LocalSearchPreferences.KeywordMode) -> SearchSourceResult {
        guard let page = result.page else { return result }
        let videos = page.videos.filter { mode.accepts($0.name, keyword: keyword) }
        let manga = result.mangaPage.map { page in
            MangaPage(comics: page.comics.filter { mode.accepts($0.title, keyword: keyword) }, next: page.next)
        }
        // Search never displays category/filter catalogs. Drop them before retaining
        // a response so a plugin cannot hide a second unbounded payload beside its titles.
        return SearchSourceResult(site: result.site,
                                  page: CatalogPage(videos: videos, pageCount: page.pageCount),
                                  error: result.error, mangaPage: manga, pageNumber: result.pageNumber,
                                  unfilteredPageFingerprint: result.unfilteredPageFingerprint)
    }

    /// Called after the initial request releases its admission permit. Only sources
    /// whose first page was entirely rejected need this bounded continuation scan.
    /// Each additional page acquires the same global/runtime permit as normal paging.
    static func firstMatch(_ initial: SearchSourceResult, keyword: String, mode: LocalSearchPreferences.KeywordMode,
                           config: Subscription, http: HTTPClient) async -> SearchSourceResult {
        var response = initial, pageNumber = 1
        var seenPages = Set<String>(), seenCursors = Set<MangaCursor>()
        while true {
            guard !Task.isCancelled else { return SearchSourceResult(site: initial.site, page: nil, error: CancellationError().localizedDescription) }
            guard let page = response.page else { return response }
            let fingerprint = PluginChecksum.sha256((try? JSONEncoder().encode(page.videos.map(\.id))) ?? Data())
            let stamped = SearchSourceResult(site: response.site, page: page, error: response.error, mangaPage: response.mangaPage,
                                            pageNumber: pageNumber, unfilteredPageFingerprint: fingerprint)
            let accepted = filtered(stamped, keyword: keyword, mode: mode)
            guard mode != .default, accepted.page?.videos.isEmpty == true, !page.videos.isEmpty else { return accepted }
            guard seenPages.insert(fingerprint).inserted else { return accepted }
            let cursor = response.mangaPage?.next
            let more = LocalSearchManga.key(for: response.site) != nil ? cursor != nil : pageNumber < page.pageCount
            guard more else { return accepted }
            if let cursor, !seenCursors.insert(cursor).inserted { return accepted }
            guard pageNumber < 5 else {
                return SearchSourceResult(site: response.site, page: accepted.page,
                                          error: "前 5 页没有匹配标题，已停止继续翻页；可调整关键词后重试。",
                                          mangaPage: accepted.mangaPage, pageNumber: pageNumber,
                                          unfilteredPageFingerprint: fingerprint)
            }
            pageNumber += 1
            if LocalSearchManga.key(for: response.site) != nil {
                let site = response.site
                do {
                    response = try await GlobalSearch.withAdmission(site: site) {
                        await LocalSearchManga.page(site: site, keyword: keyword, cursor: cursor)
                    }
                } catch { return SearchSourceResult(site: site, page: nil, error: error.localizedDescription) }
            } else {
                response = await GlobalSearch.page(site: response.site, origin: config.origin, jarURL: config.spiderURL,
                                                   query: keyword, page: pageNumber, http: http)
            }
        }
    }
}
