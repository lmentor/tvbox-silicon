import Foundation

/// Only immediate resource metadata; opaque group IDs are never searched for nested URLs.
public struct SitePanShare: Codable, Hashable, Sendable {
    public let url: String
    public let password: String
    public let datetime: String
    public init?(json: [String: JSONValue]?) {
        guard let json, let url = json["url"]?.string, !url.isEmpty, url.utf8.count <= 2048 else { return nil }
        self.url = url
        password = String((json["password"]?.string ?? "").prefix(100))
        datetime = String((json["datetime"]?.string ?? "").prefix(80))
    }
    public var json: JSONValue {
        .object(["url": .string(url), "password": .string(password), "datetime": .string(datetime)])
    }
}
