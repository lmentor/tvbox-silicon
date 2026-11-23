import Foundation

/// Room bookmarks name the live subscription as well as the provider. Only a playback request carries a quality.
public struct IPTVRoomAddress: Hashable, Sendable {
    public let sourceID: String
    public let platformID: String
    public let roomID: String
    public let channelName: String?
    public private(set) var quality: Int?

    public init(sourceID: String, platformID: String, roomID: String, channelName: String? = nil) {
        self.sourceID = sourceID
        self.platformID = platformID
        self.roomID = roomID
        self.channelName = channelName
    }

    public init?(_ url: URL) {
        guard url.scheme == "yingxia-iptv-room", url.host == "room",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
        guard let source = value("source"), !source.isEmpty, let provider = value("platform"), !provider.isEmpty,
              let room = value("id"), !room.isEmpty else { return nil }
        self.init(sourceID: source, platformID: provider, roomID: room, channelName: value("ch"))
        quality = value("q").flatMap(Int.init)
    }

    public func withQuality(_ quality: Int?) -> Self {
        var next = self
        next.quality = quality
        return next
    }

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = "yingxia-iptv-room"
        parts.host = "room"
        var query = [URLQueryItem(name: "source", value: sourceID), URLQueryItem(name: "platform", value: platformID),
                     URLQueryItem(name: "id", value: roomID)]
        if let channelName { query.append(URLQueryItem(name: "ch", value: channelName)) }
        if let quality { query.append(URLQueryItem(name: "q", value: String(quality))) }
        parts.queryItems = query
        return parts.url!
    }
}

public struct IPTVPlatform: Codable, Hashable, Identifiable, Sendable {
    enum Adapter: String, Codable { case rooms, catalog }
    public let id: String
    public let name: String
    let site: Site
    let origin: URL
    let adapter: Adapter
    public let account: String?
    let remoteCatRoute: Bool
    let searchNeedsAccount: Bool
    let chat: String?

    public static func registered(in object: [String: JSONValue], origin: URL?, headers: [String: String] = [:], namespace: String = "") throws -> [Self] {
        var result: [Self] = []
        var seen: Set<String> = []
        var failures: [String] = []
        func add(_ entry: JSONValue, adapter: Adapter, remoteCatRoute: Bool = false) {
            guard var fields = entry.object else { return }
            let isRoomScript = adapter == .rooms
            let route = fields["api"]?.string ?? ""
            if !isRoomScript, !PlaybackSourceContext.isLive(route: fields["catPawOpen"]?.string ?? route, fields: fields) { return }
            let key = (isRoomScript ? fields["id"] : fields["key"])?.string ?? ""
            let name = Site.localizedName(fields) ?? fields["name"]?.string ?? key
            let id = (namespace.isEmpty ? "" : namespace + "/") + adapter.rawValue + "." + key
            guard !key.isEmpty, !route.isEmpty else { failures.append(name); return }
            let type = isRoomScript ? 3 : (remoteCatRoute ? 4 : fields["type"]?.int ?? 0)
            let legacyPython = type == 3 && route.hasPrefix("py_")
            let api = legacyPython ? (fields["ext"]?.string ?? route) : route
            guard let endpoint = try? WebAddress.resolve(api, relativeTo: origin) else { failures.append(name); return }
            // Only the app's canonical provider document can request an app-managed provider credential.
            // Every other room adapter may use credentials explicitly supplied in that registration's ext.
            let trusted = isRoomScript && origin == CloudSources.address
            let account = trusted ? fields["account"]?.string : nil
            fields.removeValue(forKey: "yingxia")
            fields.removeValue(forKey: "jar")
            let supplied = PlaybackNormalization.headers(fields["header"] ?? fields["headers"])
            var scopedHeaders = IPTVHeaders.inherited(headers, from: origin, to: endpoint)
            for (key, value) in supplied {
                scopedHeaders = scopedHeaders.filter { $0.key.caseInsensitiveCompare(key) != .orderedSame }
                scopedHeaders[key] = value
            }
            fields["header"] = .object(scopedHeaders.mapValues(JSONValue.string))
            fields["key"] = .string(key)
            fields["api"] = .string(endpoint.absoluteString)
            if legacyPython { fields["ext"] = .string(endpoint.absoluteString) }
            if let account { fields["yingxia"] = .object(["builtin": .bool(true), "account": .string(account)]) }
            let site = Site(key: "iptv." + id, name: name, type: type, api: legacyPython ? route : endpoint.absoluteString,
                            raw: fields, detectedRuntime: isRoomScript ? .javascript : nil)
            guard [.api, .javascript, .python].contains(site.runtime) else { failures.append(name); return }
            guard seen.insert(id).inserted else { return }
            result.append(Self(id: id, name: name, site: site, origin: origin ?? endpoint, adapter: adapter,
                               account: account, remoteCatRoute: remoteCatRoute, searchNeedsAccount: fields["searchNeedsAccount"] == .bool(true),
                               chat: fields["chat"]?.string))
        }
        for entry in object["yingxiaLive"]?.array ?? [] { add(entry, adapter: .rooms) }
        for entry in object["sites"]?.array ?? [] { add(entry, adapter: .catalog) }
        // A running CatPawOpen HTTP service exposes its routes in video.sites. Bundles unpacked by
        // CatPawOpen.subscription instead have a JS api and the route in catPawOpen, handled above.
        for entry in object["video"]?.object?["sites"]?.array ?? [] { add(entry, adapter: .catalog, remoteCatRoute: true) }
        if result.isEmpty, !failures.isEmpty {
            throw TVError.unsupported("直播平台缺少兼容的脚本或 HTTP 接口：" + failures.joined(separator: "、"))
        }
        return result
    }

    /// Scope runtime sessions to the selected record, preserving the provider's original spider key.
    func scopedSite(sourceID: String) -> Site {
        var fields = site.raw
        // The native API client attaches these to its catalog endpoint. Only the reply's own fields
        // may authorize another host for playback.
        if site.native { fields.removeValue(forKey: "header"); fields.removeValue(forKey: "headers") }
        return Site(key: site.key + "@" + sourceID, name: name, type: site.type, api: site.api, raw: fields,
             detectedRuntime: site.detectedRuntime)
    }
}
