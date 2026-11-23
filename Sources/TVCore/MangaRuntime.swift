import Foundation
import CoreGraphics

/// Runs Venera comic sources (github.com/venera-app/venera-configs) in-process on QuickJS: one runtime per
/// source, with Venera's script API (ScriptAssets/venera) answered by MangaHost.
public actor MangaRuntime {
    public static let shared = MangaRuntime()
    /// Posted on the main queue when a source shows a message (userInfo "source", "text").
    public static let noticeNotification = Notification.Name("MangaRuntime.notice")
    /// Posted when a site makes requests wait (拷贝漫画's 210); userInfo "host", "seconds".
    public static let throttleNotification = Notification.Name("MangaRuntime.throttle")
    /// Chapters' page lists for a while: reopening one (Continue, the chapter list) doesn't ask the site again.
    private var pageLists: [String: (date: Date, pages: [String])] = [:]
    /// Comics' details for a while too, as the open-source copymanga clients keep them (30 min): reading on from a
    /// comic's page and coming back doesn't ask the site again. Try Again asks afresh.
    private var detailsKept: [String: (date: Date, details: MangaDetails)] = [:]
    /// Explore pages' first screens for ten minutes: going back to a source doesn't ask the site again.
    private var exploreKept: [String: (date: Date, value: (shelves: [MangaShelf], page: MangaPage))] = [:]
    private var exploreRevision: [String: UInt64] = [:]

    final class Session: @unchecked Sendable {
        let script: ScriptSession
        let host: MangaHost
        let info: MangaSourceInfo
        let revision: String
        /// Image scripts share this source's bitmap store. The next page waits
        /// until the preceding transformation and its cleanup have finished.
        var modifying: Task<Void, Never>?
        init(script: ScriptSession, host: MangaHost, info: MangaSourceInfo, revision: String) { self.script = script; self.host = host; self.info = info; self.revision = revision }
    }
    private var sessions: [String: Session] = [:]
    private var starting: [String: Task<Session, Error>] = [:]

    /// Loads a source's script on its own and describes it, without keeping it (for installing).
    public func inspect(code: String) async throws -> MangaSourceInfo {
        let session = try await Self.start(key: "inspect-" + UUID().uuidString.prefix(8), code: code, revision: "")
        session.script.close()
        return session.info
    }

    public func info(_ key: String) async throws -> MangaSourceInfo { try await session(key).info }

    /// Drops a running source, e.g. after it was updated or removed.
    public func reset(_ key: String) {
        sessions.removeValue(forKey: key)?.script.close()
        starting.removeValue(forKey: key)?.cancel()
        pageLists = pageLists.filter { !$0.key.hasPrefix(key + "|") }
        detailsKept = detailsKept.filter { !$0.key.hasPrefix(key + "|") }
        exploreKept = exploreKept.filter { !$0.key.hasPrefix(key + "|") }
    }

    func session(_ key: String) async throws -> Session {
        guard let installed = MangaSources.shared.installed(key) else { throw TVError.unsupported(L10n.text("This comic source is no longer installed.")) }
        if let session = sessions[key], session.revision == installed.revision { return session }
        if let task = starting[key] { return try await task.value }
        sessions.removeValue(forKey: key)?.script.close()
        let task = Task { () throws -> Session in
            let code = try MangaSources.shared.code(key)
            return try await Self.start(key: key, code: code, revision: installed.revision)
        }
        starting[key] = task
        defer { starting[key] = nil }
        let session = try await task.value
        sessions[key] = session
        return session
    }

    private static func start(key: String, code: String, revision: String, cancellable: Bool = false,
                              webLogin: MangaWebLoginTransaction? = nil, profileOverride: URL? = nil) async throws -> Session {
        let host = MangaHost(sourceKey: key, webLogin: webLogin)
        let profile = profileOverride ?? MangaLibrary.root.appendingPathComponent("Profiles/\(key)", isDirectory: true)
        let script = try await ScriptSession.start(module: "assets://venera/prelude.js", supplied: [:], profile: profile, label: "manga \(key)", extension: host)
        do {
            if cancellable { try Task.checkCancellation() }
            guard let api = ScriptAssets.bundled("assets://venera/init.js") else { throw TVError.unsupported(L10n.text("The comic source runtime is missing from this build.")) }
            // A global script, so its classes and `let`s are globals the source can see.
            let booted = await script.evaluate(api + "\n;true", within: 30, cancellable: cancellable)
            if cancellable { try Task.checkCancellation() }
            if let error = booted["error"]?.string { throw TVError.unsupported(L10n.text("Comic source error: %@", String(error.prefix(300)))) }
            let value = try await call(script, "__venera.load(\(json(code)))", seconds: 60, cancellable: cancellable)
            return Session(script: script, host: host, info: try MangaSourceInfo(value), revision: revision)
        } catch {
            if cancellable { await script.closeAndWait() } else { script.close() }
            throw error
        }
    }

    /// Evaluates a `__venera` call and unwraps its {value} or {error}.
    private static func call(_ script: ScriptSession, _ expression: String, seconds: Double,
                             cancellable: Bool = false,
                             maximumBytes: Int = BoundedHTTPData.searchBytes,
                             isolation: isolated (any Actor)? = #isolation) async throws -> Any? {
        if cancellable { try Task.checkCancellation() }
        let envelope = await script.evaluate("Promise.resolve(\(expression)).then(value => JSON.stringify(value))", within: seconds, cancellable: cancellable, search: cancellable)
        if cancellable { try Task.checkCancellation() }
        if let error = envelope["error"]?.string { throw TVError.unsupported(MangaRuntime.readable(error)) }
        guard let text = envelope["value"]?.string else {
            throw TVError.unsupported(L10n.text("The comic source returned nothing."))
        }
        let data = Data(text.utf8)
        if cancellable { try CatalogResponseParser.validate(data, maximumBytes: maximumBytes) }
        guard let answer = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            throw TVError.unsupported(L10n.text("The comic source returned nothing."))
        }
        if let error = answer["error"] as? String { throw TVError.unsupported(MangaRuntime.readable(error)) }
        return answer["value"]
    }

    static func readable(_ error: String) -> String {
        let first = error.split(separator: "\n").first.map(String.init) ?? error
        if first.contains("did not finish in time") { return L10n.text("The comic source took too long to answer.") }
        return String(first.prefix(400))
    }

    static func json(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "null" }
        return (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    /// Calls the source's function at `path` with JSON-able arguments.
    public func call(_ key: String, _ path: String, _ arguments: [Any?], seconds: Double = 60) async throws -> Any? {
        let session = try await session(key)
        let started = ContinuousClock.now, since = Date()
        do {
            let value = try await Self.call(session.script, "__venera.call(\(Self.json(path)), \(Self.json(arguments.map { $0 ?? NSNull() })))", seconds: seconds)
            Diagnostics.shared.record(.info, "manga.call", "source=\(key) \(path) ok \(started.duration(to: .now))")
            return value
        } catch {
            Diagnostics.shared.record(.error, "manga.call", "source=\(key) \(path) failed: \(error.localizedDescription.prefix(300))")
            // The script's message ("Invalid status code: 403") hides why; the site's answer says.
            if var problem = MangaSiteProblem.latest(since: since) {
                problem.detail = error.localizedDescription
                throw problem
            }
            throw error
        }
    }

    func raw(_ key: String, _ expression: String, seconds: Double = 30) async throws -> Any? {
        try await Self.call(try await session(key).script, expression, seconds: seconds)
    }

    func host(_ key: String) async throws -> MangaHost { try await session(key).host }
}

// MARK: - The Venera API, typed

extension MangaRuntime {
    /// Global search owns a short-lived runtime, separate from an open reader's session.
    /// The shared search pool bounds these VMs; closing waits for native cleanup before
    /// that pool admits a replacement source, including canceled or timed-out searches.
    public func searchGlobal(_ key: String, keyword: String, cursor: MangaCursor?) async throws -> MangaPage {
        try Task.checkCancellation()
        guard let installed = MangaSources.shared.installed(key) else {
            throw TVError.unsupported(L10n.text("This comic source is no longer installed."))
        }
        let code = try MangaSources.shared.code(key)
        let session = try await Self.start(key: key, code: code, revision: installed.revision, cancellable: true)
        do {
            let page = try await Self.searchPage(session, keyword: keyword, cursor: cursor)
            await session.script.closeAndWait()
            try Task.checkCancellation()
            return page
        } catch {
            await session.script.closeAndWait()
            throw error
        }
    }

    private static func searchPage(_ session: Session, keyword: String, cursor: MangaCursor?) async throws -> MangaPage {
        let info = session.info
        guard info.canSearch else { return MangaPage(comics: [], next: nil) }
        let options: [Any] = info.searchOptions.map { $0.defaultValue.map { $0 as Any } ?? NSNull() }
        let path = info.searchPaged ? "search.load" : "search.loadNext"
        let position: Any
        var number = 1
        if info.searchPaged {
            if case .page(let page) = cursor { number = page }
            position = number
        } else if case .token(let token) = cursor { position = token }
        else { position = NSNull() }
        let arguments: [Any] = [keyword, options, position]
        let value = try await call(session.script, "__venera.call(\(json(path)), \(json(arguments)))", seconds: 25, cancellable: true) as? [String: Any]
        let comics = MangaComic.list(value?["comics"], source: info.key)
        let next: MangaCursor?
        if info.searchPaged {
            let more = MangaValue.int(value?["maxPage"]).map { number < $0 } ?? !comics.isEmpty
            next = more && !comics.isEmpty ? .page(number + 1) : nil
        } else { next = MangaValue.string(value?["next"]).map(MangaCursor.token) }
        return MangaPage(comics: comics, next: next)
    }

    public func explore(_ key: String, page index: Int, cursor: MangaCursor?) async throws -> (shelves: [MangaShelf], page: MangaPage) {
        try Task.checkCancellation()
        let kept = "\(key)|explore|\(index)"
        let revision = exploreRevision[key, default: 0]
        if cursor == nil, let entry = exploreKept[kept], Date().timeIntervalSince(entry.date) < 10 * 60 { return entry.value }
        let value = try await exploreAfresh(key, page: index, cursor: cursor)
        try Task.checkCancellation()
        if cursor == nil, exploreRevision[key, default: 0] == revision { exploreKept[kept] = (Date(), value) }
        return value
    }

    /// Refresh the browse page without stopping an open reader or discarding its source profile.
    public func refreshExplore(_ key: String) {
        exploreRevision[key, default: 0] &+= 1
        exploreKept = exploreKept.filter { !$0.key.hasPrefix(key + "|") }
    }

    private func exploreAfresh(_ key: String, page index: Int, cursor: MangaCursor?) async throws -> (shelves: [MangaShelf], page: MangaPage) {
        let info = try await info(key)
        guard info.explore.indices.contains(index) else { return ([], MangaPage(comics: [], next: nil)) }
        let page = info.explore[index]
        switch page.type {
        case "multiPartPage", "singlePageWithMultiPart":
            let value = try await call(key, "explore.\(index).load", [NSNull()])
            if let parts = value as? [Any] {
                return (parts.compactMap { Self.shelf($0, source: key) }, MangaPage(comics: [], next: nil))
            }
            // singlePageWithMultiPart: {title: [comics]}
            let shelves = MangaValue.pairs(value).map { MangaShelf(title: $0.0, comics: MangaComic.list($0.1, source: key), viewMore: nil) }
            return (shelves.filter { !$0.comics.isEmpty }, MangaPage(comics: [], next: nil))
        case "mixed":
            let number: Int
            if case .page(let value) = cursor { number = value } else { number = 1 }
            let value = try await call(key, "explore.\(index).load", [number]) as? [String: Any]
            var shelves: [MangaShelf] = [], comics: [MangaComic] = []
            for part in value?["data"] as? [Any] ?? [] {
                if part is [Any] { comics += MangaComic.list(part, source: key) } else if let shelf = Self.shelf(part, source: key) { shelves.append(shelf) }
            }
            let maxPage = MangaValue.int(value?["maxPage"])
            return (shelves, MangaPage(comics: comics, next: maxPage.map { number < $0 ? .page(number + 1) : nil } ?? nil))
        default:
            return ([], try await list(key, page.paged ? "explore.\(index).load" : "explore.\(index).loadNext", cursor: cursor, paged: page.paged) { $0 })
        }
    }

    private static func shelf(_ value: Any?, source: String) -> MangaShelf? {
        guard let item = value as? [String: Any] else { return nil }
        let comics = MangaComic.list(item["comics"], source: source)
        guard !comics.isEmpty else { return nil }
        return MangaShelf(title: MangaValue.string(item["title"]) ?? "", comics: comics, viewMore: MangaJump(item["viewMore"]))
    }

    /// A paged list: `load(..., page)` answering {comics, maxPage}, or `loadNext(..., next)` answering {comics, next}.
    private func list(_ key: String, _ path: String, cursor: MangaCursor?, paged: Bool, arguments: ([Any?]) -> [Any?]) async throws -> MangaPage {
        if paged {
            var number = 1
            if case .page(let value) = cursor { number = value }
            let value = try await call(key, path, arguments([number])) as? [String: Any]
            let comics = MangaComic.list(value?["comics"], source: key)
            let maxPage = MangaValue.int(value?["maxPage"])
            let more = maxPage.map { number < $0 } ?? !comics.isEmpty
            return MangaPage(comics: comics, next: more && !comics.isEmpty ? .page(number + 1) : nil)
        }
        var token: Any? = nil
        if case .token(let value) = cursor { token = value }
        let value = try await call(key, path, arguments([token])) as? [String: Any]
        let comics = MangaComic.list(value?["comics"], source: key)
        return MangaPage(comics: comics, next: MangaValue.string(value?["next"]).map { .token($0) })
    }

    public func search(_ key: String, keyword: String, options: [String?], cursor: MangaCursor?) async throws -> MangaPage {
        let info = try await info(key)
        guard info.canSearch else { return MangaPage(comics: [], next: nil) }
        return try await list(key, info.searchPaged ? "search.load" : "search.loadNext", cursor: cursor, paged: info.searchPaged) { [keyword, options.map { value -> Any in value ?? NSNull() }] + $0 }
    }

    public func category(_ key: String, name: String, param: String?, options: [String], cursor: MangaCursor?) async throws -> MangaPage {
        try await list(key, "categoryComics.load", cursor: cursor, paged: true) { [name, param ?? NSNull(), options] + $0 }
    }

    public func ranking(_ key: String, option: String, cursor: MangaCursor?) async throws -> MangaPage {
        try await list(key, "categoryComics.ranking.load", cursor: cursor, paged: true) { [option] + $0 }
    }

    public func details(_ key: String, id: String, fresh: Bool = false) async throws -> MangaDetails {
        let kept = "\(key)|\(id)"
        if !fresh, let entry = detailsKept[kept], Date().timeIntervalSince(entry.date) < 30 * 60 { return entry.details }
        let details = try MangaDetails(try await call(key, "comic.loadInfo", [id], seconds: 120), id: id, source: key)
        if detailsKept.count > 60 { detailsKept = detailsKept.filter { Date().timeIntervalSince($0.value.date) < 30 * 60 } }
        detailsKept[kept] = (Date(), details)
        return details
    }

    /// Page image addresses of a chapter (`nil` for a one-shot comic).
    public func pages(_ key: String, comic: String, chapter: String?) async throws -> [String] {
        let id = "\(key)|\(comic)|\(chapter ?? "")"
        if let kept = pageLists[id], Date().timeIntervalSince(kept.date) < 30 * 60 { return kept.pages }
        // Long enough for a site's waits: 拷贝漫画's script sleeps 40 s per "too many requests".
        let value = try await call(key, "comic.loadEp", [comic, chapter ?? NSNull()], seconds: 180) as? [String: Any]
        let images = MangaValue.strings(value?["images"])
        guard !images.isEmpty else { throw TVError.unsupported(L10n.text("This chapter has no pages.")) }
        if pageLists.count > 40 { pageLists = pageLists.filter { Date().timeIntervalSince($0.value.date) < 30 * 60 } }
        pageLists[id] = (Date(), images)
        return images
    }

    public func signIn(_ key: String, account: String, password: String) async throws {
        _ = try await call(key, "account.login", [account, password])
        MangaSourceData.shared.set(key, "account", [account, password])
    }

    public func signIn(_ key: String, cookies: [String]) async throws {
        let valid = try await call(key, "account.loginWithCookies.validate", [cookies]) as? Bool ?? false
        guard valid else { throw TVError.unsupported(L10n.text("The source did not accept these cookies.")) }
        MangaSourceData.shared.set(key, "account", "ok")
    }

    /// Runs the source's actual web-login callbacks in a cancellable transient VM.
    /// Browser credentials stay staged until success, source identity and request
    /// ownership all agree; the normal reader's VM is left alone on cancellation.
    public func signInWithWebPage(_ key: String, url: URL, title: String, cookies: [HTTPCookie], localStorage: [String: String],
                                  request: MangaWebLoginRequest = MangaWebLoginRequest()) async throws -> Bool {
        try Task.checkCancellation()
        guard let installed = MangaSources.shared.installed(key) else { throw TVError.unsupported("漫画站点已移除。") }
        let code = try MangaSources.shared.code(key)
        let transaction = MangaWebLoginTransaction(key: key, cookies: cookies, localStorage: localStorage)
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("manga-login-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: profile) }
        let session = try await Self.start(key: key, code: code, revision: installed.revision, cancellable: true,
                                           webLogin: transaction, profileOverride: profile)
        do {
            guard let page = session.info.signInPage, let declared = URL(string: page),
                  url.scheme == "https" || url.scheme == "http", let host = url.host?.lowercased(),
                  let loginHost = declared.host?.lowercased(),
                  url.scheme == declared.scheme, url.port == declared.port,
                  host == loginHost || host.hasSuffix("." + loginHost) else {
                await session.script.closeAndWait()
                return false
            }
            let accepted = try await Self.call(session.script, "__venera.webLogin(\(Self.json(url.absoluteString)), \(Self.json(title)))",
                                               seconds: 15, cancellable: true) as? Bool ?? false
            await session.script.closeAndWait()
            try Task.checkCancellation()
            guard accepted else { return false }
            try request.commit { try MangaSources.shared.commitLogin(installed) { try transaction.commit() } }
            refreshExplore(key)
            return true
        } catch {
            await session.script.closeAndWait()
            throw error
        }
    }

    public func signOut(_ key: String) async {
        _ = try? await call(key, "account.logout", [])
        MangaSourceData.shared.set(key, "account", nil)
        if MangaSourceData.shared.value(key, "_webCookies") != nil {
            MangaSourceData.shared.set(key, "_webCookies", [])
            MangaSourceData.shared.set(key, "_localStorage", nil)
        }
    }

    public func runSettingCallback(_ key: String, setting: String) async throws {
        _ = try await call(key, "settings.\(setting).callback", [])
    }

    /// Headers (and a possibly different address) for covers, from the source's onThumbnailLoad.
    public func thumbnailRequests(_ key: String, urls: [String]) async -> [String: (url: String, headers: [String: String])] {
        guard (try? await info(key))?.hasThumbnailConfig == true, !urls.isEmpty else { return [:] }
        guard let value = try? await raw(key, "__venera.thumbnailHeaders(\(Self.json(urls)))") as? [String: Any] else { return [:] }
        var out: [String: (url: String, headers: [String: String])] = [:]
        for (url, item) in value {
            guard let item = item as? [String: Any] else { continue }
            out[url] = (MangaValue.string(item["url"]) ?? url, (item["headers"] as? [String: Any] ?? [:]).compactMapValues { MangaValue.string($0) })
        }
        return out
    }

    struct ImageConfig {
        var id: Int
        var request: MangaHTTP.Request
        var onResponse: Bool
        var modifyImage: Bool
        var onLoadFailed: Bool
    }

    /// Cold cover sources never enter the resident reader session dictionary.
    /// MangaImages holds at most six leases and releases only after image work ends.
    struct ImageLease: Sendable {
        fileprivate let session: Session
        fileprivate let transient: Bool
        var info: MangaSourceInfo { session.info }
    }

    func imageLease(_ key: String, cover: Bool) async throws -> ImageLease {
        try Task.checkCancellation()
        if !cover { return ImageLease(session: try await session(key), transient: false) }
        guard let installed = MangaSources.shared.installed(key) else {
            throw TVError.unsupported(L10n.text("This comic source is no longer installed."))
        }
        if let retained = sessions[key], retained.revision == installed.revision {
            return ImageLease(session: retained, transient: false)
        }
        let code = try MangaSources.shared.code(key)
        let isolated = try await Self.start(key: key, code: code, revision: installed.revision, cancellable: true)
        return ImageLease(session: isolated, transient: true)
    }

    func closeImageLease(_ lease: ImageLease, config: ImageConfig?) async {
        if let config {
            _ = try? await Self.call(lease.session.script, "__venera.release(\(config.id))", seconds: 5)
        }
        if lease.transient { await lease.session.script.closeAndWait() }
    }

    func imageConfig(_ key: String, kind: String, url: String, comic: String?, chapter: String?) async throws -> ImageConfig {
        let lease = ImageLease(session: try await session(key), transient: false)
        return try await imageConfig(lease, kind: kind, url: url, comic: comic, chapter: chapter)
    }

    func imageConfig(_ lease: ImageLease, kind: String, url: String, comic: String?, chapter: String?) async throws -> ImageConfig {
        let value = try await Self.call(lease.session.script, "__venera.imageConfig(\(Self.json(kind)), \(Self.json(url)), \(Self.json(comic)), \(Self.json(chapter)))",
                                        seconds: 30, cancellable: lease.transient) as? [String: Any] ?? [:]
        let address = MangaValue.string(value["url"]) ?? url
        guard let target = URL(string: address) ?? address.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:)) else {
            throw TVError.unsupported(L10n.text("The page address is invalid."))
        }
        var request = MangaHTTP.Request(url: target, method: MangaValue.string(value["method"]) ?? "GET")
        request.cookies = lease.session.host.cookies
        request.headers = (value["headers"] as? [String: Any] ?? [:]).compactMapValues { MangaValue.string($0) }
        if let body = value["body"] as? String { request.body = Data(base64Encoded: body) }
        return ImageConfig(id: MangaValue.int(value["id"]) ?? 0, request: request, onResponse: value["onResponse"] as? Bool ?? false,
                           modifyImage: value["modifyImage"] as? Bool ?? false, onLoadFailed: value["onLoadFailed"] as? Bool ?? false)
    }

    func transformResponse(_ key: String, config: Int, data: Data) async throws -> Data {
        let lease = ImageLease(session: try await session(key), transient: false)
        return try await transformResponse(lease, config: config, data: data)
    }

    func transformResponse(_ lease: ImageLease, config: Int, data: Data) async throws -> Data {
        let value = try await Self.call(lease.session.script, "__venera.onResponse(\(config), \(Self.json(data.base64EncodedString())))",
                                        seconds: 60, cancellable: lease.transient, maximumBytes: BoundedHTTPData.catalogBytes)
        return Data(base64Encoded: MangaValue.string(value) ?? "") ?? data
    }

    func retryRequest(_ key: String, config: Int) async -> MangaHTTP.Request? {
        guard let session = try? await session(key) else { return nil }
        return await retryRequest(ImageLease(session: session, transient: false), config: config)
    }

    func retryRequest(_ lease: ImageLease, config: Int) async -> MangaHTTP.Request? {
        guard let value = try? await Self.call(lease.session.script, "__venera.onLoadFailed(\(config))", seconds: 30,
                                               cancellable: lease.transient) as? [String: Any],
              let address = MangaValue.string(value["url"]), let url = URL(string: address) else { return nil }
        var request = MangaHTTP.Request(url: url)
        request.cookies = lease.session.host.cookies
        request.headers = (value["headers"] as? [String: Any] ?? [:]).compactMapValues { MangaValue.string($0) }
        return request
    }

    /// Runs the config's modifyImage script on the decoded page.
    func modify(_ key: String, config: Int, image: CGImage) async throws -> CGImage {
        let lease = ImageLease(session: try await session(key), transient: false)
        return try await modify(lease, config: config, image: image)
    }

    func modify(_ lease: ImageLease, config: Int, image: CGImage) async throws -> CGImage {
        let session = lease.session
        let previous = session.modifying
        let work = Task {
            await previous?.value
            if lease.transient { try Task.checkCancellation() }
            return try await Self.unscramble(session, config: config, image: image, cancellable: lease.transient)
        }
        session.modifying = Task { _ = try? await work.value }
        return try await withTaskCancellationHandler { try await work.value } onCancel: {
            if lease.transient { work.cancel() }
        }
    }

    private static func unscramble(_ session: Session, config: Int, image: CGImage,
                                   cancellable: Bool = false,
                                   isolation: isolated (any Actor)? = #isolation) async throws -> CGImage {
        let bitmaps = session.host.bitmaps
        guard let input = bitmaps.add(image) else { return image }
        defer { bitmaps.clear() }
        let output = MangaValue.int(try await Self.call(session.script, "__venera.modify(\(config), \(input))", seconds: 30, cancellable: cancellable)) ?? input
        return bitmaps.image(output) ?? image
    }

    func release(_ key: String, config: Int) async {
        _ = try? await raw(key, "__venera.release(\(config))", seconds: 5)
    }
}
