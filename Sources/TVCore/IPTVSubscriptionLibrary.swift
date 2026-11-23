import Foundation
import Perception

public struct IPTVRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var enabled = true
    public var address: String?
    public var filename: String?
    public var resourceBase: URL?
    public var format = ""
    public var stations: [IPTVStation] = []
    public var platforms: [IPTVPlatform] = []
    public var epgURLs: [String] = []
    public var guideOverride: String?
    public var timeZoneID = TimeZone.current.identifier
    public var lastUpdated: Date?
    public var lastError: String?
    public var requiresAuthorization = false
    public var asSingle = false
}

private struct IPTVSourceInput: Codable, Sendable {
    var headers: [String: String] = [:]
    var localData: Data?
    var asSingle = false
}

private struct IPTVSourceSnapshot: Codable, Sendable {
    var record: IPTVRecord
    var input: IPTVSourceInput
}

public struct IPTVPreview: Sendable {
    fileprivate let snapshot: IPTVSourceSnapshot
    fileprivate let replacing: String?
    fileprivate let generation: UUID?
    fileprivate let libraryGeneration: UUID
    public let warnings: [String]
    public var name: String { snapshot.record.name }
    public var format: String { snapshot.record.format }
    public var stations: [IPTVStation] { snapshot.record.stations }
    public var platforms: [IPTVPlatform] { snapshot.record.platforms }
}

@MainActor @Perceptible public final class IPTVLibrary {
    public static let shared = IPTVLibrary(directory: URL.applicationSupportDirectory.appendingPathComponent("IPTVLibrary"))
    nonisolated public static let maximumDocumentBytes = 20_000_000

    public private(set) var records: [IPTVRecord] = []
    public private(set) var refreshingIDs: Set<String> = []
    public private(set) var loadError: String?

    private let directory: URL
    // Private inputs and channel snapshots stay in protected, per-subscription files.
    // One atomic manifest publishes the complete new order and all changed versions.
    @PerceptionIgnored private var inputs: [String: IPTVSourceInput] = [:]
    @PerceptionIgnored private var files: [String: String] = [:]
    @PerceptionIgnored private var generations: [String: UUID] = [:]
    @PerceptionIgnored private var jobs: [String: Task<IPTVPreview, Error>] = [:]
    @PerceptionIgnored private var libraryGeneration = UUID()
    private var manifest: URL { directory.appendingPathComponent("index.json") }

    public init(directory: URL) {
        self.directory = directory
        do {
            let order: [String]
            do { order = try JSONDecoder().decode([String].self, from: Data(contentsOf: manifest)) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return }
            var loaded: [IPTVSourceSnapshot] = []
            var versions: [String: String] = [:]
            for file in order {
                guard UUID(uuidString: file) != nil else { throw Self.invalidBackup }
                let data = try Data(contentsOf: directory.appendingPathComponent(file))
                let entry = try JSONDecoder().decode(IPTVSourceSnapshot.self, from: data)
                let id = entry.record.id
                guard UUID(uuidString: id) != nil, versions.updateValue(file, forKey: id) == nil else { throw Self.invalidBackup }
                loaded.append(entry)
            }
            files = versions
            inputs = Dictionary(uniqueKeysWithValues: loaded.map { ($0.record.id, $0.input) })
            records = loaded.map(\.record)
        } catch {
            loadError = "无法读取直播订阅库，请检查可用存储后重新打开。"
        }
    }

    public func headers(for id: String) -> [String: String] { inputs[id]?.headers ?? [:] }

    public func preview(address: String, name: String = "", headers: [String: String] = [:],
                        asSingle: Bool = false, replacing: String? = nil) async throws -> IPTVPreview {
        let url = try MediaAddress.resolve(address)
        if url.host?.lowercased() == "sources.yingxia.invalid" {
            return try await previewSavedSource(url, name: name, headers: headers, replacing: replacing)
        }
        let record = try draft(replacing, name: name, fallback: url.host ?? "直播订阅")
        return try await prepare(record: record, address: url, filename: nil,
                                 input: IPTVSourceInput(headers: headers, asSingle: asSingle || MediaAddress.streamingSchemes.contains(url.scheme?.lowercased() ?? "")), replacing: replacing)
    }

    /// A normal subscription copy can be explicitly entered in live settings. Resolve it
    /// once: future refreshes use the original remote resource or our own local file copy.
    private func previewSavedSource(_ url: URL, name: String, headers: [String: String],
                                    replacing: String?) async throws -> IPTVPreview {
        let parts = url.pathComponents.filter { $0 != "/" }
        let sources = try await LocalSourceLibrary.shared.records()
        guard let source = sources.first(where: { $0.id == parts.first }), source.group == .subscription,
              url == source.address || url == source.asset("subscription.json") || url == source.asset("index.js") else {
            throw TVError.unsupported("找不到此订阅副本，请填写原始订阅地址或重新选择清单。")
        }
        let title = name.isEmpty ? source.name : name
        if let remote = source.input.first(where: { ["http", "https"].contains($0.scheme?.lowercased() ?? "") &&
                                                    $0.host?.lowercased() != "sources.yingxia.invalid" }) {
            return try await preview(address: remote.absoluteString, name: title, headers: headers, replacing: replacing)
        }
        guard source.format == "tvbox", let data = try LocalSourceLibrary.data(at: source.asset("subscription.json")) else {
            throw TVError.unsupported("请填写该直播接口包的远程地址。")
        }
        let filename = source.input.first?.lastPathComponent ?? "subscription.json"
        return try await preview(data: data, filename: filename, name: title, headers: headers, replacing: replacing)
    }

    public func preview(data: Data, filename: String, name: String = "", headers: [String: String] = [:],
                        replacing: String? = nil) async throws -> IPTVPreview {
        guard data.count <= Self.maximumDocumentBytes else { throw IPTVSourceReader.tooLarge }
        let file = URL(fileURLWithPath: filename).lastPathComponent
        let record = try draft(replacing, name: name, fallback: (file as NSString).deletingPathExtension)
        return try await prepare(record: record, address: nil, filename: file,
                                 input: IPTVSourceInput(headers: headers, localData: data), replacing: replacing)
    }

    public func previewLocal(_ id: String, name: String, headers: [String: String]) async throws -> IPTVPreview {
        let record = try existing(id)
        guard let data = inputs[id]?.localData, let filename = record.filename else {
            throw TVError.unsupported("请重新选择原直播清单。")
        }
        return try await preview(data: data, filename: filename, name: name, headers: headers, replacing: id)
    }

    private func draft(_ replacing: String?, name: String, fallback: String) throws -> IPTVRecord {
        if let loadError { throw TVError.unsupported(loadError) }
        var record: IPTVRecord
        if let replacing {
            record = try existing(replacing)
        } else {
            record = IPTVRecord(id: UUID().uuidString, name: "")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        record.name = trimmed.isEmpty ? (fallback.isEmpty ? "直播订阅" : fallback) : trimmed
        return record
    }

    private func prepare(record: IPTVRecord, address: URL?, filename: String?, input: IPTVSourceInput,
                         replacing: String?) async throws -> IPTVPreview {
        let generation = replacing.flatMap { generations[$0] }
        let currentLibrary = libraryGeneration
        let (document, finalURL) = try await IPTVSourceReader.read(input: input, address: address, record: record)
        try Task.checkCancellation()
        var record = record
        record.address = address?.absoluteString
        record.filename = filename
        record.asSingle = input.asSingle
        record.resourceBase = finalURL
        record.format = document.format
        record.stations = document.stations
        record.platforms = document.platforms
        record.epgURLs = document.epgURLs
        record.lastUpdated = Date()
        record.lastError = nil
        record.requiresAuthorization = false
        return IPTVPreview(snapshot: IPTVSourceSnapshot(record: record, input: input), replacing: replacing,
                           generation: generation, libraryGeneration: currentLibrary, warnings: document.warnings)
    }

    public func commit(_ preview: IPTVPreview, guideOverride: String? = nil, timeZoneID: String? = nil) throws {
        let id = preview.snapshot.record.id
        guard preview.libraryGeneration == libraryGeneration,
              preview.replacing == nil || generations[id] == preview.generation else { throw Self.stale }
        var entry = preview.snapshot
        if let value = guideOverride { entry.record.guideOverride = try Self.guideURL(value) }
        if let timeZoneID { entry.record.timeZoneID = try Self.zone(timeZoneID) }
        var next = records
        if preview.replacing != nil {
            guard let index = next.firstIndex(where: { $0.id == id }) else { throw Self.stale }
            next[index] = entry.record
        } else {
            guard !files.keys.contains(id) else { throw Self.stale }
            next.append(entry.record)
        }
        try publish(next, changed: [entry])
        invalidate(id)
    }

    public func rename(_ id: String, name: String) throws {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw TVError.unsupported("请输入直播订阅名称。") }
        try change(id) { $0.name = value }
    }

    public func setGuide(_ id: String, override: String?, timeZoneID: String) throws {
        let guide = try Self.guideURL(override ?? "")
        let zone = try Self.zone(timeZoneID)
        try change(id) { $0.guideOverride = guide; $0.timeZoneID = zone }
    }

    private static func guideURL(_ value: String) throws -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // XMLTV and per-channel EPG templates are resolved by the guide reader.
        if trimmed.isEmpty { return nil }
        let resolved = trimmed.replacingOccurrences(of: "{name}", with: "channel")
            .replacingOccurrences(of: "{date}", with: "2026-01-01")
        guard !resolved.contains("{"), !resolved.contains("}") else {
            throw TVError.unsupported("节目单地址只支持 {name} 和 {date} 占位符。")
        }
        _ = try WebAddress.resolve(resolved)
        return trimmed
    }

    private static func zone(_ id: String) throws -> String {
        guard TimeZone(identifier: id) != nil else { throw TVError.unsupported("节目单时区无效。") }
        return id
    }

    public func setEnabled(_ id: String, enabled: Bool) throws { try change(id) { $0.enabled = enabled } }

    public func delete(_ id: String) throws {
        _ = try existing(id)
        try publish(records.filter { $0.id != id }, changed: [])
        invalidate(id)
    }

    public func move(from offsets: IndexSet, to destination: Int) throws {
        guard !offsets.isEmpty, offsets.allSatisfy(records.indices.contains), (0...records.count).contains(destination) else { return }
        let moved = offsets.map { records[$0] }
        var next = records.enumerated().compactMap { offsets.contains($0.offset) ? nil : $0.element }
        next.insert(contentsOf: moved, at: destination - offsets.count(in: 0..<destination))
        try publish(next, changed: [])
    }

    public func cancel(_ id: String) { invalidate(id) }

    private func invalidate(_ id: String) {
        generations[id] = UUID()
        jobs.removeValue(forKey: id)?.cancel()
        refreshingIDs.remove(id)
    }

    public func refresh(_ id: String) async throws {
        let record = try existing(id)
        let input = inputs[id] ?? IPTVSourceInput()
        invalidate(id)
        let generation = generations[id]
        let job = Task {
            try await self.prepare(record: record, address: try record.address.map { try MediaAddress.resolve($0) }, filename: record.filename,
                                   input: input, replacing: id)
        }
        jobs[id] = job
        refreshingIDs.insert(id)
        defer {
            if generations[id] == generation { jobs[id] = nil; refreshingIDs.remove(id) }
        }
        do {
            let result = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            try Task.checkCancellation()
            guard generations[id] == generation else { throw CancellationError() }
            try commit(result)
        } catch {
            guard generations[id] == generation, !job.isCancelled, !Task.isCancelled else { throw CancellationError() }
            let reason = Self.reason(error)
            try change(id) { $0.lastError = reason }
            throw TVError.unsupported(reason)
        }
    }

    private func existing(_ id: String) throws -> IPTVRecord {
        guard let value = records.first(where: { $0.id == id }) else { throw Self.stale }
        return value
    }

    private func change(_ id: String, _ edit: (inout IPTVRecord) -> Void) throws {
        guard let index = records.firstIndex(where: { $0.id == id }), let input = inputs[id] else { throw Self.stale }
        var next = records
        edit(&next[index])
        try publish(next, changed: [IPTVSourceSnapshot(record: next[index], input: input)])
        invalidate(id)
    }

    private func publish(_ next: [IPTVRecord], changed: [IPTVSourceSnapshot]) throws {
        if let loadError { throw TVError.unsupported(loadError) }
        var versions = files
        var newInputs = inputs
        var staged: [URL] = []
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var protectedDirectory = directory
            try protectedDirectory.setResourceValues(values)
            for entry in changed {
                let file = UUID().uuidString
                let url = directory.appendingPathComponent(file)
                try Self.write(try JSONEncoder().encode(entry), to: url)
                staged.append(url)
                versions[entry.record.id] = file
                newInputs[entry.record.id] = entry.input
            }
            let order = try next.map { record in
                guard let file = versions[record.id] else { throw Self.invalidBackup }
                return file
            }
            try Self.write(try JSONEncoder().encode(order), to: manifest)
            // Publishing the manifest is the commit point. Cleanup cannot roll it back.
            let living = Set(next.map(\.id))
            let oldFiles = Set(files.values).subtracting(order)
            files = versions.filter { living.contains($0.key) }
            inputs = newInputs.filter { living.contains($0.key) }
            records = next
            for file in oldFiles { try? FileManager.default.removeItem(at: directory.appendingPathComponent(file)) }
        } catch {
            for url in staged { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    private static func write(_ data: Data, to url: URL) throws {
        #if os(iOS) || os(tvOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    nonisolated fileprivate static var stale: TVError { .unsupported("直播订阅已更改，请重新预览。") }
    nonisolated fileprivate static var invalidBackup: TVError { .unsupported("直播订阅备份包含无效记录。") }
    nonisolated fileprivate static func webURL(_ string: String) throws -> URL {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { throw TVError.invalidURL }
        return url
    }
    nonisolated fileprivate static func reason(_ error: Error) -> String {
        if let reason = error as? TVError { return reason.localizedDescription }
        if let error = error as? URLError { return "读取直播订阅失败（网络错误 \(error.code.rawValue)）。" }
        return "直播订阅内容损坏或无法读取。"
    }
}

/// Each preview owns a session and traversal budget. The actor shares those limits across
/// overlapping child downloads without sharing cookies or cancellation with another import.
private actor IPTVSourceReader {
    static var tooLarge: TVError { .unsupported("直播清单超过 20 MB，请选择较小的清单。") }
    static var timedOut: TVError { .unsupported("直播订阅读取超时，请检查网络后重试。") }
    let session: URLSession
    let deadline = ContinuousClock.now.advanced(by: .seconds(45))
    var remainingDocuments = 128
    var remainingBytes = 50_000_000
    let sourceID: String
    var childFailures = 0
    var firstChildError: String?

    init(sourceID: String) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration)
        self.sourceID = sourceID
    }

    static func read(input: IPTVSourceInput, address: URL?, record: IPTVRecord) async throws -> (IPTVDocument, URL?) {
        let reader = IPTVSourceReader(sourceID: record.id)
        let session = reader.session
        // A per-request timeout restarts for every child (and for each arriving byte).
        // End the entire traversal even when a server keeps trickling an unfinished list.
        let watchdog = Task {
            do { try await Task.sleep(until: reader.deadline, clock: .continuous) }
            catch { return }
            session.invalidateAndCancel()
        }
        defer { watchdog.cancel(); session.invalidateAndCancel() }
        do {
            return try await withTaskCancellationHandler {
                try await reader.read(input: input, address: address, record: record)
            } onCancel: { session.invalidateAndCancel() }
        } catch {
            try Task.checkCancellation()
            if ContinuousClock.now >= reader.deadline { throw timedOut }
            throw error
        }
    }

    private func read(input: IPTVSourceInput, address: URL?, record: IPTVRecord) async throws -> (IPTVDocument, URL?) {
        let root: IPTVDocument
        var finalAddress = address
        if let data = input.localData {
            root = try IPTVDocument.parse(data, baseURL: nil, title: record.name, sourceID: record.id, headers: input.headers)
        } else if let address {
            if input.asSingle {
                root = .direct(url: address, title: record.name, sourceID: record.id, headers: input.headers)
            } else {
                (root, finalAddress) = try await fetch(address, title: record.name, namespace: "", headers: input.headers, guideURL: nil)
            }
        } else {
            throw TVError.unsupported("请重新选择原直播清单或填写订阅地址。")
        }
        var result = IPTVDocument(format: root.format)
        try await expand(root, into: &result, ancestors: Set([finalAddress, address].compactMap { $0 }), concurrentChildren: true)
        guard !result.stations.isEmpty || !result.platforms.isEmpty else {
            throw TVError.unsupported(firstChildError ?? result.warnings.first ?? "未找到可导入的直播频道。")
        }
        if childFailures > 0 && (!record.stations.isEmpty || !record.platforms.isEmpty) {
            throw TVError.unsupported(firstChildError ?? "子清单读取失败，保留上次成功的频道目录。")
        }
        var ids = Set<String>()
        result.stations = result.stations.filter { ids.insert($0.id).inserted }
        var guides = Set<String>()
        result.epgURLs = result.epgURLs.filter { guides.insert($0).inserted }
        var platforms = Set<IPTVPlatform>()
        result.platforms = result.platforms.filter { platforms.insert($0).inserted }
        return (result, finalAddress)
    }

    private func expand(_ doc: IPTVDocument, into result: inout IPTVDocument, ancestors: Set<URL>,
                        concurrentChildren: Bool = false) async throws {
        result.epgURLs += doc.epgURLs
        result.platforms += doc.platforms
        result.warnings += doc.warnings
        // Only root branches run in parallel. Descendants stay sequential within their
        // branch, so arbitrarily nested configurations never exceed four active requests.
        let children = concurrentChildren ? try await expandChildren(doc.children, ancestors: ancestors) : [:]
        for entry in doc.entries {
            try Task.checkCancellation()
            switch entry {
            case .station(let index):
                result.stations.append(doc.stations[index])
            case .child(let index):
                let child: IPTVDocument
                if let loaded = children[index] { child = loaded }
                else { child = try await expandChild(doc.children[index], index: index, ancestors: ancestors) }
                result.stations += child.stations
                result.platforms += child.platforms
                result.epgURLs += child.epgURLs
                result.warnings += child.warnings
            }
        }
    }

    private func expandChildren(_ children: [IPTVChild], ancestors: Set<URL>) async throws -> [Int: IPTVDocument] {
        try await withThrowingTaskGroup(of: (Int, IPTVDocument).self) { group in
            var next = 0
            func enqueue(_ index: Int) {
                let child = children[index]
                group.addTask { (index, try await self.expandChild(child, index: index, ancestors: ancestors)) }
            }
            while next < min(4, children.count) { enqueue(next); next += 1 }
            var results: [Int: IPTVDocument] = [:]
            while let (index, document) = try await group.next() {
                results[index] = document
                if next < children.count { enqueue(next); next += 1 }
            }
            return results
        }
    }

    private func expandChild(_ child: IPTVChild, index: Int, ancestors: Set<URL>) async throws -> IPTVDocument {
        var result = IPTVDocument(format: "")
        do {
            try checkDeadline()
            guard remainingDocuments > 0, ancestors.count < 10, !ancestors.contains(child.url) else {
                throw TVError.unsupported("子清单循环引用或超过嵌套上限。")
            }
            remainingDocuments -= 1
            let (nested, finalURL) = try await fetch(child.url, title: child.name, namespace: child.namespace,
                                                     headers: child.headers, guideURL: child.guideURL)
            guard !ancestors.contains(finalURL) else { throw TVError.unsupported("子清单循环引用。") }
            if nested.stations.isEmpty && nested.children.isEmpty && nested.platforms.isEmpty {
                throw TVError.unsupported(nested.warnings.first ?? "子清单没有可用的直播频道。")
            }
            try await expand(nested, into: &result, ancestors: ancestors.union([child.url, finalURL]))
            if let declaredGuide = child.guideURL {
                // The parent's lives[] entry may bind credentials to a guide at the
                // original child host while the playlist itself redirects to a CDN.
                for offset in result.stations.indices where result.stations[offset].guideURL == declaredGuide {
                    result.stations[offset].bindGuide(headers: child.headers, origin: child.url)
                }
            }
        } catch {
            try Task.checkCancellation()
            let reason = ContinuousClock.now >= deadline ? Self.timedOut.localizedDescription : IPTVLibrary.reason(error)
            let warning = "第 \(index + 1) 项子清单（\(child.name)）：" + reason
            if firstChildError == nil { firstChildError = warning }
            childFailures += 1
            result.warnings.append(warning)
        }
        return result
    }

    private func checkDeadline() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw Self.timedOut }
    }

    private func fetch(_ address: URL, title: String, namespace: String, headers: [String: String],
                       guideURL: String?) async throws -> (IPTVDocument, URL) {
        try checkDeadline()
        let url = try IPTVLibrary.webURL(address.absoluteString)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue(HTTPClient.subscriptionUserAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            guard !key.isEmpty, key.utf8.allSatisfy({ (33...126).contains($0) && $0 != 58 }),
                  !value.contains(where: { $0.isNewline || $0 == "\0" }) else { throw TVError.unsupported("直播订阅请求头无效。") }
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (bytes, response) = try await session.bytes(for: request, delegate: IPTVRedirectPolicy())
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, let finalURL = http.url else { throw TVError.invalidURL }
        guard (200..<300).contains(http.statusCode) else { throw TVError.http(http.statusCode) }
        let scope = IPTVHeaders.inherited(headers, from: url, to: finalURL).filter { field, value in
            // Compare with the final hop as well: an A → B → A redirect must not
            // restore credentials that were discarded before reaching B.
            bytes.task.currentRequest?.value(forHTTPHeaderField: field) == value
        }
        func direct() -> (IPTVDocument, URL) {
            (.direct(url: finalURL, title: title, sourceID: sourceID, namespace: namespace, headers: scope, guideURL: guideURL), finalURL)
        }
        let mime = (http.mimeType ?? "").lowercased()
        if (mime.hasPrefix("video/") || mime.hasPrefix("audio/") || mime == "application/x-flv") &&
            !mime.contains("mpegurl") && !mime.contains("m3u") { return direct() }
        var data = Data()
        // TVBox may wrap the configuration after a binary image prefix. Keep reading
        // within the existing document/time budgets so SubscriptionDocument can unwrap it.
        for try await byte in bytes {
            guard data.count < IPTVLibrary.maximumDocumentBytes, remainingBytes > 0 else { throw Self.tooLarge }
            remainingBytes -= 1
            data.append(byte)
            if data.count.isMultiple(of: 65536) { try checkDeadline() }
            if data.count == 3, data.elementsEqual([0x46, 0x4c, 0x56]) { return direct() }
            if data.count == 377, data[0] == 0x47 && data[188] == 0x47 && data[376] == 0x47 { return direct() }
        }
        try checkDeadline()
        if namespace.isEmpty, let bundle = CatPawOpen.bundle(data, at: finalURL) {
            let subscription = try await CatPawOpen.subscription(bundle: bundle, origin: finalURL, http: HTTPClient(session: session))
            data = try JSONEncoder().encode(subscription.raw)
        }
        let doc = try IPTVDocument.parse(data, baseURL: finalURL, title: title, sourceID: sourceID, namespace: namespace,
                                         headers: scope, guideURL: guideURL)
        return (doc, finalURL)
    }
}

final class IPTVRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let nextURL = request.url, (try? IPTVLibrary.webURL(nextURL.absoluteString)) != nil else {
            completionHandler(nil)
            return
        }
        var next = request
        let fields = request.allHTTPHeaderFields ?? [:]
        let allowed = IPTVHeaders.inherited(fields, from: response.url, to: nextURL)
        for field in fields.keys where allowed[field] == nil {
            next.setValue(nil, forHTTPHeaderField: field)
        }
        // URLSession can omit Authorization even on a same-origin redirect. Restore
        // only the preceding hop's permitted fields; originalRequest would revive
        // credentials after a cross-origin redirect later returns to the source.
        if let previous = task.currentRequest {
            let forwarded = IPTVHeaders.inherited(previous.allHTTPHeaderFields ?? [:], from: previous.url, to: nextURL)
            for (field, value) in forwarded where next.value(forHTTPHeaderField: field) == nil {
                next.setValue(value, forHTTPHeaderField: field)
            }
        }
        completionHandler(next)
    }
}

extension IPTVLibrary {
    /// Portable records contain the recoverable channel catalog. The raw imported document,
    /// request headers and provider scripts belong only to the protected local source.
    public func portableRecords() throws -> [IPTVRecord] {
        if let loadError { throw TVError.unsupported(loadError) }
        return records.map { record in
            Self.portable(record, hasPrivateHeaders: !(inputs[record.id]?.headers.isEmpty ?? true))
        }
    }

    public func restorePortable(_ incoming: [IPTVRecord], replace: Bool) throws {
        try Self.validatePortable(incoming)
        let retained = replace ? [] : records
        let ids = Set(retained.map(\.id))
        let entries = incoming.filter { !ids.contains($0.id) }.map { record in
            var record = record
            record.enabled = false
            return IPTVSourceSnapshot(record: record, input: IPTVSourceInput(asSingle: record.asSingle))
        }
        try publish(retained + entries.map(\.record), changed: entries)
        invalidateAll()
    }

    public func privateSnapshot() throws -> Data {
        if let loadError { throw TVError.unsupported(loadError) }
        let entries = try records.map { record in
            guard let input = inputs[record.id] else { throw Self.invalidBackup }
            return IPTVSourceSnapshot(record: record, input: input)
        }
        return try JSONEncoder().encode(entries)
    }

    public func restorePrivate(_ data: Data) throws {
        let entries = try JSONDecoder().decode([IPTVSourceSnapshot].self, from: data)
        let records = entries.map(\.record)
        try Self.checkIdentities(records)
        try publish(records, changed: entries)
        invalidateAll()
    }

    private func invalidateAll() {
        libraryGeneration = UUID()
        for id in Array(jobs.keys) { invalidate(id) }
        generations.removeAll()
    }

    nonisolated public static func validatePortable(_ records: [IPTVRecord]) throws {
        try checkIdentities(records)
        for record in records {
            guard portable(record, hasPrivateHeaders: false) == record else { throw invalidBackup }
        }
    }

    nonisolated private static func checkIdentities(_ records: [IPTVRecord]) throws {
        guard Set(records.map(\.id)).count == records.count else { throw invalidBackup }
        for record in records {
            guard UUID(uuidString: record.id) != nil, !record.name.isEmpty,
                  TimeZone(identifier: record.timeZoneID) != nil,
                  Set(record.stations.map(\.id)).count == record.stations.count else { throw invalidBackup }
            for station in record.stations {
                guard station.id.utf8.count == 64, station.id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      !station.name.isEmpty else { throw invalidBackup }
            }
        }
    }

    nonisolated private static func portable(_ record: IPTVRecord, hasPrivateHeaders: Bool) -> IPTVRecord {
        var result = record
        result.address = portableURL(record.address)
        result.resourceBase = nil
        result.guideOverride = portableURL(record.guideOverride)
        result.epgURLs = record.epgURLs.compactMap(portableURL)
        result.platforms = []
        result.lastError = nil
        result.enabled = false
        if let file = record.filename { result.filename = URL(fileURLWithPath: file).lastPathComponent }
        var needsInput = hasPrivateHeaders || record.requiresAuthorization || result.address != record.address ||
            result.guideOverride != record.guideOverride || result.epgURLs != record.epgURLs || !record.platforms.isEmpty
        result.stations = record.stations.map { station in
            var station = station
            station.logo = station.logo.flatMap { portableURL($0.absoluteString) }.flatMap(URL.init(string:))
            let safeGuide = portableURL(station.guideURL)
            if safeGuide != station.guideURL || !(station.guideHeaders?.isEmpty ?? true) { needsInput = true }
            station.guideURL = safeGuide
            station.guideOrigin = nil
            station.guideHeaders = nil
            station.lines = station.lines.compactMap { original in
                guard portableURL(original.url.absoluteString) != nil else { needsInput = true; return nil }
                var line = original
                if !line.headers.isEmpty { needsInput = true }
                line.headers = [:]
                // Catch-up templates can embed private values even outside normal URL components.
                if let catchup = line.catchup, portableURL(catchup.source) == nil || catchup.replace != nil {
                    line.catchup = nil
                }
                return line
            }
            return station
        }
        result.requiresAuthorization = needsInput
        return result
    }

    /// Only carry complete, usable public URLs. Dropping one token parameter from a signed
    /// URL would create a broken line and could still expose credentials in an adjacent field.
    nonisolated private static func portableURL(_ value: String?) -> String? {
        guard let value, let url = try? MediaAddress.resolve(value), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.fragment == nil else { return nil }
        let safeQuery: Set<String> = ["id", "channel", "ch", "cid", "name", "date", "format", "type", "lang", "quality", "v", "version"]
        for item in parts.queryItems ?? [] {
            guard safeQuery.contains(item.name.lowercased()), let field = item.value, field.count <= 96,
                  field.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_.{}".unicodeScalars.contains($0) }) else { return nil }
        }
        let path = parts.path.lowercased()
        let hiddenPath = #"/(?:live|movie|series|timeshift)/[^/]+/[^/]+/[^/]+|/(?:token|auth|signature|password|credential)(?:/|=)|(?:^|/)[^/]+/[^/]+/\d+\.(?:ts|m3u8)$|[a-f0-9]{32,}|eyj[a-z0-9_-]+\.[a-z0-9_-]+\.|[?&;](?:token|key|auth|sign|pwd)="#
        guard path.range(of: hiddenPath, options: .regularExpression) == nil,
              !parts.path.contains("|"), !parts.path.contains("@") else { return nil }
        return value
    }
}
