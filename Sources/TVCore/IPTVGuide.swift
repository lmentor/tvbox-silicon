import Foundation
import zlib

public struct IPTVProgramme: Hashable, Sendable {
    public let title: String
    public let start: Date
    public let end: Date

    public init(title: String, start: Date, end: Date) {
        self.title = title
        self.start = start
        self.end = end
    }
}

public extension Array where Element == IPTVProgramme {
    func now(at date: Date) -> IPTVProgramme? { last { $0.start <= date && date < $0.end } }
    func next(after date: Date) -> IPTVProgramme? { first { $0.start > date } }
}

private func ordered(_ shows: [IPTVProgramme]) -> [IPTVProgramme] {
    let sorted = Set(shows).sorted {
        if $0.start == $1.start { return ($0.end, $0.title) < ($1.end, $1.title) }
        return $0.start < $1.start
    }
    return sorted.enumerated().compactMap { index, show in
        if show.end != .distantFuture { return show.end > show.start ? show : nil }
        let next = sorted.dropFirst(index + 1).first { $0.start > show.start }?.start
        return IPTVProgramme(title: show.title, start: show.start, end: next ?? show.start.addingTimeInterval(3600))
    }
}

public struct IPTVGuideContext: Equatable, Sendable {
    public static let defaultAddress = "https://epg.cdn.loc.cc?ch={name}&date={date}"

    public static func resolvedAddress(override: String?, station: String?, subscription: String?) -> String {
        for address in [override, station, subscription].compactMap({ $0 }) {
            let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return defaultAddress
    }

    public static func resolvedAddresses(override: String?, station: String?, subscription: [String]) -> [String] {
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [override.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        var seen = Set<String>()
        return ([station].compactMap { $0 } + subscription + [defaultAddress]).compactMap { raw in
            let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return !address.isEmpty && seen.insert(address).inserted ? address : nil
        }
    }

    public let sourceID: String
    public let address: String
    public let stations: [IPTVStation]
    public let zone: TimeZone
    public let fallbackAddresses: [String]
    let origin: URL?
    let headers: [String: String]
    let fallbackOrigin: URL?
    let fallbackHeaders: [String: String]?

    public init(sourceID: String, address: String, stations: [IPTVStation], timeZoneID: String = "Asia/Shanghai",
                origin: URL? = nil, headers: [String: String] = [:], fallbackAddresses: [String] = [],
                fallbackOrigin: URL? = nil, fallbackHeaders: [String: String]? = nil) {
        self.sourceID = sourceID
        self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%7B", with: "{", options: .caseInsensitive)
            .replacingOccurrences(of: "%7D", with: "}", options: .caseInsensitive)
        self.stations = stations
        self.zone = TimeZone(identifier: timeZoneID) ?? TimeZone(identifier: "Asia/Shanghai")!
        self.origin = origin
        self.headers = headers
        self.fallbackAddresses = fallbackAddresses
        self.fallbackOrigin = fallbackOrigin
        self.fallbackHeaders = fallbackHeaders
    }

    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    var perChannel: Bool { address.contains("{name}") || address.contains("{date}") }

    func url(name: String, day: Date) -> URL? {
        guard !address.isEmpty else { return nil }
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let date = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        let text = address.replacingOccurrences(of: "{name}", with: name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")
            .replacingOccurrences(of: "{date}", with: date)
        guard !text.contains("{"), !text.contains("}"), let url = URL(string: text, relativeTo: origin)?.absoluteURL,
              ["https", "http"].contains(url.scheme?.lowercased()), url.host != nil else { return nil }
        return url
    }
}

enum IPTVGuideFailure: String, LocalizedError {
    case invalid = "节目单格式无效"
    case address = "节目单地址无效"
    case limit = "节目单超过大小限制"
    case http = "节目单服务暂时不可用"
    case dayMismatch = "节目单服务返回了其他日期，请稍后重试"
    case channelMismatch = "节目单服务返回了其他频道，暂不显示"
    var errorDescription: String? { rawValue }
}

enum IPTVGuideDIYP {
    static func parse(_ data: Data, day: Date, zone: TimeZone, channelName: String? = nil) throws -> [IPTVProgramme] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["epg_data"] as? [Any] else { throw IPTVGuideFailure.invalid }
        if let channelName, !entries.isEmpty {
            let returned = ["channel_name", "channel_id"].compactMap { root[$0] as? String }
                .map(channelKey).filter { !$0.isEmpty }
            // Some services fuzzy-match a room title to an unrelated TV station.
            // Older DIYP services omit identity fields; retain their existing contract.
            if !returned.isEmpty, !returned.contains(channelKey(channelName)) { throw IPTVGuideFailure.channelMismatch }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let midnight = calendar.startOfDay(for: day)
        if let raw = root["date"] as? String {
            let responseDay = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Some DIYP services fall back to today's schedule for an unavailable
            // date. Never turn those clock times into a replay for the requested day.
            if responseDay.range(of: #"^(?:[0-9]{8}|[0-9]{4}-[0-9]{2}-[0-9]{2})$"#, options: .regularExpression) != nil {
                let parts = calendar.dateComponents([.year, .month, .day], from: midnight)
                let expected = String(format: "%04d%02d%02d", parts.year!, parts.month!, parts.day!)
                guard responseDay.replacingOccurrences(of: "-", with: "") == expected else { throw IPTVGuideFailure.dayMismatch }
            }
        }
        func date(_ value: Any?) -> Date? {
            guard let raw = value as? String else { return nil }
            let fields = raw.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
            let numbers = fields.compactMap { Int($0) }
            guard (2...3).contains(numbers.count), fields.count == numbers.count else { return nil }
            let (h,m,s) = (numbers[0], numbers[1], numbers.count == 3 ? numbers[2] : 0)
            if h == 24, m == 0, s == 0 { return calendar.date(byAdding: .day, value: 1, to: midnight) }
            guard (0..<24).contains(h), (0..<60).contains(m), (0..<60).contains(s) else { return nil }
            return calendar.date(bySettingHour: h, minute: m, second: s, of: midnight)
        }
        return ordered(entries.compactMap { row in
            guard let item = row as? [String: Any], let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty, let start = date(item["start"]) else { return nil }
            var end = date(item["end"]) ?? .distantFuture
            if end < start { end = calendar.date(byAdding: .day, value: 1, to: end) ?? end }
            return IPTVProgramme(title: title, start: start, end: end)
        })
    }

    private static func channelKey(_ name: String) -> String {
        var value = IPTVGuideXML.key(name)
        // Quality variants have the same schedule. CCTV-4K/8K are distinct channels,
        // so their complete names must survive suffix removal.
        let quality = ["超高清", "高清", "标清", "uhd", "fhd", "hd", "sd", "4k", "8k"]
        while !["cctv4k", "cctv8k"].contains(value), let suffix = quality.first(where: { value.hasSuffix($0) }) {
            value.removeLast(suffix.count)
        }
        // Only established full station aliases may collapse to a numbered CCTV ID.
        // Prefix matching would confuse CCTV1 with CCTV10 and unrelated local channels.
        let aliases = ["cctv1综合": "cctv1", "cctv2财经": "cctv2", "cctv3综艺": "cctv3",
                       "cctv4中文国际": "cctv4", "cctv5体育": "cctv5", "cctv5+体育赛事": "cctv5+",
                       "cctv6电影": "cctv6", "cctv7国防军事": "cctv7", "cctv7军事农业": "cctv7",
                       "cctv8电视剧": "cctv8", "cctv9纪录": "cctv9", "cctv10科教": "cctv10",
                       "cctv11戏曲": "cctv11", "cctv12社会与法": "cctv12", "cctv13新闻": "cctv13",
                       "cctv14少儿": "cctv14", "cctv15音乐": "cctv15", "cctv16奥林匹克": "cctv16",
                       "cctv17农业农村": "cctv17"]
        return aliases[value] ?? value
    }
}

struct IPTVGuideXML: Sendable {
    let byChannel: [String: [IPTVProgramme]]
    let knownIDs: Set<String>
    let aliases: [String: Set<String>]
    let stationNames: [String: Set<String>]

    func schedule(_ station: IPTVStation) -> [IPTVProgramme] {
        if let id = station.guideID, knownIDs.contains(id) { return byChannel[id] ?? [] }
        for name in [station.guideName, station.name].compactMap({ $0 }) {
            let key = Self.key(name)
            guard let ids = aliases[key] else { continue }
            guard ids.count == 1, stationNames[key]?.count == 1, let id = ids.first else { return [] }
            return byChannel[id] ?? []
        }
        return []
    }

    static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "+" }.map(String.init).joined()
    }

    static func parse(_ input: Data, stations: [IPTVStation], window: DateInterval, zone: TimeZone) throws -> Self {
        let xml = try inflated(input)
        var names: [String: Set<String>] = [:]
        for station in stations {
            for name in [station.guideName, station.name].compactMap({ $0 }) {
                let key = key(name)
                if !key.isEmpty { names[key, default: []].insert(station.id) }
            }
        }
        let reader = XMLGuideReader(names: Set(names.keys), ids: Set(stations.compactMap(\.guideID)), window: window, zone: zone)
        let parser = XMLParser(data: xml)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        let success = parser.parse()
        guard reader.isGuide, success || !reader.programmes.isEmpty else { throw IPTVGuideFailure.invalid }
        return Self(byChannel: reader.programmes.mapValues { list in
            ordered(list).filter { $0.end > window.start && $0.start < window.end }
        }, knownIDs: reader.knownIDs, aliases: reader.aliases, stationNames: names)
    }

    // Size-check each output chunk, including streams whose advertised gzip trailer is false.
    static func inflated(_ data: Data, limit: Int = 64 * 1024 * 1024) throws -> Data {
        guard data.count <= limit else { throw IPTVGuideFailure.limit }
        guard data.starts(with: [0x1f, 0x8b]) else { return data }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw IPTVGuideFailure.invalid }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var result = Data()
            var chunk = [UInt8](repeating: 0, count: 32 * 1024)
            repeat {
                let status = chunk.withUnsafeMutableBytes { out in
                    stream.next_out = out.bindMemory(to: UInt8.self).baseAddress
                    stream.avail_out = uInt(out.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let count = chunk.count - Int(stream.avail_out)
                guard result.count <= limit - count else { throw IPTVGuideFailure.limit }
                result.append(contentsOf: chunk.prefix(count))
                if status == Z_STREAM_END { return result }
                guard status == Z_OK else { throw IPTVGuideFailure.invalid }
            } while true
        }
    }
}

private final class XMLGuideReader: NSObject, XMLParserDelegate {
    let wantedNames: Set<String>
    let window: DateInterval
    var keptIDs: Set<String>
    var knownIDs = Set<String>()
    var calendar: Calendar
    var aliases = [String: Set<String>]()
    var programmes = [String: [IPTVProgramme]]()
    var isGuide = false
    private var channel: String?
    private var slot: (channel: String, start: Date, end: Date)?
    private var title: String?
    private var field: String?
    private var value = ""

    init(names: Set<String>, ids: Set<String>, window: DateInterval, zone: TimeZone) {
        wantedNames = names
        keptIDs = ids
        self.window = window
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
    }

    private func add(_ alias: String, to id: String) {
        let key = IPTVGuideXML.key(alias)
        if wantedNames.contains(key) {
            aliases[key, default: []].insert(id)
            keptIDs.insert(id)
        }
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        switch element {
        case "tv": isGuide = true
        case "channel":
            channel = attributes["id"]
            if let channel {
                add(channel, to: channel)
                if keptIDs.contains(channel) { knownIDs.insert(channel) }
            }
        case "display-name" where channel != nil, "title" where slot != nil && title == nil:
            field = element
            value = ""
        case "programme":
            slot = nil
            title = nil
            guard let id = attributes["channel"] else { return }
            if !keptIDs.contains(id) { add(id, to: id) }
            guard keptIDs.contains(id) else { return }
            knownIDs.insert(id)
            guard let start = stamp(attributes["start"]), start < window.end else { return }
            let end = stamp(attributes["stop"]) ?? .distantFuture
            if end == .distantFuture, start < window.start.addingTimeInterval(-86400) { return }
            if end > window.start { slot = (id, start, end) }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if field != nil, value.utf8.count < 4096 { value += string.prefix(4096) }
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if field != nil { self.parser(parser, foundCharacters: String(decoding: data.prefix(4096), as: UTF8.self)) }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if field == element {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                if element == "title" { title = text }
                if element == "display-name", let channel { add(text, to: channel) }
            }
            field = nil
        }
        if element == "channel" { channel = nil }
        if element == "programme" {
            if let slot, let title {
                programmes[slot.channel, default: []].append(IPTVProgramme(title: title, start: slot.start, end: slot.end))
            }
            slot = nil
            title = nil
        }
    }

    private func stamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespaces)
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        guard digits.count == 12 || digits.count == 14 else { return nil }
        let bytes = Array(digits.utf8)
        func number(_ offset: Int) -> Int { (Int(bytes[offset]) - 48) * 10 + Int(bytes[offset + 1]) - 48 }
        var local = calendar
        let suffix = text.dropFirst(bytes.count).trimmingCharacters(in: .whitespaces)
        if !suffix.isEmpty {
            if ["Z", "UTC", "GMT"].contains(suffix) { local.timeZone = .gmt }
            else {
                let offset = suffix.dropFirst().replacingOccurrences(of: ":", with: "")
                guard ["+", "-"].contains(suffix.prefix(1)), offset.count == 4,
                      let hours = Int(offset.prefix(2)), let mins = Int(offset.suffix(2)), hours <= 18, mins < 60,
                      let zone = TimeZone(secondsFromGMT: (suffix.hasPrefix("-") ? -1 : 1) * (hours * 3600 + mins * 60)) else { return nil }
                local.timeZone = zone
            }
        }
        let date = DateComponents(year: number(0) * 100 + number(2), month: number(4), day: number(6), hour: number(8),
                                  minute: number(10), second: bytes.count == 14 ? number(12) : 0)
        guard date.isValidDate(in: local) else { return nil }
        return local.date(from: date)
    }
}
