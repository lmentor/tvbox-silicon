import Foundation

public enum IPTVGuideCatchup {
    public static func line(_ live: IPTVLine, for show: IPTVProgramme, now: Date, zone: TimeZone) -> IPTVLine? {
        guard !live.isRecording, let spec = live.catchup, show.end > show.start, show.end <= now else { return nil }
        // A declared template is still usable when the provider omits retention.
        // Explicit zero/negative days disable it; known windows remain enforced.
        if let days = spec.days, days <= 0 || now.timeIntervalSince(show.start) > Double(days) * 86_400 { return nil }
        guard let url = resolve(spec, live: live.url, show: show, zone: zone) else { return nil }
        return IPTVLine(name: live.name, url: url, headers: IPTVHeaders.inherited(live.headers, from: live.url, to: url), isFinite: true)
    }

    public static func supports(_ line: IPTVLine, zone: TimeZone) -> Bool {
        guard !line.isRecording, let spec = line.catchup, spec.days.map({ $0 > 0 }) ?? true else { return false }
        let sample = IPTVProgramme(title: "", start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 3600))
        return resolve(spec, live: line.url, show: sample, zone: zone) != nil
    }

    private static let datePattern = try! NSRegularExpression(pattern: #"^(?:yyyy|MM|dd|HH|mm|ss|[-_:.T/])+$"#)
    private static let placeholders = try! NSRegularExpression(pattern: #"\$?\{([^{}]+)\}"#)

    private static func resolve(_ spec: IPTVCatchup, live: URL, show: IPTVProgramme, zone: TimeZone) -> URL? {
        var source = spec.source
        guard !source.isEmpty, source.utf8.count < 16_384 else { return nil }
        let matches = placeholders.matches(in: source, range: NSRange(source.startIndex..., in: source))
        for match in matches.reversed() {
            guard let tag = Range(match.range(at: 1), in: source), let whole = Range(match.range, in: source),
                  let value = render(String(source[tag]), show: show, zone: zone) else { return nil }
            source.replaceSubrange(whole, with: value)
        }
        guard !source.contains("{"), !source.contains("}") else { return nil }
        let address: URL?
        switch spec.mode.lowercased() {
        case "default":
            address = URL(string: source, relativeTo: live)?.absoluteURL
        case "append":
            guard source.hasPrefix("?") || source.hasPrefix("&") else { return nil }
            var parts = live.absoluteString.components(separatedBy: "#")
            var base = parts.removeFirst()
            if let replace = spec.replace, !replace.isEmpty {
                let pair = replace.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2, !pair[0].isEmpty else { return nil }
                // Path rules are literal. Never rewrite a signature or other query value.
                let query = base.firstIndex(of: "?") ?? base.endIndex
                base = base[..<query].replacingOccurrences(of: String(pair[0]), with: String(pair[1])) + base[query...]
            }
            let join = base.hasSuffix("?") || base.hasSuffix("&") ? "" : (base.contains("?") ? "&" : "?")
            let fragment = parts.isEmpty ? "" : "#" + parts.joined(separator: "#")
            address = URL(string: base + join + source.dropFirst() + fragment)
        default: return nil
        }
        guard let address, ["http", "https"].contains(address.scheme?.lowercased()), address.host != nil else { return nil }
        return address
    }

    private static func render(_ token: String, show: IPTVProgramme, zone: TimeZone) -> String? {
        let begin = String(Int64(show.start.timeIntervalSince1970))
        let end = String(Int64(show.end.timeIntervalSince1970))
        switch token {
        case "utc", "utc:timestamp", "start": return begin
        case "utcend", "utcend:timestamp", "end": return end
        case "duration": return String(Int64(show.end.timeIntervalSince(show.start)))
        default: break
        }
        let date: Date
        let format: String
        if token.hasPrefix("(b)") || token.hasPrefix("(e)") {
            date = token.hasPrefix("(b)") ? show.start : show.end
            format = String(token.dropFirst(3))
        } else { return nil }
        if format == "timestamp" { return String(Int64(date.timeIntervalSince1970)) }
        // Only provider-defined date components and URL-safe separators are meaningful here.
        let range = NSRange(format.startIndex..., in: format)
        guard format.utf8.count <= 64, datePattern.firstMatch(in: format, range: range) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = format.replacingOccurrences(of: "T", with: "'T'")
        return formatter.string(from: date)
    }
}
