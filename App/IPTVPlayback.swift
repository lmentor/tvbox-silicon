#if os(iOS)
import Foundation
import CryptoKit
import Network
import TVCore

/// Only the station reference enters the shared player cover, favorites and PiP state.
/// Consume the originating list once; a cold favorite resolves against its current enabled source.
@MainActor extension Store {
    func playIPTV(_ station: IPTVStation, lineup: [IPTVStation]) {
        var reference = IPTVStationReference.channel(for: station)
        let request = UUID()
        reference.playbackRequestID = request
        IPTVPlayback.pending = (request, lineup.map(\.id))
        playing = reference
    }
}

@MainActor struct IPTVPlayback {
    static var pending: (request: UUID, ids: [String])?
    let sourceID: String
    var station: IPTVStation
    var lineup: [IPTVStation]
    var guide: IPTVGuideContext?
    var lineIndex: Int
    var programme: IPTVProgramme?
    var catchupLine: IPTVLine?
    var attempted: Set<Int> = []
    var refreshed = false
    var started = ProcessInfo.processInfo.systemUptime

    init?(reference: Channel, id: String) {
        let records = IPTVLibrary.shared.records.filter(\.enabled)
        let requested = Self.pending
        Self.pending = nil
        guard let record = records.first(where: { $0.stations.contains { $0.id == id } }),
              let station = record.stations.first(where: { $0.id == id }), !station.lines.isEmpty else { return nil }
        sourceID = record.id
        self.station = station
        guide = record.guideContext(for: station)
        let ids = requested?.request == reference.playbackRequestID ? requested?.ids : nil
        if let ids, ids.contains(id) {
            let candidates = Dictionary(records.flatMap(\.stations).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var seen = Set<String>()
            lineup = ids.compactMap { seen.insert($0).inserted ? candidates[$0] : nil }
        } else {
            lineup = record.stations
        }
        let preferred = UserDefaults.standard.string(forKey: "local.iptv.line." + id)
        let matches = preferred.map { signature in station.lines.indices.filter { Self.signature(station.lines[$0]) == signature } } ?? []
        lineIndex = matches.count == 1 ? matches[0] : 0
    }

    var line: IPTVLine { catchupLine ?? station.lines[lineIndex] }

    func neighbor(back: Bool) -> IPTVStation? {
        guard lineup.count > 1, let index = lineup.firstIndex(where: { $0.id == station.id }) else { return nil }
        return lineup[(index + (back ? lineup.count - 1 : 1)) % lineup.count]
    }

    var enabledRecord: IPTVRecord? { IPTVLibrary.shared.records.first { $0.id == sourceID && $0.enabled } }

    mutating func useRefreshedStation(_ replacement: IPTVStation, in record: IPTVRecord) {
        // The same named line may now have a fresh signature or headers. Unchanged failed transports
        // remain spent, even if the source shuffled its labels or positions during refresh.
        let failed = attempted.map { station.lines[$0] }
        let current = line
        attempted = Set(replacement.lines.indices.filter { index in
            let candidate = replacement.lines[index]
            return failed.contains { $0.url == candidate.url && $0.headers == candidate.headers }
        })
        lineIndex = replacement.lines.firstIndex(where: { $0.name == current.name })
            ?? replacement.lines.firstIndex(where: { $0.url == current.url }) ?? 0
        station = replacement
        if let index = lineup.firstIndex(where: { $0.id == replacement.id }) { lineup[index] = replacement }
        guide = record.guideContext(for: replacement)
    }

    func rememberLine() {
        guard programme == nil else { return }
        UserDefaults.standard.set(Self.signature(line), forKey: "local.iptv.line." + station.id)
    }

    // Persist an opaque fingerprint. Expiring URL queries and request credentials stay out of defaults.
    private static func signature(_ line: IPTVLine) -> String {
        let url = line.url
        let parts = [url.scheme ?? "", url.host ?? "", url.port.map(String.init) ?? "", url.path, line.name]
        return SHA256.hash(data: Data(parts.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A network outage suspends line selection until a path returns. A reachable network with a
/// dead individual host still advances through the station's other lines.
@MainActor final class IPTVNetworkPath {
    static let shared = IPTVNetworkPath()
    private let monitor = NWPathMonitor()
    private(set) var offline = false
    private init() {
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let offline = path.status == .unsatisfied
            Task { @MainActor [weak self] in self?.offline = offline }
        }
        monitor.start(queue: DispatchQueue(label: "yingxia.iptv.path"))
    }
}
#endif
