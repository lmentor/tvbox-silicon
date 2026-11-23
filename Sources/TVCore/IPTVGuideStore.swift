import Foundation

public struct IPTVGuideSchedule: Sendable {
    public fileprivate(set) var shows: [IPTVProgramme]
    public fileprivate(set) var updated: Date
    public fileprivate(set) var refreshAfter: Date
    public fileprivate(set) var stale: Bool
}

public actor IPTVGuideStore {
    public static let shared = IPTVGuideStore(fetch: IPTVGuideDownload.fetch)
    typealias Fetch = @Sendable (URLRequest, Int) async throws -> (Data, HTTPURLResponse)

    // Array equality fast-paths the shared COW buffer of the source's channel snapshot. Hashing the
    // count keeps row lookups independent of the number of channels while still checking equality.
    private struct Catalog: Hashable {
        let stations: [IPTVStation]
        func hash(into hasher: inout Hasher) { hasher.combine(stations.count) }
    }
    private struct Key: Hashable {
        let source: String
        let url: URL
        let headers: [String: String]
        let zone: String
        let midnight: Date
        let catalog: Catalog?
    }
    private enum Guide: Sendable {
        case xml(IPTVGuideXML)
        case diyp([IPTVProgramme])
    }
    private struct Entry: Sendable {
        let guide: Guide
        let updated: Date
        var refreshAfter: Date
        var stale = false

        func schedule(_ station: IPTVStation) -> IPTVGuideSchedule {
            let shows: [IPTVProgramme]
            switch guide {
            case .xml(let xml): shows = xml.schedule(station)
            case .diyp(let list): shows = list
            }
            return IPTVGuideSchedule(shows: shows, updated: updated, refreshAfter: refreshAfter, stale: stale)
        }
    }

    private var entries = [Key: Entry]()
    private var conflictingNames = [Catalog: Set<String>]()
    private var pending = [Key: Task<Entry, Error>]()
    private var retryAfter = [Key: Date]()
    private let fetch: Fetch

    init(fetch: @escaping Fetch) { self.fetch = fetch }

    public func schedule(_ context: IPTVGuideContext, station: IPTVStation, day: Date, force: Bool = false,
                         adjacent: Bool = false) async throws -> IPTVGuideSchedule {
        guard !context.fallbackAddresses.isEmpty else {
            return try await singleSchedule(context, station: station, day: day, force: force, adjacent: adjacent)
        }
        var seen = Set<String>()
        var stale: IPTVGuideSchedule?, empty: IPTVGuideSchedule?
        var failure: Error = IPTVGuideFailure.http
        for address in [context.address] + context.fallbackAddresses where seen.insert(address).inserted {
            try Task.checkCancellation()
            let fallback = address != context.address && context.fallbackHeaders != nil
            let candidate = IPTVGuideContext(sourceID: context.sourceID, address: address, stations: context.stations,
                timeZoneID: context.zone.identifier, origin: fallback ? context.fallbackOrigin : context.origin,
                headers: fallback ? context.fallbackHeaders ?? [:] : context.headers)
            do {
                let result = try await singleSchedule(candidate, station: station, day: day, force: force, adjacent: adjacent)
                if !result.shows.isEmpty {
                    if !result.stale { return result }
                    if stale == nil { stale = result }
                } else if empty == nil { empty = result }
            } catch {
                try Task.checkCancellation()
                failure = error
            }
        }
        if let result = stale ?? empty { return result }
        throw failure
    }

    private func singleSchedule(_ context: IPTVGuideContext, station: IPTVStation, day: Date, force: Bool,
                                adjacent: Bool) async throws -> IPTVGuideSchedule {
        if context.perChannel, ambiguous(station, in: context) {
            let now = Date()
            return IPTVGuideSchedule(shows: [], updated: now, refreshAfter: now.addingTimeInterval(21600), stale: false)
        }
        let calendar = context.calendar
        let midnight = calendar.startOfDay(for: day)
        let next = calendar.date(byAdding: .day, value: 1, to: midnight)!
        var result = try await entry(context, station: station, day: midnight, force: force).schedule(station)
        guard context.perChannel else { return result }
        // A DIYP server usually files an overnight programme on the day it starts.
        var extra: [Date] = []
        let now = Date()
        let today = calendar.isDate(day, inSameDayAs: now)
        if (result.shows.first?.start ?? next) > (adjacent || !today ? midnight : now),
           let previous = calendar.date(byAdding: .day, value: -1, to: midnight) { extra.append(previous) }
        if adjacent, today, result.shows.next(after: now) == nil { extra.append(next) }
        for date in extra {
            try Task.checkCancellation()
            if let other = try? await entry(context, station: station, day: date, force: force).schedule(station) {
                let overlap = date < midnight ? other.shows.filter { $0.end > midnight } : other.shows
                result.shows += overlap
                if !overlap.isEmpty {
                    result.stale = result.stale || other.stale
                    result.updated = min(result.updated, other.updated)
                    result.refreshAfter = min(result.refreshAfter, other.refreshAfter)
                }
            }
        }
        result.shows = Array(Set(result.shows)).sorted { ($0.start, $0.end, $0.title) < ($1.start, $1.end, $1.title) }
        return result
    }

    private func ambiguous(_ station: IPTVStation, in context: IPTVGuideContext) -> Bool {
        // tvg-name explicitly maps a station to this provider's channel. Alternate
        // groups/lines often share it; that is a shared guide, not an ambiguous name.
        if let name = station.guideName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        let key = Catalog(stations: context.stations)
        let name = IPTVGuideXML.key(station.guideName ?? station.name)
        if let known = conflictingNames[key] { return known.contains(name) }
        var unique = Set<String>()
        var duplicates = Set<String>()
        for item in context.stations {
            let value = IPTVGuideXML.key(item.guideName ?? item.name)
            if !unique.insert(value).inserted { duplicates.insert(value) }
        }
        if conflictingNames.count >= 12, let first = conflictingNames.keys.first { conflictingNames.removeValue(forKey: first) }
        conflictingNames[key] = duplicates
        return duplicates.contains(name)
    }

    private func entry(_ context: IPTVGuideContext, station: IPTVStation, day: Date, force: Bool) async throws -> Entry {
        try Task.checkCancellation()
        let name = station.guideName ?? station.name
        guard let url = context.url(name: name, day: day) else { throw IPTVGuideFailure.address }
        let headers = IPTVHeaders.inherited(context.headers, from: context.origin, to: url)
        let key = Key(source: context.sourceID, url: url, headers: headers, zone: context.zone.identifier, midnight: day,
                      catalog: context.perChannel ? nil : Catalog(stations: context.stations))
        let now = Date()
        if !force {
            if let saved = entries[key], now < saved.refreshAfter { return saved }
            if let retry = retryAfter[key], retry > now { throw IPTVGuideFailure.http }
        }
        if let task = pending[key] { return try await task.value }
        let task = Task { try await load(context, key: key, channelName: name) }
        pending[key] = task
        return try await task.value
    }

    private func load(_ context: IPTVGuideContext, key: Key, channelName: String) async throws -> Entry {
        defer { pending[key] = nil }
        do {
            var request = URLRequest(url: key.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue(HTTPClient.subscriptionUserAgent, forHTTPHeaderField: "User-Agent")
            for (field, value) in key.headers { request.setValue(value, forHTTPHeaderField: field) }
            let (data, response) = try await fetch(request, context.perChannel ? 2_000_000 : 32_000_000)
            guard (200..<300).contains(response.statusCode) else { throw IPTVGuideFailure.http }
            let guide: Guide
            if context.perChannel {
                guide = .diyp(try IPTVGuideDIYP.parse(data, day: key.midnight, zone: context.zone, channelName: channelName))
            } else {
                let end = context.calendar.date(byAdding: .day, value: 2, to: key.midnight)!
                let window = DateInterval(start: key.midnight, end: end)
                let parsed = try await Task.detached(priority: .utility) {
                    try IPTVGuideXML.parse(data, stations: context.stations, window: window, zone: context.zone)
                }.value
                guide = .xml(parsed)
            }
            let now = Date()
            let lifetime = Self.lifetime(response, now: now)
            let result = Entry(guide: guide, updated: now, refreshAfter: now.addingTimeInterval(lifetime ?? 0))
            retryAfter[key] = nil
            if lifetime != nil {
                entries[key] = result
                let sameKind = entries.filter { ($0.key.catalog == nil) == (key.catalog == nil) }
                if sameKind.count > (context.perChannel ? 256 : 6),
                   let oldest = sameKind.min(by: { $0.value.updated < $1.value.updated }) { entries[oldest.key] = nil }
            } else { entries[key] = nil }
            return result
        } catch {
            let retry = Date().addingTimeInterval(60)
            if var saved = entries[key] {
                saved.stale = true
                saved.refreshAfter = retry
                entries[key] = saved
                return saved
            }
            retryAfter = retryAfter.filter { $0.value > Date() }
            if retryAfter.count < 256 { retryAfter[key] = retry }
            throw error
        }
    }

    // nil means the provider forbids storage. Honor both modern and traditional freshness headers.
    static func lifetime(_ response: HTTPURLResponse, now: Date) -> TimeInterval? {
        let controls = (response.value(forHTTPHeaderField: "Cache-Control") ?? "")
            .lowercased().components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if controls.contains("no-store") { return nil }
        if controls.contains("no-cache") { return 0 }
        if let directive = controls.first(where: { $0.hasPrefix("max-age=") }),
           let seconds = TimeInterval(directive.dropFirst(8).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))), seconds.isFinite {
            let age = TimeInterval(response.value(forHTTPHeaderField: "Age") ?? "") ?? 0
            return max(0, seconds - max(0, age))
        }
        if let expires = response.value(forHTTPHeaderField: "Expires") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .gmt
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let expiry = formatter.date(from: expires) { return max(0, expiry.timeIntervalSince(now)) }
        }
        return 6 * 3600
    }
}

private final class IPTVGuideDownload: NSObject, URLSessionDownloadDelegate, Sendable {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForResource = 40
        return URLSession(configuration: config)
    }()

    let limit: Int
    init(limit: Int) { self.limit = limit }

    static func fetch(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let (file, response) = try await session.download(for: request, delegate: IPTVGuideDownload(limit: limit))
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw IPTVGuideFailure.http }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size <= limit else { throw IPTVGuideFailure.limit }
        return (try Data(contentsOf: file, options: .mappedIfSafe), http)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if max(totalBytesWritten, totalBytesExpectedToWrite) > limit { downloadTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased()) else { completionHandler(nil); return }
        var next = request
        let headers = request.allHTTPHeaderFields ?? [:]
        let allowed = IPTVHeaders.inherited(headers, from: response.url, to: url)
        for name in headers.keys where allowed[name] == nil { next.setValue(nil, forHTTPHeaderField: name) }
        // URLSession can strip Authorization even on a same-origin redirect. Restore
        // the previous hop's allowed fields; using originalRequest could resurrect
        // credentials after a cross-origin hop returns to the original host.
        if let previous = task.currentRequest {
            let inherited = IPTVHeaders.inherited(previous.allHTTPHeaderFields ?? [:], from: previous.url, to: url)
            for (name, value) in inherited { next.setValue(value, forHTTPHeaderField: name) }
        }
        completionHandler(next)
    }
}
