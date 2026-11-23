import Foundation

/// Catalog category evidence shared by detail enrichment and the player's gesture routing.
public enum CatalogVideoCategory {
    case shortDrama, ordinary, unspecified

    public static func classify(_ value: String?) -> Self {
        let text = (value ?? "").folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        if text.contains("短剧") || text.contains("短劇") ||
            text.range(of: #"(?:^|[^a-z])(?:short[ _-]*dramas?|micro[ _-]*dramas?|duan[ _-]*ju)(?:$|[^a-z])"#,
                       options: .regularExpression) != nil { return .shortDrama }
        let ordinary = ["电影", "電影", "电视剧", "電視劇", "连续剧", "連續劇", "综艺", "綜藝", "纪录", "紀錄", "动漫", "動畫", "动画"]
        if ordinary.contains(where: text.contains) ||
            text.range(of: #"\b(?:movie|film|tv series|documentary|anime)\b"#, options: .regularExpression) != nil { return .ordinary }
        return .unspecified
    }

    /// Explicit catalog types supplement genre-only detail, keeping both short dramas and ordinary
    /// titles identifiable. A definite detail type always overrides browsing/listing context.
    static func retaining(_ current: String?, fallback: String?) -> String? {
        guard let fallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty else { return current }
        guard let current, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
        guard classify(current) == .unspecified, classify(fallback) != .unspecified else { return current }
        let labels = fallback.components(separatedBy: CharacterSet(charactersIn: ",，/|"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { classify($0) != .unspecified }
        return labels.isEmpty ? current : ([current] + labels).joined(separator: ",")
    }
}
