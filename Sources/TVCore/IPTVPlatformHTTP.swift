import Foundation

/// A running CatPawOpen server exposes /spider/<key>/<type>/<operation> with a JSON POST body.
struct IPTVPlatformHTTP: Sendable {
    let endpoint: URL
    let headers: [String: String]
    var usesCatPawRoutes = true

    func request(_ params: [String: String]) throws -> URLRequest {
        var method = "home"
        var values: [String: JSONValue] = [:]
        let page = JSONValue.number(Double(Int(params["pg"] ?? "") ?? 1))
        if let play = params["play"] {
            method = "play"
            values = ["id": .string(play), "flag": .string(params["flag"] ?? "")]
        } else if let id = params["ids"] {
            method = "detail"
            values = ["id": .string(id)]
        } else if let search = params["wd"] {
            method = "search"
            values = ["wd": .string(search), "page": page, "quick": .bool(false)]
        } else if let area = params["t"] {
            method = "category"
            let filters = params["ext"].flatMap { Data(base64Encoded: $0) }
                .flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) } ?? [:]
            values = ["id": .string(area), "page": page, "filter": .bool(true), "filters": .object(filters)]
        }
        var request = URLRequest(url: endpoint.appendingPathComponent(method), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(values)
        return request
    }

    func send(_ params: [String: String], client: CatalogClient) async throws -> [String: JSONValue] {
        var request: URLRequest
        if usesCatPawRoutes {
            request = try self.request(params)
        } else {
            request = URLRequest(url: try client.requestURL(params), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue(HTTPClient.userAgent, forHTTPHeaderField: "User-Agent")
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        }
        request.httpShouldHandleCookies = false
        let session = client.http.session
        let (bytes, response) = try await session.bytes(for: request, delegate: IPTVRedirectPolicy())
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw TVError.invalidConfiguration }
        if http.statusCode == 404, params["wd"] != nil { return ["list": .array([])] }
        guard (200..<300).contains(http.statusCode) else { throw TVError.http(http.statusCode) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < IPTVLibrary.maximumDocumentBytes else { throw TVError.unsupported("直播平台响应超过大小上限。") }
            data.append(byte)
        }
        if params["wd"] != nil, data.isEmpty { return ["list": .array([])] }
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }
}
