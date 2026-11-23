import Foundation

/// Catalog JSON is decoded on one background actor, with bounded input complexity.
/// Thirty network responses cannot become thirty simultaneous allocation-heavy decoders.
enum CatalogResponseParser {
    private static let worker = Worker()

    static func decode(_ data: Data, maximumBytes: Int = 20_000_000) async throws -> [String: JSONValue] {
        try Task.checkCancellation()
        return try await worker.decode(data, maximumBytes: maximumBytes)
    }

    static func validate(_ data: Data, maximumBytes: Int = 20_000_000) throws {
        guard data.count <= maximumBytes else { throw BoundedHTTPData.TooLarge(limit: maximumBytes) }
        var depth = 0, elements = 0, quoted = false, escaped = false
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                continue
            }
            switch byte {
            case 34: quoted = true
            case 91, 123:
                depth += 1; elements += 1
                guard depth <= 64 else { throw TVError.unsupported("站点响应层级过深，已停止解析。") }
            case 93, 125: depth -= 1
            case 44: elements += 1
            default: break
            }
            guard elements <= 100_000 else { throw TVError.unsupported("站点响应条目过多，请缩小关键词后重试。") }
        }
    }

    private actor Worker {
        func decode(_ data: Data, maximumBytes: Int) throws -> [String: JSONValue] {
            try Task.checkCancellation()
            try validate(data, maximumBytes: maximumBytes)
            let value = try JSONDecoder().decode([String: JSONValue].self, from: data)
            try Task.checkCancellation()
            return value
        }
    }
}
