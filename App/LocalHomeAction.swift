import Foundation

/// Dock clicks have their own preference; the launch destination remains independent.
enum LocalHomeAction: String, CaseIterable, Identifiable {
    static let enabledKey = "local.home.action.enabled"
    static let modeKey = "local.home.action.mode"
    static let fixedKey = "local.home.action.fixed"
    static let previousKey = "local.home.action.previous"

    case previous, fixed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .previous: "单击切换到之前的界面"
        case .fixed: "单击切换到固定的界面"
        }
    }

    /// A nil destination means show the selector. Being anywhere in the Home
    /// family takes precedence over the shortcut, including a different fixed target.
    static func destination(enabled: Bool, mode: Self, isHome: Bool,
                            previous: LocalHomeActionTarget?, fixed: LocalHomeActionTarget?) -> LocalHomeActionTarget? {
        guard enabled, !isHome else { return nil }
        return mode == .previous ? previous ?? .home : fixed
    }
}

/// Source keys in a merged subscription are temporary. Persist its original
/// owner/key pair, while HTML entries retain the library's stable source ID.
enum LocalHomeActionTarget: Codable, Hashable {
    case home
    case site(LocalHomeSourceSelection, title: String)
    case html(id: String, title: String)
    case manga(key: String, title: String)

    var title: String {
        switch self {
        case .home: "首页"
        case .site(_, let title), .html(_, let title), .manga(_, let title): title
        }
    }

    var sourceSelection: LocalHomeSourceSelection? {
        guard case .site(let source, _) = self else { return nil }
        return LocalHomeSourceSelection(origin: source.origin, sourceKey: source.sourceKey, python: source.python)
    }

    func save(forKey key: String, defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: key)
    }

    static func saved(forKey key: String, defaults: UserDefaults = .standard) -> Self? {
        decode(defaults.data(forKey: key) ?? Data())
    }

    static func decode(_ data: Data) -> Self? {
        guard let value = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        switch value {
        case .home: return value
        case .site(let source, let title):
            guard !source.origin.isEmpty, !source.sourceKey.isEmpty else { return nil }
            return .site(LocalHomeSourceSelection(origin: source.origin, sourceKey: source.sourceKey, python: source.python), title: title)
        case .html(let id, _):
            return id.isEmpty || id == "builtin" ? nil : value
        case .manga(let key, _):
            return key.isEmpty ? nil : value
        }
    }
}
