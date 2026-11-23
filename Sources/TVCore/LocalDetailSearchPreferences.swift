import Foundation

/// Independent choices for the home catalog and subscription index detail entries.
public enum LocalDetailSearchPreferences {
    public static let homeKey = "local.home.detailSearchEntry.v1"
    public static let indexKey = "local.home.indexDetailSearchEntry.v1"

    public enum HomeEntry: String, CaseIterable, Sendable {
        case pan, quick
        public var title: String { self == .pan ? "盘搜" : "快速搜索" }
    }
    public enum IndexEntry: String, CaseIterable, Sendable {
        case global, quick
        public var title: String { self == .global ? "全局搜索" : "快速搜索" }
    }
    public static func home(defaults: UserDefaults = .standard) -> HomeEntry {
        HomeEntry(rawValue: defaults.string(forKey: homeKey) ?? "") ?? .quick
    }
    public static func index(defaults: UserDefaults = .standard) -> IndexEntry {
        IndexEntry(rawValue: defaults.string(forKey: indexKey) ?? "") ?? .quick
    }
}
