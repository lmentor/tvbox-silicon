import Foundation

/// A source listed by a Venera repository (`index.json` of github.com/venera-app/venera-configs or a copy).
public struct MangaRepositoryEntry: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var key: String?
    public var address: URL
    public var version: String
    public var description: String
    public var id: String { key ?? address.absoluteString }
}

/// A source the viewer installed.
public struct MangaInstalledSource: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    public var name: String
    public var version: String
    /// Where its script came from, for updates; nil when pasted or imported.
    public var origin: URL?
    public var installed: Date
    /// The script's checksum: a changed script restarts the source's runtime.
    public var revision: String
    /// Old installed records probe this lazily; newly installed scripts keep their capability.
    public var canSearch: Bool? = nil
    public var id: String { key }
}

/// Installed Venera comic sources and the repositories they come from, kept in Application Support.
public final class MangaSources: @unchecked Sendable {
    public static let shared = MangaSources()
    /// Venera's own repository, which the Add Repository page offers (never added on its own).
    public static let veneraRepository = URL(string: "https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/index.json")!

    private let lock = NSLock()
    private var list: [MangaInstalledSource]
    private var repositoryList: [URL]
    private var repositoryEntries: [String: [MangaRepositoryEntry]]
    private var repositoryRequests: [String: UUID] = [:]
    private var repositoryWorking: Set<String> = []
    private var repositoryFailures: [String: [String: String]] = [:]
    private static var folder: URL { MangaLibrary.root.appendingPathComponent("Sources", isDirectory: true) }
    private static var listFile: URL { MangaLibrary.root.appendingPathComponent("sources.json") }
    private static var repositoriesFile: URL { MangaLibrary.root.appendingPathComponent("repositories.json") }
    private static var entriesFile: URL { MangaLibrary.root.appendingPathComponent("repository-entries.json") }

    init() {
        list = (try? JSONDecoder().decode([MangaInstalledSource].self, from: Data(contentsOf: Self.listFile))) ?? []
        repositoryList = (try? JSONDecoder().decode([URL].self, from: Data(contentsOf: Self.repositoriesFile))) ?? []
        repositoryEntries = (try? JSONDecoder().decode([String: [MangaRepositoryEntry]].self, from: Data(contentsOf: Self.entriesFile))) ?? [:]
    }

    public var installed: [MangaInstalledSource] { lock.withLock { list } }
    public var repositories: [URL] { lock.withLock { repositoryList } }
    public func cachedEntries(of repository: URL) -> [MangaRepositoryEntry] {
        lock.withLock { repositoryEntries[repository.absoluteString] ?? [] }
    }
    public func preparationErrors(of repository: URL) -> [String: String] {
        lock.withLock { repositoryFailures[repository.absoluteString] ?? [:] }
    }
    public func installed(_ key: String) -> MangaInstalledSource? { lock.withLock { list.first { $0.key == key } } }

    func commitLogin(_ source: MangaInstalledSource, operation: () throws -> Void) throws {
        try lock.withLock {
            guard list.first(where: { $0.key == source.key }) == source else { throw CancellationError() }
            try operation()
        }
    }

    func code(_ key: String) throws -> String {
        guard Self.validKey(key) else { throw TVError.unsupported("漫画站点标识无效。") }
        return try String(contentsOf: Self.folder.appendingPathComponent(key + ".js"), encoding: .utf8)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: MangaLibrary.root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: Self.listFile, options: .atomic) }
        if let data = try? JSONEncoder().encode(repositoryList) { try? data.write(to: Self.repositoriesFile, options: .atomic) }
    }

    // MARK: Repositories

    public func addRepository(_ url: URL) {
        lock.withLock {
            guard !repositoryList.contains(url) else { return }
            repositoryList.append(url); save()
        }
    }
    public func removeRepository(_ url: URL) { try? deleteRepository(url) }

    /// A subscription prepares its scripts as part of import. Individual failures
    /// leave the validated list and every usable source available for retry.
    @discardableResult
    public func importRepository(_ url: URL) async throws -> [MangaRepositoryEntry] {
        let request = beginRepositoryRequest(url)
        defer { endRepositoryRequest(url, request: request) }
        let entries = try await entries(of: url)
        try Task.checkCancellation()
        let committed = try lock.withLock {
            guard repositoryRequests[url.absoluteString] == request else { return false }
            var next = repositoryList
            if !next.contains(url) { next.append(url) }
            var cached = repositoryEntries
            cached[url.absoluteString] = entries
            try persistRepositories(next, entries: cached)
            return true
        }
        if committed { try await prepare(entries, repository: url, request: request, updates: true) }
        return entries
    }

    /// Refreshing a page that has since been removed must not subscribe again.
    @discardableResult
    public func refreshRepository(_ url: URL) async throws -> [MangaRepositoryEntry] {
        let request = beginRepositoryRequest(url)
        defer { endRepositoryRequest(url, request: request) }
        let entries = try await entries(of: url)
        try Task.checkCancellation()
        let committed = try lock.withLock {
            guard repositoryList.contains(url), repositoryRequests[url.absoluteString] == request else { return false }
            var cached = repositoryEntries
            cached[url.absoluteString] = entries
            try persistRepositories(repositoryList, entries: cached)
            return true
        }
        if committed { try await prepare(entries, repository: url, request: request, updates: true) }
        return entries
    }

    /// Upgrade cached subscriptions from editions that installed sources only
    /// when selected. Existing scripts and profiles are reused without a fetch.
    public func prepareRepository(_ url: URL) async throws {
        guard let request = lock.withLock({ () -> UUID? in
            guard !repositoryWorking.contains(url.absoluteString) else { return nil }
            let request = UUID()
            repositoryRequests[url.absoluteString] = request
            repositoryWorking.insert(url.absoluteString)
            return request
        }) else { return }
        defer { endRepositoryRequest(url, request: request) }
        try await prepare(cachedEntries(of: url), repository: url, request: request, updates: false)
    }

    private func beginRepositoryRequest(_ url: URL) -> UUID {
        lock.withLock {
            let request = UUID()
            repositoryRequests[url.absoluteString] = request
            repositoryWorking.insert(url.absoluteString)
            return request
        }
    }

    private func endRepositoryRequest(_ url: URL, request: UUID) {
        lock.withLock {
            guard repositoryRequests[url.absoluteString] == request else { return }
            repositoryWorking.remove(url.absoluteString)
        }
    }

    private func prepare(_ entries: [MangaRepositoryEntry], repository: URL, request: UUID, updates: Bool) async throws {
        // One download/inspection at a time bounds script memory and preserves
        // subscription order. Completed sources survive cancellation or failure.
        var failures: [String: String] = [:]
        for entry in entries {
            try Task.checkCancellation()
            let active = lock.withLock {
                repositoryList.contains(repository) && repositoryRequests[repository.absoluteString] == request
            }
            guard active else { return }
            let owner = lock.withLock {
                repositoryList.first { url in repositoryEntries[url.absoluteString]?.contains(where: { $0.id == entry.id }) == true }
            }
            guard owner == repository else { continue }
            if let key = entry.key, let current = installed(key), (!updates || current.origin == entry.address),
               (!updates || Self.compare(entry.version, current.version) != .orderedDescending),
               FileManager.default.fileExists(atPath: Self.folder.appendingPathComponent(key + ".js").path) { continue }
            do {
                _ = try await install(entry, repository: repository, request: request)
            } catch is CancellationError {
                try Task.checkCancellation()
                let stillActive = lock.withLock {
                    repositoryList.contains(repository) && repositoryRequests[repository.absoluteString] == request
                }
                if !stillActive { return }
                // Only this entry lost ownership while its bytes downloaded.
                // Keep preparing this still-active repository's unique sources.
                continue
            } catch {
                try Task.checkCancellation()
                failures[entry.id] = error.localizedDescription
            }
        }
        try Task.checkCancellation()
        lock.withLock {
            guard repositoryRequests[repository.absoluteString] == request, repositoryList.contains(repository) else { return }
            repositoryFailures[repository.absoluteString] = failures
        }
    }

    public func deleteRepository(_ url: URL) throws {
        try lock.withLock {
            var cached = repositoryEntries
            cached[url.absoluteString] = nil
            try persistRepositories(repositoryList.filter { $0 != url }, entries: cached)
            repositoryRequests[url.absoluteString] = nil
            repositoryWorking.remove(url.absoluteString)
            repositoryFailures[url.absoluteString] = nil
        }
    }

    private func persistRepositories(_ repositories: [URL], entries: [String: [MangaRepositoryEntry]]) throws {
        try FileManager.default.createDirectory(at: MangaLibrary.root, withIntermediateDirectories: true)
        // Commit the membership file last: an orphaned cache is harmless, a
        // subscribed list with no validated entries is not a completed import.
        try JSONEncoder().encode(entries).write(to: Self.entriesFile, options: .atomic)
        try JSONEncoder().encode(repositories).write(to: Self.repositoriesFile, options: .atomic)
        repositoryEntries = entries
        repositoryList = repositories
    }

    /// How many sources a Venera source list holds, or nil when the data isn't one: a JSON array whose
    /// items name a script (`fileName` or a `.js` url) and a `key`.
    public static func listedCount(_ data: Data) -> Int? {
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], !items.isEmpty else { return nil }
        let scripts = items.filter { item in
            let file = MangaValue.string(item["fileName"]) ?? MangaValue.string(item["filename"])
            let link = MangaValue.string(item["url"])
            return item["key"] != nil && (file?.hasSuffix(".js") == true || link?.hasSuffix(".js") == true)
        }
        return scripts.count * 2 >= items.count ? items.count : nil
    }

    /// The sources a repository lists. Addresses are resolved against the index's own address.
    public func entries(of repository: URL) async throws -> [MangaRepositoryEntry] {
        guard Self.isWebAddress(repository) else {
            throw TVError.unsupported("漫画订阅需要有效的 HTTP 或 HTTPS 地址。")
        }
        let (data, origin) = try await HTTPClient().get(repository)
        try Task.checkCancellation()
        return try Self.entries(data, origin: origin)
    }

    private static func entries(_ data: Data, origin: URL) throws -> [MangaRepositoryEntry] {
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], !items.isEmpty else {
            throw TVError.unsupported(L10n.text("This address is not a Venera source list."))
        }
        var seen: Set<String> = []
        var entries: [MangaRepositoryEntry] = []
        for item in items {
            let file = MangaValue.string(item["fileName"]) ?? MangaValue.string(item["filename"])
            let link = MangaValue.string(item["url"])
            guard let key = MangaValue.string(item["key"]), validKey(key),
                  let path = link ?? file, let address = URL(string: path, relativeTo: origin)?.absoluteURL,
                  isWebAddress(address), address.pathExtension.lowercased() == "js" else {
                throw TVError.unsupported("漫画订阅含有无效站点，请检查站点标识和 JS 地址。")
            }
            guard seen.insert(key).inserted else { continue }
            entries.append(MangaRepositoryEntry(name: MangaValue.string(item["name"]) ?? key, key: key, address: address,
                                               version: MangaValue.string(item["version"]) ?? "", description: MangaValue.string(item["description"]) ?? ""))
        }
        return entries
    }

    static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 160 && key != "." && key != ".."
            && !key.contains("/") && !key.contains("\\")
            && key.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private static func isWebAddress(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false
    }

    // MARK: Sources

    /// Downloads a source script and installs it, replacing an installed source with the same key.
    @discardableResult
    public func install(from address: URL) async throws -> MangaInstalledSource {
        guard Self.isWebAddress(address) else { throw TVError.unsupported("漫画站点需要有效的 HTTP 或 HTTPS 地址。") }
        let (data, _) = try await HTTPClient().get(address)
        return try await install(code: String(decoding: data, as: UTF8.self), origin: address)
    }

    @discardableResult
    public func install(_ entry: MangaRepositoryEntry) async throws -> MangaInstalledSource {
        try await install(entry, repository: nil, request: nil)
    }

    private func install(_ entry: MangaRepositoryEntry, repository: URL?, request: UUID?) async throws -> MangaInstalledSource {
        guard Self.isWebAddress(entry.address) else { throw TVError.unsupported("漫画站点需要有效的 HTTP 或 HTTPS 地址。") }
        let (data, _) = try await HTTPClient().get(entry.address)
        return try await install(code: String(decoding: data, as: UTF8.self), origin: entry.address, expectedKey: entry.key,
                                 repository: repository, request: request, entry: entry)
    }

    @discardableResult
    public func install(code: String, origin: URL?) async throws -> MangaInstalledSource {
        try await install(code: code, origin: origin, expectedKey: nil)
    }

    private func install(code: String, origin: URL?, expectedKey: String?, repository: URL? = nil, request: UUID? = nil,
                         entry: MangaRepositoryEntry? = nil) async throws -> MangaInstalledSource {
        let info = try await MangaRuntime.shared.inspect(code: code)
        try Task.checkCancellation()
        guard Self.validKey(info.key) else { throw TVError.unsupported("漫画站点标识无效。") }
        guard expectedKey == nil || expectedKey == info.key else {
            throw TVError.unsupported("下载的漫画脚本与订阅站点不匹配，请更新订阅后重试。")
        }
        let source = MangaInstalledSource(key: info.key, name: info.name, version: info.version, origin: origin, installed: Date(),
                                          revision: PluginChecksum.sha256(Data(code.utf8)), canSearch: info.canSearch)
        try lock.withLock {
            try Task.checkCancellation()
            if let repository {
                let owner = repositoryList.first { url in repositoryEntries[url.absoluteString]?.contains(where: { $0.key == info.key }) == true }
                guard owner == repository, repositoryRequests[repository.absoluteString] == request,
                      let entry, repositoryEntries[repository.absoluteString]?.contains(entry) == true else { throw CancellationError() }
            }
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let script = Self.folder.appendingPathComponent(info.key + ".js")
            let previous = try? Data(contentsOf: script)
            var next = list
            if let index = next.firstIndex(where: { $0.key == source.key }) { next[index] = source } else { next.append(source) }
            do {
                try Data(code.utf8).write(to: script, options: .atomic)
                try JSONEncoder().encode(next).write(to: Self.listFile, options: .atomic)
                list = next
            } catch {
                if let previous { try? previous.write(to: script, options: .atomic) }
                else { try? FileManager.default.removeItem(at: script) }
                throw error
            }
        }
        await MangaRuntime.shared.reset(info.key)
        Diagnostics.shared.record(.info, "manga.install", "source=\(info.key) version=\(info.version)")
        return source
    }

    public func remove(_ key: String) async {
        lock.withLock {
            list.removeAll { $0.key == key }
            save()
        }
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(key + ".js"))
        MangaSourceData.shared.remove(key)
        await MangaRuntime.shared.reset(key)
    }

    public func move(fromOffsets: IndexSet, toOffset: Int) {
        lock.withLock {
            var moved = list
            let items = fromOffsets.map { moved[$0] }
            for index in fromOffsets.sorted(by: >) { moved.remove(at: index) }
            let target = toOffset - fromOffsets.filter { $0 < toOffset }.count
            moved.insert(contentsOf: items, at: max(0, min(target, moved.count)))
            list = moved
            save()
        }
    }

    /// Whether `entry` is newer than what is installed under its key.
    public func hasUpdate(_ entry: MangaRepositoryEntry) -> Bool {
        guard let key = entry.key, let current = installed(key) else { return false }
        return Self.compare(entry.version, current.version) == .orderedDescending
    }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(x.count, y.count) {
            let l = index < x.count ? x[index] : 0, r = index < y.count ? y[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
