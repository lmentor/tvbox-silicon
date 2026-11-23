import Foundation

/// A streaming byte ceiling, applied before accepting a declared length or another chunk.
/// Reuses the caller's session, authentication, proxy and connection pool.
enum BoundedHTTPData {
    static let searchBytes = 8 * 1024 * 1024
    static let catalogBytes = 20_000_000
    private static let budget = HTTPBudget()

    struct TooLarge: LocalizedError {
        let limit: Int
        var errorDescription: String? { "站点响应超过 \(max(1, limit / 1024 / 1024)) MB，已停止读取。" }
    }

    static func load(_ request: URLRequest, session: URLSession, maximumBytes: Int, followsRedirects: Bool = true,
                     redirectHandler: (@Sendable (HTTPURLResponse, URLRequest) -> URLRequest?)? = nil,
                     countsTowardBudget: Bool = true) async throws -> (Data, URLResponse) {
        let limit = max(1, maximumBytes)
        if countsTowardBudget { try await budget.acquire() }
        do {
            try Task.checkCancellation()
            let transfer = Transfer(limit: limit, followsRedirects: followsRedirects, redirectHandler: redirectHandler)
            let result = try await withTaskCancellationHandler {
                try await transfer.start(request, session: session)
            } onCancel: { transfer.cancel() }
            try Task.checkCancellation()
            if countsTowardBudget { await budget.release() }
            return result
        } catch {
            if countsTowardBudget { await budget.release() }
            throw error
        }
    }

    /// Chunk callbacks keep parsing off the URLSession delegate and avoid a per-byte
    /// async loop. Only didComplete resumes a caller, including cancellation/oversize.
    private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let limit: Int
        let followsRedirects: Bool
        let redirectHandler: (@Sendable (HTTPURLResponse, URLRequest) -> URLRequest?)?
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var continuation: CheckedContinuation<(Data, URLResponse), any Error>?
        private var failure: (any Error)?
        private var response: URLResponse?
        private var data = Data()
        init(limit: Int, followsRedirects: Bool, redirectHandler: (@Sendable (HTTPURLResponse, URLRequest) -> URLRequest?)?) {
            self.limit = limit; self.followsRedirects = followsRedirects; self.redirectHandler = redirectHandler
        }
        func start(_ request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                task.delegate = self
                let stopped = lock.withLock {
                    self.continuation = continuation
                    self.task = task
                    return failure != nil
                }
                if stopped { task.cancel() }
                task.resume()
            }
        }
        func cancel() {
            let task = lock.withLock { failure = failure ?? CancellationError(); return self.task }
            task?.cancel()
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            let allow = lock.withLock {
                self.response = response
                if response.expectedContentLength > limit { failure = TooLarge(limit: limit) }
                return failure == nil
            }
            completionHandler(allow ? .allow : .cancel)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            let stop = lock.withLock {
                guard failure == nil else { return true }
                guard chunk.count <= limit - data.count else {
                    failure = TooLarge(limit: limit); data = Data(); return true
                }
                data.append(chunk)
                return false
            }
            if stop { dataTask.cancel() }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            guard followsRedirects else { completionHandler(nil); return }
            if let redirectHandler { completionHandler(redirectHandler(response, request)); return }
            if let delegate = session.delegate as? any URLSessionTaskDelegate,
               let redirect = delegate.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:) {
                redirect(session, task, response, request, completionHandler)
            } else { completionHandler(request) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            let answer: (CheckedContinuation<(Data, URLResponse), any Error>?, Result<(Data, URLResponse), any Error>) = lock.withLock {
                defer { continuation = nil; self.task = nil; data = Data() }
                if let failure = failure ?? error { return (continuation, .failure(failure)) }
                guard let response else { return (continuation, .failure(URLError(.badServerResponse))) }
                return (continuation, .success((data, response)))
            }
            answer.0?.resume(with: answer.1)
        }
    }

    /// Native catalogs, artwork, loopback replies and QuickJS share actual HTTP slots.
    /// Node completion/cancel control messages bypass this data budget to avoid deadlock.
    private actor HTTPBudget {
        private final class Ticket: @unchecked Sendable {
            let id = UUID()
            private let lock = NSLock()
            private var stopped = false
            var cancelled: Bool { lock.withLock { stopped } }
            func cancel() { lock.withLock { stopped = true } }
        }
        private var active = 0
        private var pending: [(Ticket, CheckedContinuation<Void, any Error>)] = []
        func acquire() async throws {
            let ticket = Ticket()
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    guard !ticket.cancelled else { continuation.resume(throwing: CancellationError()); return }
                    pending.append((ticket, continuation)); drain()
                }
            } onCancel: {
                ticket.cancel()
                Task { await self.cancel(ticket.id) }
            }
        }
        private func cancel(_ id: UUID) {
            guard let index = pending.firstIndex(where: { $0.0.id == id }) else { return }
            pending.remove(at: index).1.resume(throwing: CancellationError())
        }
        func release() { active -= 1; drain() }
        private func drain() {
            while active < 32, !pending.isEmpty {
                let (ticket, continuation) = pending.removeFirst()
                if ticket.cancelled { continuation.resume(throwing: CancellationError()); continue }
                active += 1
                continuation.resume()
            }
        }
    }
}
