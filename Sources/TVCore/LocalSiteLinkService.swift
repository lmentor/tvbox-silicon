import Foundation

public enum LocalSiteLinkService {
    public static func check(site: Site, videos: [Video], refresh: Bool) async throws -> PanCheckResult {
        guard site.supportsLocalLinkChecks else { return try PanCheckResult(json: .object(["enabled": .bool(false), "items": .array([])])) }
        let rows = videos.map { video -> JSONValue in
            var fields: [String: JSONValue] = ["id": .string(video.id)]
            if video.isFolder { fields["kind"] = .string("folder") }
            if let share = video.panShare { fields["panShare"] = share.json }
            return .object(fields)
        }
        return try await PanCheckResult(json: MobileMediaServices.call("catalog.pan.check", [
            "site": .object(["panCheck": .bool(true), "indexs": .bool(site.isIndexSource)]),
            "items": .array(rows), "refresh": .bool(refresh),
        ]))
    }
}

extension Video {
    /// Matches MacCat's leaf rule. The Node normalizer confirms the exact provider;
    /// IDs that merely contain an embedded URL are never candidates.
    public var hasLocalCheckCandidate: Bool {
        guard !isFolder, action == nil else { return false }
        if panShare != nil { return true }
        let address = id.lowercased()
        return id.utf8.count <= 2048 && (address.hasPrefix("https://") || address.hasPrefix("http://")
            || address.hasPrefix("magnet:?") || address.hasPrefix("ed2k://"))
    }
}
