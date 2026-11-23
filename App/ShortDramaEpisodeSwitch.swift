import Foundation
#if canImport(TVCore)
import TVCore
#endif

/// Short-drama gestures need catalog evidence; portrait framing and episode duration are not evidence.
enum ShortDramaSwipe {
    enum Direction { case next, previous }

    static func eligible(category: String?, sourceName: String, sourceKey: String,
                         sourceRoute: String? = nil, scriptName: String? = nil,
                         episodeCount: Int, live: Bool, reading: Bool) -> Bool {
        guard !live, !reading, episodeCount > 0 else { return false }
        switch CatalogVideoCategory.classify(category) {
        case .shortDrama: return true
        case .ordinary: return false
        case .unspecified: break
        }
        // Imported Python sources have an opaque record key; merged CatPaw sources wrap their
        // original provider key as cp_<interface hash>_<key>_<hash>. Display names are editable.
        var identities = [providerKey(sourceKey)]
        if let sourceRoute, let path = URLComponents(string: sourceRoute)?.path {
            let components = path.split(separator: "/")
            if components.count == 3, components[0] == "spider", ["3", "4"].contains(components[2]) {
                identities.append(providerKey(String(components[1])))
            }
        }
        if let scriptName {
            let file = URL(fileURLWithPath: scriptName)
            if ["py", "js"].contains(file.pathExtension.lowercased()) {
                identities.append(providerKey(file.deletingPathExtension().lastPathComponent))
            }
        }
        // Exact identities matter: xifannext/animexifan are anime and bookhongguo is audio.
        if identities.contains(where: { ["hongguo", "xifan", "hema"].contains($0) || labeled($0) }) { return true }
        return labeled(normalized(sourceName)) || labeled(normalized(sourceKey))
    }

    private static func providerKey(_ value: String) -> String {
        var key = normalized(value).trimmingCharacters(in: .whitespacesAndNewlines)
        if let prefix = ["nodejs_", "builtin.", "py_", "js_"].first(where: key.hasPrefix) {
            key.removeFirst(prefix.count)
        }
        let pattern = #"^cp_[0-9a-f]{8}_(.+)_[0-9a-f]{8}$"#
        if let expression = try? NSRegularExpression(pattern: pattern),
           let match = expression.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)),
           let range = Range(match.range(at: 1), in: key) { key = String(key[range]) }
        return key
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func labeled(_ text: String) -> Bool {
        CatalogVideoCategory.classify(text) == .shortDrama
    }

    static func isVertical(horizontal: Double, vertical: Double) -> Bool {
        horizontal.isFinite && vertical.isFinite && abs(vertical) > abs(horizontal) * 1.35
    }

    static func direction(horizontal: Double, vertical: Double, height: Double) -> Direction? {
        guard height.isFinite, height > 0, isVertical(horizontal: horizontal, vertical: vertical),
              abs(vertical) >= min(96, max(60, height * 0.11)) else { return nil }
        return vertical < 0 ? .next : .previous
    }
}

/// One worker owns all resolution and cancellation drains. Further swipes only replace its target;
/// a resolver which is slow to cancel keeps the worker occupied until its real completion.
@MainActor final class ShortDramaEpisodeSwitch {
    struct Context: Equatable {
        let scope: String
        let episodes: [String]
        let current: String
    }
    enum Outcome: Equatable { case target(String), first, last, unavailable }
    private(set) var target: String?
    var isWorking: Bool { worker != nil }
    private let debounce: TimeInterval
    private var context: Context?
    private var revision: UInt64 = 0
    private var due: TimeInterval = 0
    private var activeTarget: String?
    private var cancelled = false
    private var worker: Task<Void, Never>?
    private var drains: [Task<Void, Never>] = []
    private var interrupt: (@MainActor (String?) -> [Task<Void, Never>])?
    private var select: (@MainActor (String) async -> Bool)?
    private var settled: (@MainActor () -> Void)?

    init(debounce: TimeInterval = 0.22) { self.debounce = max(0, debounce) }

    @discardableResult
    func move(_ direction: ShortDramaSwipe.Direction, in next: Context,
              interrupt: @escaping @MainActor (String?) -> [Task<Void, Never>],
              select: @escaping @MainActor (String) async -> Bool,
              settled: @escaping @MainActor () -> Void = {}) -> Outcome {
        synchronize(next)
        guard let context, let index = context.episodes.firstIndex(of: target ?? context.current) else { return .unavailable }
        let offset = index + (direction == .next ? 1 : -1)
        guard offset >= 0 else { return .first }
        guard context.episodes.indices.contains(offset) else { return .last }
        let nextID = context.episodes[offset]
        self.interrupt = interrupt; self.select = select; self.settled = settled
        revision &+= 1; cancelled = false
        target = nextID == context.current ? nil : nextID
        due = ProcessInfo.processInfo.systemUptime + debounce
        drains += interrupt(target)
        startWorker()
        return .target(nextID)
    }

    /// Same-work episode handoffs keep a later swipe's intended target; a different source, title,
    /// line, or an unrelated explicit selection invalidates the old gesture immediately.
    func synchronize(_ next: Context?) {
        if let old = context, let next, old.scope == next.scope, old.episodes == next.episodes {
            if old.current != next.current, next.current != target, next.current != activeTarget { cancel() }
        } else if context != nil { cancel() }
        context = next
    }

    func cancel() {
        guard !cancelled, isWorking || target != nil else { return }
        revision &+= 1; target = nil; due = 0; cancelled = true
        drains += interrupt?(nil) ?? []
        startWorker()
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        defer {
            worker = nil; activeTarget = nil
            let finished = settled
            interrupt = nil; select = nil; settled = nil
            finished?()
        }
        while true {
            if !drains.isEmpty {
                let previous = drains; drains.removeAll(keepingCapacity: true)
                for task in previous { await task.value }
                continue
            }
            guard let target else { return }
            let remaining = due - ProcessInfo.processInfo.systemUptime
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
                continue
            }
            // A SwiftUI channel handoff may start its media preparation after the swipe
            // callback. Fence that final gap before handing the only worker to resolution.
            let late = interrupt?(target) ?? []
            if !late.isEmpty { drains += late; continue }
            guard let select else { self.target = nil; return }
            let requested = revision
            activeTarget = target
            _ = await select(target)
            activeTarget = nil
            guard requested == revision else { continue }
            self.target = nil
            return
        }
    }
}
