import Foundation

/// A browser dismissal invalidates this fence synchronously, including while
/// QuickJS awaits its hook. Only an active request can commit the login profile.
public final class MangaWebLoginRequest: @unchecked Sendable {
    public static var userAgent: String { MangaHTTP.userAgent }
    private let lock = NSLock()
    private var active = true
    public init() {}
    public func cancel() { lock.withLock { active = false } }
    func commit(_ operation: () throws -> Void) throws {
        try lock.withLock {
            guard active else { throw CancellationError() }
            try Task.checkCancellation()
            try operation()
            active = false
        }
    }
}

/// Source callbacks see the browser cookies and storage, but cannot write to the
/// persistent account until every hook succeeds and the request still owns it.
final class MangaWebLoginTransaction: @unchecked Sendable {
    let key: String
    let cookies: MangaCookieJar
    private let lock = NSLock()
    private var data: [String: Any]
    private var changes: [String: Any] = [:]

    init(key: String, cookies: [HTTPCookie], localStorage: [String: String]) {
        self.key = key
        self.cookies = MangaCookieJar(cookies: cookies, userAgent: MangaHTTP.userAgent)
        data = MangaSourceData.shared.snapshot(key)
        data["_localStorage"] = localStorage
        changes["_localStorage"] = localStorage
    }

    func handle(_ request: [String: Any]) throws -> String? {
        guard (request["key"] as? String ?? key) == key else { throw TVError.unsupported("登录回调访问了其他漫画站点。") }
        return lock.withLock {
            if let name = request["get"] as? String { return MangaHost.json(data[name]) }
            if let name = request["set"] as? String {
                let value = request["value"] ?? NSNull()
                changes[name] = value; data[name] = value is NSNull ? nil : value
            }
            if let name = request["delete"] as? String { changes[name] = NSNull(); data[name] = nil }
            return nil
        }
    }

    func commit() throws {
        let changed = lock.withLock { changes }
        try MangaSourceData.shared.commitWebLogin(key, changes: changed, cookies: MangaCookieJar.encoded(cookies.allCookies()), userAgent: MangaHTTP.userAgent)
    }
}
