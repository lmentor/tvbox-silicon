import Foundation

public struct IPTVCatchup: Codable, Hashable, Sendable {
    public var mode: String
    public var source: String
    public var days: Int?
    public var replace: String?

    public init(mode: String, source: String, days: Int? = nil, replace: String? = nil) {
        self.mode = mode
        self.source = source
        self.days = days
        self.replace = replace
    }
}

public struct IPTVLine: Codable, Hashable, Sendable {
    public var name: String
    public var url: URL
    public var headers: [String: String]
    public var catchup: IPTVCatchup?
    public var isFinite: Bool

    /// A playlist can mix live channels with archived media files. Keep this
    /// derived so records saved before finite playback support work on reopening.
    public var isRecording: Bool {
        isFinite || (["http", "https"].contains(url.scheme?.lowercased()) &&
            ["mp4", "m4v", "mov", "mkv", "avi", "webm"].contains(url.pathExtension.lowercased()))
    }

    public init(name: String, url: URL, headers: [String: String] = [:], catchup: IPTVCatchup? = nil, isFinite: Bool = false) {
        self.name = name
        self.url = url
        self.headers = headers
        self.catchup = catchup
        self.isFinite = isFinite
    }

    private enum CodingKeys: String, CodingKey { case name, url, headers, catchup, isFinite }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try values.decode(String.self, forKey: .name), url: try values.decode(URL.self, forKey: .url),
                  headers: try values.decodeIfPresent([String: String].self, forKey: .headers) ?? [:],
                  catchup: try values.decodeIfPresent(IPTVCatchup.self, forKey: .catchup),
                  isFinite: try values.decodeIfPresent(Bool.self, forKey: .isFinite) ?? false)
    }
}

public struct IPTVStation: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var group: String
    public var number: String?
    public var logo: URL?
    public var guideID: String?
    public var guideName: String?
    public var guideURL: String?
    public var guideOrigin: URL?
    public var guideHeaders: [String: String]?
    public var lines: [IPTVLine]

    public init(id: String, name: String, group: String = "", number: String? = nil, logo: URL? = nil,
                guideID: String? = nil, guideName: String? = nil, guideURL: String? = nil, lines: [IPTVLine]) {
        self.id = id
        self.name = name
        self.group = group
        self.number = number
        self.logo = logo
        self.guideID = guideID
        self.guideName = guideName
        self.guideURL = guideURL
        self.lines = lines
    }
}

extension IPTVStation {
    mutating func bindGuide(headers: [String: String], origin: URL?, explicit: [String: String] = [:]) {
        guard let guideURL, let guide = try? WebAddress.resolve(guideURL) else { return }
        var parts = URLComponents()
        parts.scheme = guide.scheme
        parts.host = guide.host
        parts.port = guide.port
        self.guideOrigin = parts.url
        guideHeaders = mergeHeaders(IPTVHeaders.inherited(headers, from: origin, to: guide), explicit)
    }
}

public struct IPTVChild: Sendable {
    public var url: URL
    public var name: String
    public var namespace: String
    public var headers: [String: String]
    public var guideURL: String?
}

public enum IPTVEntry: Hashable, Sendable {
    case station(Int)
    case child(Int)
}

/// One document, parsed relative to the address at which it was actually served.
/// The caller follows child lists in entry order, keeping fetching and storage independent of parsing.
public struct IPTVDocument: Sendable {
    public var platforms: [IPTVPlatform] = []
    public var stations: [IPTVStation] = []
    public var children: [IPTVChild] = []
    public var entries: [IPTVEntry] = []
    public var epgURLs: [String] = []
    public var warnings: [String] = []
    public var format: String

    public init(format: String) { self.format = format }

    public static func direct(url: URL, title: String, sourceID: String, namespace: String = "",
                              headers: [String: String] = [:], guideURL: String? = nil, isFinite: Bool = false) -> Self {
        var result = Self(format: isFinite ? "HLS 录像" : "单频道")
        var station = IPTVStation(id: identity([sourceID, namespace, "direct"]), name: clean(title) ?? "直播频道",
                                  guideURL: guideURL, lines: [IPTVLine(name: "线路 1", url: url, headers: headers, isFinite: isFinite)])
        station.bindGuide(headers: headers, origin: url)
        result.stations = [station]
        result.entries = [.station(0)]
        result.epgURLs = [guideURL].compactMap { $0 }
        return result
    }

    public static func parse(_ data: Data, baseURL: URL?, title: String, sourceID: String,
                             namespace: String = "", headers: [String: String] = [:], guideURL: String? = nil) throws -> Self {
        var reader = CatalogReader(base: baseURL, sourceID: sourceID, namespace: namespace, headers: headers, guide: guideURL)
        let trimming = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
        var text = String(data: data, encoding: .utf8)
        // Some live room lists contain a broken surrogate in a broadcaster's display name.
        // Repair recognizable M3U text only; media addresses containing replacements are skipped below.
        if text == nil, !data.contains(0),
           String(decoding: data.prefix(256), as: UTF8.self).trimmingCharacters(in: trimming).uppercased().hasPrefix("#EXTM3U") {
            text = String(decoding: data, as: UTF8.self)
            reader.document.warnings.append("清单含有无效文字编码，已替换损坏字符并跳过受影响的线路地址。")
        }
        let trimmed = text?.trimmingCharacters(in: trimming)
        let startsM3U = trimmed?.uppercased().hasPrefix("#EXTM3U") == true || trimmed?.uppercased().hasPrefix("#EXTINF:") == true
        // Live settings accepts the same TVBox image envelopes, encrypted and commented JSON
        // as ordinary subscriptions. Decode the original bytes before requiring UTF-8 text.
        if trimmed == nil || trimmed?.hasPrefix("{") == true || trimmed?.hasPrefix("2423") == true {
            try reader.readJSON(.object(SubscriptionDocument.decode(data)))
        } else if let trimmed, trimmed.hasPrefix("[") {
            try reader.readJSON(JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)))
        } else if !startsM3U, let object = try? SubscriptionDocument.decode(data) {
            try reader.readJSON(.object(object))
        } else {
            guard let trimmed, !trimmed.isEmpty else { throw TVError.unsupported("直播清单为空。") }
            let lines = trimmed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            if lines.contains(where: { line in hlsTags.contains(tag(line)) }) {
                guard let baseURL else { throw TVError.unsupported("本地 HLS 清单需要可访问的媒体地址，请填写该清单的远程地址。") }
                let finite = lines.contains { tag($0) == "#EXT-X-ENDLIST" || $0.uppercased() == "#EXT-X-PLAYLIST-TYPE:VOD" }
                var doc = direct(url: baseURL, title: title, sourceID: sourceID, namespace: namespace,
                                 headers: headers, guideURL: guideURL, isFinite: finite)
                doc.format = finite ? "HLS 录像" : "HLS"
                return doc
            }
            if trimmed.hasPrefix("<") { throw TVError.unsupported("收到网页或 XML，未找到可导入的直播频道。") }
            reader.readPlaylist(lines)
        }
        return reader.finish()
    }

    private static let hlsTags: Set<String> = ["#EXT-X-STREAM-INF", "#EXT-X-I-FRAME-STREAM-INF", "#EXT-X-MEDIA",
        "#EXT-X-TARGETDURATION", "#EXT-X-MEDIA-SEQUENCE", "#EXT-X-PART", "#EXT-X-PLAYLIST-TYPE", "#EXT-X-ENDLIST"]

    private static func tag(_ line: String) -> String {
        String(line.prefix { $0 != ":" }).uppercased()
    }
}

private func clean(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func normalized(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .widthInsensitive],
        locale: Locale(identifier: "en_US_POSIX")).split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

/// Length-prefix each component so opaque provider IDs cannot collide at a separator.
private func identity(_ parts: [String]) -> String {
    PluginChecksum.sha256(Data(parts.map { "\($0.utf8.count):\($0)" }.joined().utf8))
}

private func mergeHeaders(_ inherited: [String: String], _ overrides: [String: String]) -> [String: String] {
    var result = [String: String]()
    var keys = [String: String]()
    for scope in [inherited, overrides] {
        for key in scope.keys.sorted() {
            let name = key.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.allSatisfy({ (33...126).contains($0) && $0 != 58 }),
                  let value = scope[key], !value.contains(where: { $0.isNewline || $0 == "\0" }) else { continue }
            if let previous = keys.updateValue(name, forKey: name.lowercased()) { result.removeValue(forKey: previous) }
            result[name] = value
        }
    }
    return result
}

/// Source-level credentials belong to their origin. Explicit fields on a particular list/line
/// are applied after this filter, so a provider can name the destination that should receive them.
public enum IPTVHeaders {
    public static func inherited(_ headers: [String: String], from origin: URL?, to target: URL) -> [String: String] {
        func port(_ url: URL) -> Int? { url.port ?? ["http": 80, "https": 443][url.scheme?.lowercased() ?? ""] }
        if let origin, origin.host?.lowercased() == target.host?.lowercased(),
           origin.scheme?.lowercased() == target.scheme?.lowercased(), port(origin) == port(target) { return headers }
        let transferable = ["user-agent", "accept", "accept-language"]
        return headers.filter { transferable.contains($0.key.lowercased()) }
    }
}

private struct CatalogReader {
    typealias Object = [String: JSONValue]
    let base: URL?
    let sourceID: String
    let namespace: String
    let headers: [String: String]
    let guide: String?
    var document = IPTVDocument(format: "")
    // A duplicate guide ID can designate different stations in different groups. Determine
    // uniqueness after reading the entire document, independently of list/line ordering.
    private enum ParsedEntry {
        case station(IPTVStation)
        case child(Int)
    }

    private var parsed: [ParsedEntry] = []
    var stationIndex: [[String]: Int] = [:]
    var numbers: [[String]: Set<String>] = [:]
    var childIDs = Set<String>()
    var skipped = 0

    init(base: URL?, sourceID: String, namespace: String, headers: [String: String], guide: String?) {
        self.base = base
        self.sourceID = sourceID
        self.namespace = namespace
        self.headers = headers
        self.guide = guide
        if let guide { document.epgURLs = [guide] }
    }

    mutating func finish() -> IPTVDocument {
        // A repeated line may omit a number declared elsewhere. Match it only when the
        // number is unambiguous, then combine routes in their original document order.
        for entry in parsed {
            switch entry {
            case .child(let index):
                document.entries.append(.child(index))
            case .station(var station):
                if station.number == nil, let values = numbers[stationKey(station)], values.count == 1 {
                    station.number = values.first
                }
                mergeStation(station)
            }
        }
        parsed.removeAll()
        var occurrences: [String: Int] = [:]
        for station in document.stations { if let id = station.guideID { occurrences[id, default: 0] += 1 } }
        for index in document.stations.indices {
            let station = document.stations[index]
            var parts = [sourceID, namespace]
            if let guideID = station.guideID {
                parts += ["guide", guideID]
                if occurrences[guideID] == 1 {
                    document.stations[index].id = identity(parts)
                    continue
                }
            }
            parts += ["station", normalized(station.group), normalized(station.name)]
            let key = stationKey(station)
            if (numbers[key]?.count ?? 0) > 1 { parts += ["number", station.number ?? ""] }
            document.stations[index].id = identity(parts)
        }
        if skipped > document.warnings.count { document.warnings.append("另有 \(skipped - document.warnings.count) 项未导入。") }
        return document
    }

    mutating func warn(_ position: String, _ message: String) {
        skipped += 1
        if document.warnings.count < 50 { document.warnings.append("\(position) · \(message)") }
    }

    private func stationKey(_ item: IPTVStation) -> [String] {
        [item.guideID ?? "", normalized(item.group), normalized(item.name)]
    }

    mutating func addStation(_ station: IPTVStation, guideHeaders: [String: String] = [:]) {
        var item = station
        item.bindGuide(headers: headers, origin: base, explicit: guideHeaders)
        if let number = item.number { numbers[stationKey(item), default: []].insert(number) }
        parsed.append(.station(item))
    }

    private mutating func mergeStation(_ item: IPTVStation) {
        let baseKey = stationKey(item)
        let key = baseKey + [item.number ?? ""]
        let index: Int
        if let found = stationIndex[key] {
            index = found
        } else {
            index = document.stations.count
            stationIndex[key] = index
            var copy = item
            copy.lines = []
            document.stations.append(copy)
            document.entries.append(.station(index))
        }
        for var line in item.lines {
            if document.stations[index].lines.contains(where: {
                $0.url == line.url && $0.headers == line.headers && $0.catchup == line.catchup &&
                    (line.name.isEmpty || $0.name == line.name)
            }) { continue }
            if line.name.isEmpty { line.name = "线路 \(document.stations[index].lines.count + 1)" }
            document.stations[index].lines.append(line)
        }
    }

    func urlIssue(_ raw: String) -> String {
        if base == nil && URLComponents(string: raw)?.scheme == nil {
            return "本地单文件缺少相对链接引用的资源，请使用绝对地址或导入远程清单。"
        }
        return "线路地址无效或协议暂不支持。"
    }

    func guideAddress(_ raw: String?) -> String? {
        guard let raw = clean(raw), let url = try? WebAddress.resolve(raw, relativeTo: base) else { return nil }
        // WebAddress encodes braces. The guide client needs to recognize the declared DIYP tokens.
        var value = url.absoluteString
        for token in ["name", "date"] where raw.contains("{\(token)}") {
            value = value.replacingOccurrences(of: "%7B\(token)%7D", with: "{\(token)}", options: .caseInsensitive)
        }
        return value
    }

    mutating func rememberGuide(_ address: String?) {
        if let address, !document.epgURLs.contains(address) { document.epgURLs.append(address) }
    }

    static let attributePattern = try! NSRegularExpression(pattern: #"(?i)(?:^|\s)([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s,]+))"#)
    static func attributes(_ text: String) -> [String: String] {
        var result = [String: String]()
        for match in attributePattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let key = Range(match.range(at: 1), in: text),
                  let range = (2...4).compactMap({ Range(match.range(at: $0), in: text) }).first else { continue }
            result[text[key].lowercased()] = String(text[range])
        }
        return result
    }

    static func fieldSeparator(_ line: String) -> String.Index? {
        var quote: Character?
        for i in line.indices {
            let c = line[i]
            if let active = quote { if c == active { quote = nil } }
            else if c == "\"" || c == "'" { quote = c }
            else if c == "," { return i }
        }
        return nil
    }

    static func unquote(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespaces)
        if value.count >= 2 && value.first == "\"" && value.last == "\"" {
            return value.dropFirst().dropLast().replacingOccurrences(of: "\"\"", with: "\"")
        }
        return value
    }

    static let routeSeparator = try! NSRegularExpression(pattern: #"(?i)#(?=(?:https?|rtmps?|rtsps?|udp|rtp)://)"#)
    // "$" and "#" also occur in signed URLs. Split only a known route label or an explicit second URI.
    static let routeLabel = try! NSRegularExpression(pattern:
        #"(?i)\$(线路[\p{L}\d _-]{0,18}|線路[\p{L}\d _-]{0,18}|主线|主線|备用[\d一二三四五]*|備用[\d一二三四五]*|备线|標清|标清|高清|超清|蓝光|4K|8K|HD|SD|FHD|(?:line|cdn)[ _-]?[a-z\d]{0,8}|[\d]{1,3})$"#)

    func mediaLines(_ raw: String, label: String?, specificHeaders: [String: String], catchup: IPTVCatchup?) -> [IPTVLine] {
        let routes = Self.routeSeparator.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "\n")
        return routes.components(separatedBy: "\n").compactMap { route in
            let parts = route.components(separatedBy: "|")
            var address = parts[0].trimmingCharacters(in: .whitespaces)
            var explicit = specificHeaders
            var name = label ?? ""
            if let match = Self.routeLabel.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)),
               let suffix = Range(match.range(at: 1), in: address), let whole = Range(match.range, in: address) {
                // An ASCII token after a literal dollar inside a query/fragment can be signed data.
                let before = address[..<whole.lowerBound]
                let localizedLabel = address[suffix].contains { !$0.isASCII }
                if (!before.contains("?") && !before.contains("#")) || localizedLabel {
                    if name.isEmpty { name = String(address[suffix]) }
                    address.removeSubrange(whole)
                }
            }
            guard !address.isEmpty, !address.contains("\u{FFFD}"),
                  let url = try? MediaAddress.resolve(address, relativeTo: base) else { return nil }
            for options in parts.dropFirst() {
                for pair in options.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard kv.count == 2 else { continue }
                    let key = String(kv[0])
                    explicit = mergeHeaders(explicit, [key: kv[1].removingPercentEncoding ?? String(kv[1])])
                }
            }
            return IPTVLine(name: name, url: url, headers: mergeHeaders(IPTVHeaders.inherited(headers, from: base, to: url), explicit), catchup: catchup)
        }
    }

    static func catchup(_ attributes: [String: String]) -> IPTVCatchup? {
        guard let source = clean(attributes["catchup-source"]) else { return nil }
        return IPTVCatchup(mode: clean(attributes["catchup"])?.lowercased() ?? "default", source: source,
                           days: attributes["catchup-days"].flatMap(Int.init), replace: clean(attributes["catchup-replace"]))
    }

    private static let playlistHeaderNames = ["http-user-agent": "User-Agent", "http-referrer": "Referer",
                                              "http-referer": "Referer", "http-origin": "Origin", "http-cookie": "Cookie"]

    static func playlistHeaders(_ attributes: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        // Attributes on EXTINF apply to that channel just like EXTVLCOPT. Several APTV
        // channels also declare a single header as http-header="Referer=https://...".
        if let field = clean(attributes["http-header"]), let split = field.firstIndex(of: "=") {
            result = mergeHeaders(result, [String(field[..<split]): String(field[field.index(after: split)...])])
        }
        for key in playlistHeaderNames.keys.sorted() {
            if let value = clean(attributes[key]), let name = playlistHeaderNames[key] {
                result = mergeHeaders(result, [name: value])
            }
        }
        return result
    }

    mutating func readPlaylist(_ lines: [String]) {
        let m3u = lines.contains { $0.uppercased().hasPrefix("#EXTINF:") || $0.uppercased().hasPrefix("#EXTM3U") }
        document.format = m3u ? "M3U" : "TXT"
        var group = "", defaultGroup = "", pending: String?, position = 0
        var entry: [String: String] = [:], global: [String: String] = [:], opts: [String: String] = [:]
        var addressGuide = guide
        for (i, line) in lines.enumerated() where !line.isEmpty {
            let tag = line.uppercased()
            if tag.hasPrefix("#EXTM3U") {
                global = Self.attributes(line)
                let values = (global["x-tvg-url"] ?? global["url-tvg"] ?? "").split(separator: ",")
                let urls = values.compactMap { guideAddress(String($0)) }
                for url in urls { rememberGuide(url) }
                addressGuide = guide ?? urls.first
            } else if tag.hasPrefix("#EXTINF:") {
                if pending != nil { warn("第 \(position) 行", "频道缺少线路地址。") }
                position = i + 1
                let split = Self.fieldSeparator(line)
                pending = split.flatMap { clean(Self.unquote(String(line[line.index(after: $0)...]))) } ?? ""
                entry = Self.attributes(String(line[..<(split ?? line.endIndex)]))
                group = entry["group-title"] ?? defaultGroup
                opts = [:]
            } else if tag.hasPrefix("#EXTGRP:") {
                group = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                defaultGroup = group
            } else if tag.hasPrefix("#EXTVLCOPT:") {
                let opt = line.dropFirst(11).split(separator: "=", maxSplits: 1)
                if opt.count == 2, let key = Self.playlistHeaderNames[opt[0].lowercased()] { opts[key] = String(opt[1]) }
            } else if !line.hasPrefix("#") {
                var address = line
                if !m3u {
                    guard let split = Self.fieldSeparator(line) else { warn("第 \(i + 1) 行", "缺少台名或地址。"); continue }
                    pending = Self.unquote(String(line[..<split]))
                    address = String(line[line.index(after: split)...]).trimmingCharacters(in: .whitespaces)
                    if address.caseInsensitiveCompare("#genre#") == .orderedSame { group = pending ?? ""; pending = nil; continue }
                }
                guard let name = clean(pending) else {
                    warn("第 \(i + 1) 行", "缺少频道名称。")
                    pending = nil
                    continue
                }
                let attrs = global.merging(entry) { _, new in new }
                let declared = mergeHeaders(Self.playlistHeaders(global), Self.playlistHeaders(entry))
                let routes = mediaLines(address, label: nil, specificHeaders: mergeHeaders(declared, opts), catchup: Self.catchup(attrs))
                if routes.isEmpty { warn("第 \(i + 1) 行", urlIssue(address)) }
                else {
                    addStation(IPTVStation(id: "", name: name, group: group, number: clean(entry["tvg-chno"] ?? entry["channel-number"]),
                        logo: entry["tvg-logo"].flatMap { try? WebAddress.resolve($0, relativeTo: base) },
                        guideID: clean(entry["tvg-id"]), guideName: clean(entry["tvg-name"]), guideURL: addressGuide, lines: routes))
                }
                pending = nil
                opts = [:]
                entry = [:]
            }
        }
        if pending != nil { warn("第 \(position) 行", "频道缺少线路地址。") }
    }

    static func jsonHeaders(_ object: Object) -> [String: String] {
        var fields = object["header"]?.object?.compactMapValues(\.string) ?? object["headers"]?.object?.compactMapValues(\.string) ?? [:]
        if let ua = clean(object["ua"]?.string) { fields = mergeHeaders(["User-Agent": ua], fields) }
        return fields
    }

    mutating func readJSON(_ root: JSONValue) throws {
        document.format = "TVBox JSON"
        if let object = root.object {
            do {
                document.platforms = try IPTVPlatform.registered(in: object, origin: base, headers: headers)
            } catch {
                // A malformed script declaration must not hide ordinary IPTV entries beside it.
                guard object["lives"]?.array != nil || object["groups"]?.array != nil ||
                        object["channels"]?.array != nil else { throw error }
                warn("直播平台", "部分平台缺少兼容的适配器。")
            }
            if let lists = object["lives"]?.array {
                // TVBox lives[].url refers to a list, whereas channels[].url refers to one line.
                var nameCounts: [String: Int] = [:]
                for item in lists {
                    if let name = clean(item.object?["name"]?.string) { nameCounts[normalized(name), default: 0] += 1 }
                }
                for (i, value) in lists.enumerated() {
                    guard let live = value.object else { warn("lives[\(i)]", "需要直播清单或频道分组。"); continue }
                    let field = "lives[\(i)]"
                    if let channels = live["channels"]?.array {
                        readGroup(live, channels: channels, path: field)
                    } else if let groups = live["groups"]?.array {
                        readGroups(groups, path: field + ".groups", inherited: Self.jsonHeaders(live), guideURL: guide ?? guideAddress(live["epg"]?.string))
                    } else if let address = clean(live["url"]?.string) {
                        let key = clean(live["name"]?.string).map(normalized) ?? ""
                        readChild(live, address: address, path: field, titleUnique: nameCounts[key] == 1)
                    } else {
                        warn(field, live["api"] == nil ? "缺少 url 或 channels。" : "此脚本直播项缺少兼容的平台适配器。")
                    }
                }
            } else if let groups = object["groups"]?.array {
                readGroups(groups, path: "groups", inherited: [:], guideURL: guide)
            } else if let channels = object["channels"]?.array {
                readGroup(object, channels: channels, path: "channels")
            } else if document.platforms.isEmpty {
                throw TVError.unsupported("未找到可导入的直播频道。")
            }
        } else if let groups = root.array {
            document.format = "分组 JSON"
            readGroups(groups, path: "groups", inherited: [:], guideURL: guide)
        }
    }

    mutating func readGroups(_ groups: [JSONValue], path: String, inherited: [String: String], guideURL: String?) {
        for (index, group) in groups.enumerated() {
            guard let object = group.object else { warn("\(path)[\(index)]", "需要频道分组。"); continue }
            if let channels = object["channels"]?.array {
                readGroup(object, channels: channels, path: "\(path)[\(index)]", inherited: inherited, guideURL: guideURL)
            } else if object["urls"] != nil || object["url"] != nil {
                readJSONStation(object, group: clean(object["group"]?.string) ?? "", fields: inherited,
                                guideURL: guideURL, path: "\(path)[\(index)]")
            } else { warn("\(path)[\(index)]", "分组缺少 channels。") }
        }
    }

    mutating func readGroup(_ object: Object, channels: [JSONValue], path: String,
                            inherited: [String: String] = [:], guideURL: String? = nil) {
        let group = clean(object["group"]?.string ?? object["name"]?.string) ?? ""
        let fields = mergeHeaders(inherited, Self.jsonHeaders(object))
        let epg = guide ?? guideURL ?? guideAddress(object["epg"]?.string)
        rememberGuide(epg)
        for (i, channel) in channels.enumerated() {
            let location = "\(path).channels[\(i)]"
            guard let entry = channel.object else { warn(location, "需要频道对象。"); continue }
            readJSONStation(entry, group: group, fields: fields, guideURL: epg, path: location)
        }
    }

    mutating func readJSONStation(_ object: Object, group: String, fields: [String: String], guideURL: String?, path: String) {
        guard let name = clean(object["name"]?.string) else { warn(path, "频道缺少台名。"); return }
        let raw = object["urls"] ?? object["url"]
        guard let raw else { warn(path, "频道缺少线路地址。"); return }
        let items = raw.array ?? [raw]
        let stationFields = mergeHeaders(fields, Self.jsonHeaders(object))
        var routes: [IPTVLine] = []
        for (index, item) in items.enumerated() {
            let line = item.object ?? [:]
            guard let address = clean(item.string ?? line["url"]?.string) else {
                warn("\(path).urls[\(index)]", "线路缺少地址。")
                continue
            }
            let lineFields = mergeHeaders(stationFields, Self.jsonHeaders(line))
            let attrs = object.merging(line) { _, new in new }.compactMapValues(\.string)
            let parsed = mediaLines(address, label: clean(line["name"]?.string), specificHeaders: lineFields, catchup: Self.catchup(attrs))
            if parsed.isEmpty { warn("\(path).urls[\(index)]", urlIssue(address)) }
            routes.append(contentsOf: parsed)
        }
        guard !routes.isEmpty else {
            if items.isEmpty { warn(path, "频道缺少线路地址。") }
            return
        }
        let epg = guide ?? guideAddress(object["epg"]?.string) ?? guideURL
        rememberGuide(epg)
        let logo = (object["tvg-logo"] ?? object["logo"])?.string.flatMap { try? WebAddress.resolve($0, relativeTo: base) }
        addStation(IPTVStation(id: "", name: name, group: clean(object["group"]?.string) ?? group,
            number: clean((object["tvg-chno"] ?? object["number"] ?? object["num"])?.string), logo: logo,
            guideID: clean((object["tvg-id"] ?? object["id"])?.string), guideName: clean(object["tvg-name"]?.string),
            guideURL: epg, lines: routes), guideHeaders: stationFields)
    }

    mutating func readChild(_ object: Object, address: String, path: String, titleUnique: Bool) {
        guard let url = try? MediaAddress.resolve(address, relativeTo: base) else { warn(path + ".url", urlIssue(address)); return }
        let name = clean(object["name"]?.string)
        var parts = [sourceID, namespace, "list"]
        if let explicit = clean((object["id"] ?? object["key"])?.string) {
            parts += ["id", explicit]
        } else if let name, titleUnique {
            parts += ["name", normalized(name)]
        } else {
            // Keep the declared path independent of server redirection and rotating query credentials.
            let pathKey = String(address.prefix { $0 != "?" && $0 != "#" })
            parts += ["path", pathKey, normalized(name ?? "")]
        }
        let childID = identity(parts)
        guard childIDs.insert(childID).inserted else { warn(path, "子清单标识重复，请给各清单设置不同名称或 ID。"); return }
        let fields = mergeHeaders(IPTVHeaders.inherited(headers, from: base, to: url), Self.jsonHeaders(object))
        let epg = guide ?? guideAddress(object["epg"]?.string)
        rememberGuide(epg)
        parsed.append(.child(document.children.count))
        document.children.append(IPTVChild(url: url, name: name ?? clean(url.lastPathComponent) ?? "直播频道", namespace: childID,
                                           headers: fields, guideURL: epg))
    }
}
