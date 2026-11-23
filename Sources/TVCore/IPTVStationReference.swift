import Foundation

/// Persist only the station identity. The enabled subscription supplies fresh transport metadata.
public enum IPTVStationReference {
    public static func channel(for station: IPTVStation) -> Channel {
        let token = Data(station.id.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        let address = URL(string: "yingxia-iptv://station")!.appendingPathComponent(token)
        return Channel(name: station.name, group: station.group, url: address, logo: nil,
                       playback: PlaybackDescriptor(format: "", isLive: true))
    }

    public static func id(for channel: Channel) -> String? {
        let url = channel.url
        guard url.scheme == "yingxia-iptv", url.host == "station", url.pathComponents.count == 2 else { return nil }
        var token = url.lastPathComponent.replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: "-", with: "+")
        token += String(repeating: "=", count: (4 - token.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: token) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
