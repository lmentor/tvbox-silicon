import Foundation

/// A small session cache. Read access refreshes recency; bytes and result counts
/// bound retained payloads independently of the number of different keywords.
struct SearchResultCache {
    struct Cost: Sendable {
        var bytes = 0
        var items = 0
        static func + (left: Self, right: Self) -> Self {
            Self(bytes: left.bytes + right.bytes, items: left.items + right.items)
        }
        static func - (left: Self, right: Self) -> Self {
            Self(bytes: max(0, left.bytes - right.bytes), items: max(0, left.items - right.items))
        }
    }
    struct Entry {
        let results: [SearchSourceResult]
        let created: Date
        let bytes: Int
        let items: Int
        var access: UInt64
        let sourceCosts: [String: Cost]
    }
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    private(set) var bytes = 0
    private(set) var items = 0
    let maximumQueries: Int
    let maximumBytes: Int
    let maximumItems: Int
    init(maximumQueries: Int = 6, maximumBytes: Int = 12 << 20, maximumItems: Int = 12_000) {
        self.maximumQueries = maximumQueries; self.maximumBytes = maximumBytes; self.maximumItems = maximumItems
    }

    mutating func value(for key: String, now: Date = Date()) -> [SearchSourceResult]? {
        guard var entry = entries[key] else { return nil }
        guard now.timeIntervalSince(entry.created) < 300 else { remove(key); return nil }
        clock &+= 1; entry.access = clock; entries[key] = entry
        return entry.results
    }
    func cost(for key: String) -> Cost {
        entries[key].map { Cost(bytes: $0.bytes, items: $0.items) } ?? Cost()
    }
    func sourceCosts(for key: String) -> [String: Cost] { entries[key]?.sourceCosts ?? [:] }

    mutating func insert(_ results: [SearchSourceResult], for key: String, cost: Cost, sourceCosts: [String: Cost], now: Date = Date()) {
        remove(key)
        guard cost.bytes <= maximumBytes, cost.items <= maximumItems, maximumQueries > 0 else { return }
        for expired in entries.filter({ now.timeIntervalSince($0.value.created) >= 300 }).map(\.key) { remove(expired) }
        while entries.count >= maximumQueries || bytes + cost.bytes > maximumBytes || items + cost.items > maximumItems {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key else { break }
            remove(oldest)
        }
        clock &+= 1
        entries[key] = Entry(results: results, created: now, bytes: cost.bytes, items: cost.items, access: clock, sourceCosts: sourceCosts)
        bytes += cost.bytes; items += cost.items
    }

    mutating func removeAll() { entries.removeAll(); bytes = 0; items = 0 }
    private mutating func remove(_ key: String) {
        guard let old = entries.removeValue(forKey: key) else { return }
        bytes -= old.bytes; items -= old.items
    }

    /// Cost measures the actual retained value payload, with room for array/string headers.
    /// Metadata is included: a single plugin may return a long synopsis or many episodes.
    static func cost(_ results: [SearchSourceResult]) -> Cost {
        var bytes = 0, items = 0
        func text(_ value: String?) { bytes += value.map { $0.utf8.count + 32 } ?? 0 }
        func json(_ value: JSONValue) {
            switch value {
            case .string(let value): text(value)
            case .array(let values): bytes += values.count * 24; values.forEach(json)
            case .object(let values): bytes += values.count * 48; for (key, value) in values { text(key); json(value) }
            default: bytes += 16
            }
        }
        for result in results {
            bytes += 256; items += 1
            text(result.site.key); text(result.site.name); text(result.site.api); text(result.error)
            for (key, value) in result.site.raw { text(key); json(value) }
            for video in result.page?.videos ?? [] {
                bytes += 384; items += 1
                for value in [video.id, video.name, video.poster?.absoluteString, video.year, video.remarks, video.synopsis,
                              video.category, video.area, video.director, video.actor, video.action, video.folderCategoryID] { text(value) }
                for (key, value) in video.posterHeaders { text(key); text(value) }
                for (key, value) in video.folderFilters { text(key); text(value) }
                if let share = video.panShare { text(share.url); text(share.password); text(share.datetime) }
                for episode in video.episodes {
                    bytes += 96
                    text(episode.id); text(episode.name); text(episode.address); text(episode.flag); text(episode.videoID)
                }
            }
            for comic in result.mangaPage?.comics ?? [] {
                bytes += 192
                for value in [comic.id, comic.sourceKey, comic.title, comic.subtitle, comic.cover, comic.description] { text(value) }
                comic.tags.forEach { text($0) }
            }
            if case .token(let value) = result.mangaPage?.next { text(value) }
        }
        return Cost(bytes: bytes, items: items)
    }
}
