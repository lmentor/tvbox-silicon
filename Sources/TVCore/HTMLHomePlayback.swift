import Foundation
import CoreFoundation
import CryptoKit

/// WebHome pages may hand over one on-demand Bilibili MPD. The player receives
/// only its HTTP tracks; arbitrary XML, data documents and local paths are refused.
public enum HTMLHomePlayback {
    /// Only the source, work and original episode identifiers survive an app
    /// restart. Media URLs, resource capabilities and request headers stay in memory.
    public struct History: Codable, Equatable, Sendable {
        public let sourceID: String
        public let workID: String
        public let isLive: Bool
        public let episodes: [EpisodeReference]
        public let historyID: String?
        /// A homepage is a resolver fallback, never evidence identifying a series.
        public let fallbackPage: String?
        public init(sourceID: String, workID: String, isLive: Bool, episodes: [EpisodeReference], historyID: String? = nil,
                    fallbackPage: String? = nil) {
            self.sourceID = sourceID; self.workID = workID; self.isLive = isLive; self.episodes = episodes
            self.historyID = historyID; self.fallbackPage = fallbackPage
        }
    }
    public struct EpisodeReference: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let pageURL: String
        public let resolverURL: String
        public init(id: String, name: String, pageURL: String, resolverURL: String) {
            self.id = id; self.name = name; self.pageURL = pageURL; self.resolverURL = resolverURL
        }
        public var payload: [String: String] { ["name": name, "url": resolverURL, "pageUrl": pageURL] }
    }
    /// Bounded evidence travels with history/backup records independently of the
    /// local catalog snapshot. Digests retain no playback addresses or credentials.
    public struct HistoryProof: Codable, Hashable, Sendable {
        static let referenceLimit = 128
        public let sourceID: String
        public let titleDigest: String
        public let workDigest: String?
        public let referenceDigests: [String]
        /// These fields are immutable. Validate once on construction/decoding,
        /// rather than rescanning every history row during each progress tick.
        let isValid: Bool
        private enum CodingKeys: String, CodingKey { case sourceID, titleDigest, workDigest, referenceDigests }
        init(sourceID: String, titleDigest: String, workDigest: String?, referenceDigests: [String]) {
            self.sourceID = sourceID; self.titleDigest = titleDigest; self.workDigest = workDigest; self.referenceDigests = referenceDigests
            func digest(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
            isValid = !sourceID.isEmpty && sourceID.utf8.count <= 128 && digest(titleDigest)
                && (workDigest.map(digest) ?? true) && referenceDigests.count <= Self.referenceLimit
                && (workDigest != nil || !referenceDigests.isEmpty) && referenceDigests.allSatisfy(digest)
        }
        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(sourceID: try values.decode(String.self, forKey: .sourceID),
                      titleDigest: try values.decode(String.self, forKey: .titleDigest),
                      workDigest: try values.decodeIfPresent(String.self, forKey: .workDigest),
                      referenceDigests: try values.decode([String].self, forKey: .referenceDigests))
        }
        func hasSameOwnerAndWork(as other: Self) -> Bool {
            sourceID == other.sourceID && workDigest == other.workDigest
                && (workDigest != nil || titleDigest == other.titleDigest)
        }
        func including(_ older: Self) -> Self {
            guard hasSameOwnerAndWork(as: older) else { return self }
            var seen = Set<String>()
            let references = (referenceDigests + older.referenceDigests).filter { seen.insert($0).inserted }
            return Self(sourceID: sourceID, titleDigest: titleDigest, workDigest: workDigest,
                        referenceDigests: Array(references.prefix(Self.referenceLimit)))
        }
    }
    public static func historyProof(sourceID: String, workID: String, title: String, episodes: [EpisodeReference],
                                    fallbackPages: [String] = [], selectedEpisodeID: String? = nil) -> HistoryProof? {
        guard !sourceID.isEmpty, sourceID.utf8.count <= 128, workID.utf8.count <= 32768, episodes.count <= 1000 else { return nil }
        func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
        func addressIdentity(_ value: String) -> String {
            guard var url = URLComponents(string: value) else { return value }
            url.fragment = nil
            url.scheme = url.scheme?.lowercased(); url.host = url.host?.lowercased()
            return url.string ?? value
        }
        let homepages = Set(fallbackPages.map(addressIdentity))
        let credentialKeys: Set<String> = ["token", "sign", "signature", "expires", "deadline", "wssecret", "auth_key", "authorization",
            "auth", "access_token", "password", "passwd", "pwd", "credential", "credentials", "secret", "api_key", "apikey", "access_key", "session", "sessionid"]
        let mediaExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "flv", "webm", "ts", "m2ts", "m3u8", "mpd",
            "m4s", "mp3", "m4a", "aac", "flac", "wav", "iso", "bdmv", "mpls"]
        func original(_ value: String) -> Bool {
            guard !value.isEmpty, !homepages.contains(addressIdentity(value)), resolverIdentity(value, pageURL: "") == value,
                  let url = URL(string: value), let scheme = url.scheme?.lowercased(), url.host?.lowercased() != "html-home.invalid",
                  !mediaExtensions.contains(url.pathExtension.lowercased()) else { return false }
            let keys = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { $0.name.lowercased() } ?? []
            guard !keys.contains(where: credentialKeys.contains) else { return false }
            return !["http", "https"].contains(scheme) || (!url.path.isEmpty && url.path != "/")
        }
        var selected = Set<String>(), all = Set<String>()
        for episode in episodes {
            for value in [episode.pageURL, episode.resolverURL] where original(value) {
                let reference = digest(value); all.insert(reference)
                if episode.id == selectedEpisodeID { selected.insert(reference) }
            }
        }
        guard !workID.isEmpty || !all.isEmpty else { return nil }
        let references = selected.sorted() + all.subtracting(selected).sorted()
        return HistoryProof(sourceID: sourceID, titleDigest: digest(title), workDigest: workID.isEmpty ? nil : digest(workID),
                            referenceDigests: Array(references.prefix(HistoryProof.referenceLimit)))
    }
    /// With no work ID this identifies a catalog snapshot. PlaybackHistory can
    /// link successive snapshots using their bounded, unambiguous original proof.
    public static func historyID(sourceID: String, workID: String, title: String, episodes: [EpisodeReference],
                                 fallbackPage: String? = nil) -> String? {
        let key: String
        if !workID.isEmpty { key = sourceID + "\n" + workID }
        else {
            guard historyProof(sourceID: sourceID, workID: workID, title: title, episodes: episodes,
                               fallbackPages: fallbackPage.map { [$0] } ?? []) != nil else { return nil }
            let references = episodes.map { episode in
                String(decoding: try! JSONEncoder().encode([episode.name, episode.pageURL, episode.resolverURL]), as: UTF8.self)
            }
            key = String(decoding: try! JSONEncoder().encode([sourceID, title] + Set(references).sorted()), as: UTF8.self)
        }
        return "html-media-" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// Opaque page tokens such as tx://work/episode are data passed back to the
    /// page's resolver. A temporary media address must never become that token.
    public static func resolverIdentity(_ input: String, pageURL: String, mediaURL: String = "") -> String {
        guard !input.isEmpty, input.utf8.count <= 32768,
              !input.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }),
              let url = URL(string: input), let scheme = url.scheme?.lowercased(),
              !["data", "blob", "file", "javascript", "yingxia-home"].contains(scheme),
              url.user == nil, url.password == nil else { return pageURL }
        if ["http", "https"].contains(scheme) {
            guard let host = url.host, !host.isEmpty else { return pageURL }
            if input == pageURL { return input }
            let temporaryKeys: Set<String> = ["token", "sign", "signature", "expires", "deadline", "wssecret", "auth_key", "authorization", "auth", "access_token"]
            let keys = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { $0.name.lowercased() } ?? []
            if input == mediaURL || keys.contains(where: temporaryKeys.contains)
                || ["mp4", "m4s", "m4a", "m3u8", "mpd", "flv", "mp3", "aac"].contains(url.pathExtension.lowercased()) { return pageURL }
        }
        return input
    }
    public struct Media: Equatable, Sendable {
        public let url: URL
        public let audioURL: URL?
        public let format: String
    }
    public struct Failure: LocalizedError {
        let message: String
        public var errorDescription: String? { message }
    }
    public static func address(_ input: String) throws -> URL {
        guard !input.isEmpty, input.utf8.count <= 32768,
              !input.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }),
              let url = URL(string: input), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            throw Failure(message: "首页只支持有效的 HTTP、HTTPS 或受限 DASH 媒体地址")
        }
        return url
    }
    public static func episodeIndex(_ payload: [String: Any], episodes: [[String: Any]]) throws -> Int {
        guard !episodes.isEmpty, episodes.count <= 1000 else { throw Failure(message: "首页播放列表无效") }
        for key in ["playIndex", "episodeIndex", "currentIndex", "ep_index", "startIndex", "index", "position"] {
            guard let raw = payload[key], !(raw is NSNull), (raw as? String) != "" else { continue }
            let value: Double?
            if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { value = number.doubleValue }
            else if let string = raw as? String { value = Double(string) }
            else { value = nil }
            guard let value, value.isFinite, value.rounded(.towardZero) == value,
                  value >= 0, value < Double(episodes.count) else { throw Failure(message: "首页选集序号无效") }
            return Int(value)
        }
        return payload["mark"].flatMap { $0 as? String }.flatMap { mark in episodes.firstIndex { $0["name"] as? String == mark } } ?? 0
    }
    public static func media(_ input: String) throws -> Media {
        let prefix = "data:application/dash+xml;base64,"
        guard input.lowercased().hasPrefix(prefix) else { return Media(url: try address(input), audioURL: nil, format: "") }
        let encoded = String(input.dropFirst(prefix.count)), limit = 256 * 1024
        guard !encoded.isEmpty, encoded.utf8.count <= 4 * ((limit + 2) / 3),
              let data = Data(base64Encoded: encoded), data.count <= limit,
              data.base64EncodedString() == encoded, let xml = String(data: data, encoding: .utf8) else {
            throw Failure(message: "DASH 清单编码无效或超过 256 KiB")
        }
        guard !xml.contains("<!") else { throw unsupported }
        let delegate = SegmentBaseDocument()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), !delegate.failed, delegate.complete, let video = delegate.tracks["video"] else { throw unsupported }
        return Media(url: video, audioURL: delegate.tracks["audio"], format: "mp4")
    }
    private static var unsupported: Failure {
        Failure(message: "此 DASH 清单暂不支持，仅支持单视频和可选单音频的静态 SegmentBase 清单")
    }

    private final class SegmentBaseDocument: NSObject, XMLParserDelegate {
        var failed = false
        var complete = false
        var tracks: [String: URL] = [:]
        private var path: [String] = []
        private var childCounts: [Int] = []
        private var kind = ""
        private var text = ""

        private func reject(_ parser: XMLParser) { failed = true; parser.abortParsing() }
        private func attributes(_ input: [String: String], allowed: [String]) -> Bool {
            Set(input.keys).isSubset(of: Set(allowed))
        }
        private func range(_ value: String?) -> Bool {
            guard let value else { return false }
            let parts = value.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
                  let first = UInt64(parts[0]), let last = UInt64(parts[1]), first <= last, last <= 9_007_199_254_740_991 else { return false }
            return true
        }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes fields: [String: String] = [:]) {
            let parent = path.last
            if !childCounts.isEmpty { childCounts[childCounts.count - 1] += 1 }
            let ordinal = childCounts.last ?? 1
            var valid = false
            switch elementName {
            case "MPD":
                valid = parent == nil && !complete && fields["type"] == "static" &&
                    (fields["xmlns"] == nil || fields["xmlns"] == "urn:mpeg:dash:schema:mpd:2011") &&
                    attributes(fields, allowed: ["xmlns", "type", "mediaPresentationDuration", "minBufferTime", "profiles"])
            case "Period":
                valid = parent == "MPD" && ordinal == 1 && (fields["start"] == nil || fields["start"] == "PT0S") &&
                    attributes(fields, allowed: ["id", "start"])
            case "AdaptationSet":
                let mime = fields["mimeType"] ?? ""
                kind = mime == "video/mp4" ? "video" : mime == "audio/mp4" ? "audio" : ""
                valid = parent == "Period" && ordinal <= 2 && !kind.isEmpty && tracks[kind] == nil &&
                    (fields["contentType"] == nil || fields["contentType"] == kind) &&
                    attributes(fields, allowed: ["id", "mimeType", "contentType", "segmentAlignment", "startWithSAP", "lang"])
            case "Representation":
                valid = parent == "AdaptationSet" && ordinal == 1 &&
                    (fields["mimeType"] == nil || fields["mimeType"] == kind + "/mp4") &&
                    attributes(fields, allowed: ["id", "bandwidth", "codecs", "mimeType", "width", "height", "frameRate", "sar", "audioSamplingRate", "startWithSAP"])
            case "BaseURL": valid = parent == "Representation" && ordinal == 1 && fields.isEmpty; text = ""
            case "SegmentBase": valid = parent == "Representation" && ordinal == 2 && attributes(fields, allowed: ["indexRange"]) && range(fields["indexRange"])
            case "Initialization": valid = parent == "SegmentBase" && ordinal == 1 && attributes(fields, allowed: ["range"]) && range(fields["range"])
            default: break
            }
            guard valid else { reject(parser); return }
            path.append(elementName); childCounts.append(0)
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if path.last == "BaseURL" { text += string }
            else if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reject(parser) }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard path.last == elementName, let count = childCounts.last else { reject(parser); return }
            let expected: Bool
            switch elementName {
            case "MPD": expected = count == 1; complete = true
            case "Period": expected = (1...2).contains(count)
            case "AdaptationSet", "SegmentBase": expected = count == 1
            case "Representation": expected = count == 2
            case "BaseURL":
                expected = count == 0
                do { tracks[kind] = try HTMLHomePlayback.address(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                catch { reject(parser); return }
            case "Initialization": expected = count == 0
            default: expected = false
            }
            guard expected else { reject(parser); return }
            path.removeLast(); childCounts.removeLast()
        }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { reject(parser) }
        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) { reject(parser) }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { reject(parser); return nil }
        func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) { failed = true }
    }
}
