import Foundation

public enum LocalTrailerPreferences {
    public static let autoplayKey = "local.home.autoplayTrailers"
}

public enum LocalAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    public static let key = "local.appearance"
    case system, light, dark
    public var id: String { rawValue }
    public var title: String { switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" } }
}

public enum LocalDockPreferences {
    public static let history = "local.dock.showHistory"
    public static let live = "local.dock.showLive"
    public static let music = "local.dock.showMusic"
}
