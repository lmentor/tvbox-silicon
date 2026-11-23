import Foundation
import Perception

/// Subscription-qualified hides. Imported JSON keeps the source owner across asset updates.
@MainActor @Perceptible public final class HiddenSources {
    private var keys: [String]
    /// Bumps when a source is hidden or shown, so a cached source row can be reused until then.
    public private(set) var revision = 0
    private let defaults: UserDefaults
    /// Called after the list changes here (not after `adopt`), for iCloud sync.
    @PerceptionIgnored public var onChange: (@MainActor () -> Void)?
    /// All changes, including cloud adoption, invalidate retained catalog/navigation state.
    @PerceptionIgnored public var onVisibilityChange: (@MainActor () -> Void)?
    private static let storageKey = "hiddenSources.v1"
    private static let builtInRestoreKey = "hiddenSources.builtInRestore.v1"
    private static let autoRestoreKey = "hiddenSources.autoRestore.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.stringArray(forKey: Self.storageKey) ?? []
        keys = Self.normalized(saved)
        if keys != saved { defaults.set(keys, forKey: Self.storageKey) }
    }

    private func key(_ site: Site, origin: URL) -> String {
        EpisodeSkipSettings.scope(origin: PlaybackHistoryContext.sourceIdentity(site.origin(or: origin)), source: site.sourceKey, video: "")
    }

    private static func normalized(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.map { key in
            guard let fields = try? JSONDecoder().decode([String].self, from: Data(key.utf8)), fields.count == 3,
                  let origin = URL(string: fields[0]) else { return key }
            return EpisodeSkipSettings.scope(origin: PlaybackHistoryContext.sourceIdentity(origin), source: fields[1], video: fields[2])
        }.filter { seen.insert($0).inserted }
    }

    public func contains(_ site: Site, origin: URL) -> Bool { keys.contains(key(site, origin: origin)) }

    public func toggle(_ site: Site, origin: URL) {
        let key = key(site, origin: origin)
        if keys.contains(key) { keys.removeAll { $0 == key } } else { keys.append(key) }
        defaults.set(keys, forKey: Self.storageKey)
        revision += 1
        onVisibilityChange?()
        onChange?()
    }

    public func insert(_ site: Site, origin: URL) {
        let key = key(site, origin: origin)
        guard !keys.contains(key) else { return }
        keys.append(key)
        defaults.set(keys, forKey: Self.storageKey)
        revision += 1
        onVisibilityChange?()
        onChange?()
    }

    /// Hides or shows many sources in one change: one save, one revision, one sync.
    public func setHidden(_ sites: [Site], origin: URL, hidden: Bool) {
        let changed = Set(sites.map { key($0, origin: origin) })
        var next = keys
        if hidden {
            for site in sites {
                let key = key(site, origin: origin)
                if !next.contains(key) { next.append(key) }
            }
        } else {
            next.removeAll { changed.contains($0) }
        }
        guard next != keys else { return }
        keys = next
        defaults.set(keys, forKey: Self.storageKey)
        revision += 1
        onVisibilityChange?()
        onChange?()
    }

    /// The saved keys, in order, as iCloud sync compares them.
    public var savedKeys: [String] { keys }
    /// The list merged with other devices'.
    public func adopt(_ keys: [String]) {
        let keys = Self.normalized(keys)
        guard keys != self.keys else { return }
        self.keys = keys
        defaults.set(keys, forKey: Self.storageKey)
        revision += 1
        onVisibilityChange?()
    }

    /// Built-in sources used to be hidden automatically like any other, so once, every hidden
    /// built-in shows again. One the viewer hides afterwards stays hidden.
    public func restoreBuiltIns(_ sites: [Site], origin: URL) {
        guard !defaults.bool(forKey: Self.builtInRestoreKey), !sites.isEmpty else { return }
        let restored = Set(sites.filter(\.isBuiltIn).map { key($0, origin: origin) })
        if keys.contains(where: restored.contains) {
            keys.removeAll { restored.contains($0) }
            defaults.set(keys, forKey: Self.storageKey)
            revision += 1
            onVisibilityChange?()
            onChange?()
        }
        defaults.set(true, forKey: Self.builtInRestoreKey)
    }

    /// 1.7.13 hid a source automatically once it went red, in the same list as the viewer's own hides,
    /// and nothing brought it back. Failing sources are now only paused in search (`SourceHealth.paused`),
    /// so once, every hidden source that failed repeatedly shows again. One hidden while it worked was
    /// the viewer's choice and stays hidden. An empty list waits for the real subscription.
    public func restoreAutoHidden(_ sites: [Site], origin: URL, health: SourceHealth) {
        guard !defaults.bool(forKey: Self.autoRestoreKey), !sites.isEmpty else { return }
        let restored = Set(sites.filter { health.failedRepeatedly($0, origin: origin) }.map { key($0, origin: origin) })
        if keys.contains(where: restored.contains) {
            keys.removeAll { restored.contains($0) }
            defaults.set(keys, forKey: Self.storageKey)
            revision += 1
            onVisibilityChange?()
            onChange?()
        }
        defaults.set(true, forKey: Self.autoRestoreKey)
    }
}
