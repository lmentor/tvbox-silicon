import Foundation

/// Keep current-site integration flags identical to MacCat's explicit opt-in contract.
public enum LocalSiteIntegration {
    public static func enabled(_ value: JSONValue?) -> Bool {
        switch value {
        case .bool(true), .number(1), .string("1"), .string("true"): true
        default: false
        }
    }

    public static func website(_ url: URL, site: Site) -> URL? {
        guard site.hasSiteSettings, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(parts.host ?? ""),
              parts.port != nil, ["/website", "/website/"].contains(parts.path) else { return nil }
        var query = (parts.queryItems ?? []).filter { $0.name != "site" && $0.name != "embed" }
        query += [URLQueryItem(name: "site", value: site.sourceKey), URLQueryItem(name: "embed", value: "1")]
        parts.queryItems = query
        return parts.url
    }
}

extension Site {
    public var isIndexSource: Bool { LocalSiteIntegration.enabled(raw["index"]) || LocalSiteIntegration.enabled(raw["indexs"]) }
    public var hasSiteSettings: Bool { isCatPawOpen && LocalSiteIntegration.enabled(raw["siteSettings"]) }
    public var supportsLocalLinkChecks: Bool { !isIndexSource && LocalSiteIntegration.enabled(raw["panCheck"]) }
}
