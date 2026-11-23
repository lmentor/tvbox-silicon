import Foundation
import Perception

/// One current catalog list. Source/category replacement cancels consumers;
/// pagination retains completed outcomes and the original ordinary-card slots.
@MainActor @Perceptible public final class LocalSiteLinkChecks {
    public private(set) var visibleVideos: [Video] = []
    public private(set) var statuses: [String: PanLinkStatus] = [:]
    public private(set) var checking = false
    public private(set) var total = 0
    public private(set) var completed = 0
    public private(set) var hiddenCount = 0
    @PerceptionIgnored private var videos: [Video] = []
    @PerceptionIgnored private var candidates: [Video] = []
    @PerceptionIgnored private var dateOrderedCandidates: [Video] = []
    @PerceptionIgnored private var scope = ""
    @PerceptionIgnored private var generation = UUID()
    @PerceptionIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @PerceptionIgnored private var inputOwners: [String: UUID] = [:]
    @PerceptionIgnored private var finished = Set<String>()
    @PerceptionIgnored private var ordinary = Set<String>()
    @PerceptionIgnored private var enabled = false
    @PerceptionIgnored private var check: @Sendable (Site, [Video], Bool) async throws -> PanCheckResult

    public init(check: @escaping @Sendable (Site, [Video], Bool) async throws -> PanCheckResult = { site, videos, refresh in
        try await LocalSiteLinkService.check(site: site, videos: videos, refresh: refresh)
    }) { self.check = check }

    public func reconcile(videos: [Video], site: Site, scope: String, enabled: Bool) {
        let enabled = enabled && site.supportsLocalLinkChecks
        let replaced = self.scope != scope || self.enabled != enabled
        if replaced {
            stop(); self.scope = scope; self.enabled = enabled
            statuses = [:]; finished = []; ordinary = []; inputOwners = [:]
        }
        let previous = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.videos = videos
        candidates = enabled ? videos.filter(\.hasLocalCheckCandidate) : []
        dateOrderedCandidates = Self.byDate(candidates)
        let wanted = Set(candidates.map(\.id))
        for id in Array(tasks.keys) where !wanted.contains(id) { tasks.removeValue(forKey: id)?.cancel() }
        for video in candidates {
            if let old = previous[video.id], old.panShare != video.panShare {
                tasks.removeValue(forKey: video.id)?.cancel()
                inputOwners[video.id] = UUID()
                statuses[video.id] = nil; finished.remove(video.id); ordinary.remove(video.id)
            } else if inputOwners[video.id] == nil { inputOwners[video.id] = UUID() }
        }
        inputOwners = inputOwners.filter { wanted.contains($0.key) }
        statuses = statuses.filter { wanted.contains($0.key) }
        finished.formIntersection(wanted)
        ordinary.formIntersection(wanted)
        project()
        if enabled { pump(site) }
    }

    public func stop() {
        generation = UUID()
        for task in tasks.values { task.cancel() }
        tasks = [:]
        checking = false
    }

    private func pump(_ site: Site) {
        guard enabled else { return }
        let current = generation
        for video in candidates where !finished.contains(video.id) && tasks[video.id] == nil {
            guard tasks.count < 4 else { break }
            let check = check
            let inputOwner = inputOwners[video.id]
            tasks[video.id] = Task { [weak self] in
                let result: PanCheckResult?
                do { result = try await check(site, [video], false) }
                catch { result = nil }
                guard let self, self.generation == current, self.inputOwners[video.id] == inputOwner, !Task.isCancelled else { return }
                self.tasks[video.id] = nil
                self.finished.insert(video.id)
                if let status = result?.items.first(where: { $0.id == video.id }) { self.statuses[video.id] = status }
                else if result == nil {
                    self.statuses[video.id] = PanLinkStatus(id: video.id, state: .uncertain, summary: "暂时无法确认")
                } else { self.ordinary.insert(video.id) }
                self.project()
                self.pump(site)
            }
        }
        checking = !tasks.isEmpty
    }

    private func project() {
        total = candidates.count - ordinary.count; completed = finished.count - ordinary.count
        guard enabled else { visibleVideos = videos; hiddenCount = 0; checking = false; return }
        let shares = candidates.filter { !ordinary.contains($0.id) }
        let candidateIDs = Set(shares.map(\.id))
        var valid: [Video] = [], other: [Video] = []
        for video in dateOrderedCandidates where !ordinary.contains(video.id) {
            switch statuses[video.id]?.state {
            case .bad: continue
            case .ok: valid.append(video)
            default: other.append(video)
            }
        }
        let resources = valid + other
        hiddenCount = shares.count - resources.count
        var remaining = resources.makeIterator()
        visibleVideos = videos.compactMap { candidateIDs.contains($0.id) ? remaining.next() : $0 }
    }

    /// Dates do not change when an outcome arrives. Parse/sort once per input list,
    /// then partition valid/other resources in linear time for incremental results.
    private static func byDate(_ videos: [Video]) -> [Video] {
        let iso = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter(); fractional.formatOptions.insert(.withFractionalSeconds)
        let dateOnly = DateFormatter(); dateOnly.locale = Locale(identifier: "en_US_POSIX"); dateOnly.dateFormat = "yyyy-MM-dd"
        func date(_ video: Video) -> Double {
            let raw = video.panShare?.datetime ?? ""
            if (raw.count == 10 || raw.count == 13), raw.allSatisfy(\.isNumber), let value = Double(raw) {
                return value / (raw.count == 13 ? 1000 : 1)
            }
            return (iso.date(from: raw) ?? fractional.date(from: raw) ?? dateOnly.date(from: raw))?.timeIntervalSince1970 ?? 0
        }
        let dates = Dictionary(videos.map { ($0.id, date($0)) }, uniquingKeysWith: { first, _ in first })
        return videos.enumerated().sorted {
            let left = dates[$0.element.id] ?? 0, right = dates[$1.element.id] ?? 0
            return left == right ? $0.offset < $1.offset : left > right
        }.map(\.element)
    }
}
