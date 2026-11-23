import Foundation

/// One bounded queue shared by all runtimes. Source order is retained while a busy runtime
/// may defer its next source so another runtime can use the remaining capacity.
/// The task group retains a slot until the operation actually returns, including cancellation.
enum SearchScheduler {
    enum Lane: CaseIterable, Sendable { case native, python, quickJS, node, jar }
    static let maximumConcurrent = 30
    static let runtimeLimits: [Lane: Int] = [.native: 30, .python: 4, .quickJS: 4, .node: 8, .jar: 5]
    private static let admission = Admission()

    /// Cancellation of an old query must not let a replacement query double its native
    /// workers while those old calls are still unwinding. These permits span search runs.
    private actor Admission {
        private final class Ticket: @unchecked Sendable {
            let id = UUID()
            private let lock = NSLock()
            private var stopped = false
            var cancelled: Bool { lock.withLock { stopped } }
            func cancel() { lock.withLock { stopped = true } }
        }
        private struct Pending {
            let ticket: Ticket
            let lanes: [Lane]
            let continuation: CheckedContinuation<Lane?, Never>
        }
        private var running: [Lane: Int] = [:]
        private var total = 0
        private var pending: [Pending] = []
        private var nextStart = ContinuousClock.now
        private var wake: Task<Void, Never>?

        func acquire(_ lane: Lane) async -> Bool { await acquire([lane]) != nil }
        func acquire(_ lanes: [Lane]) async -> Lane? {
            let ticket = Ticket()
            return await withTaskCancellationHandler {
                if Task.isCancelled { ticket.cancel() }
                return await withCheckedContinuation { continuation in
                    guard !ticket.cancelled else { continuation.resume(returning: nil); return }
                    pending.append(Pending(ticket: ticket, lanes: lanes, continuation: continuation))
                    drain()
                }
            } onCancel: {
                ticket.cancel()
                Task { await self.cancel(ticket.id) }
            }
        }
        private func cancel(_ id: UUID) {
            guard let index = pending.firstIndex(where: { $0.ticket.id == id }) else { return }
            pending.remove(at: index).continuation.resume(returning: nil)
            drain()
        }
        func release(_ lane: Lane) {
            running[lane, default: 0] -= 1
            total -= 1
            drain()
        }
        private func drain() {
            pending.removeAll { candidate in
                guard candidate.ticket.cancelled else { return false }
                candidate.continuation.resume(returning: nil)
                return true
            }
            func runnableLane(_ candidate: Pending) -> Lane? {
                candidate.lanes.first { running[$0, default: 0] < runtimeLimits[$0, default: 1] }
            }
            guard total < maximumConcurrent,
                  let index = pending.firstIndex(where: { runnableLane($0) != nil }),
                  let lane = runnableLane(pending[index]) else { return }
            guard ContinuousClock.now >= nextStart else { scheduleWake(); return }
            let candidate = pending.remove(at: index)
            running[lane, default: 0] += 1
            total += 1
            // One replacement per completion, also paced when many sources finish together.
            // This bounds connection/parser bursts across distinct search models and retries.
            nextStart = .now + .milliseconds(Int.random(in: 6...10))
            candidate.continuation.resume(returning: lane)
            if !pending.isEmpty, total < maximumConcurrent { scheduleWake() }
        }
        private func scheduleWake() {
            guard wake == nil else { return }
            let deadline = nextStart
            wake = Task {
                try? await Task.sleep(until: deadline, clock: .continuous)
                wake = nil
                drain()
            }
        }
    }

    static func withPermit<Value: Sendable>(lane: Lane,
                         operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        guard await admission.acquire(lane) else { throw CancellationError() }
        do {
            try Task.checkCancellation()
            let value = try await operation()
            try Task.checkCancellation()
            await admission.release(lane)
            return value
        } catch {
            await admission.release(lane)
            throw error
        }
    }

    static func request(site: Site, lane: Lane,
                        operation: @escaping @Sendable () async -> SearchSourceResult) async -> SearchSourceResult {
        do { return try await withPermit(lane: lane, operation: operation) }
        catch {
            return SearchSourceResult(site: site, page: nil, error: CancellationError().localizedDescription)
        }
    }

    static func search(sites: [Site], maximumConcurrent: Int, limits: [Lane: Int],
                       lane: @Sendable (Site) -> Lane,
                       operation: @escaping @Sendable (Site) async -> SearchSourceResult,
                       onResult: @escaping @Sendable (SearchSourceResult) async -> Void) async {
        guard !sites.isEmpty, !Task.isCancelled else { return }
        let maximum = min(Self.maximumConcurrent, max(1, maximumConcurrent))
        await withTaskGroup(of: (Lane, SearchSourceResult).self) { group in
            var queued = sites.map { (lane($0), $0) }
            var running: [Lane: Int] = [:]
            var active = 0
            func fill(_ count: Int) async {
                var added = 0
                while added < count, active < maximum, !Task.isCancelled {
                    var candidates: [Lane] = []
                    for (sourceLane, _) in queued where running[sourceLane, default: 0] < max(1, limits[sourceLane, default: 1]) {
                        if !candidates.contains(sourceLane) { candidates.append(sourceLane) }
                    }
                    guard !candidates.isEmpty else { break }
                    // Enqueue in the caller's order before creating a child task. Racing
                    // child acquire() calls can otherwise reorder the user's source list.
                    guard let sourceLane = await admission.acquire(candidates),
                          let index = queued.firstIndex(where: { $0.0 == sourceLane }) else { break }
                    let (_, site) = queued.remove(at: index)
                    running[sourceLane, default: 0] += 1; active += 1
                    added += 1
                    group.addTask {
                        let result: SearchSourceResult
                        if Task.isCancelled { result = SearchSourceResult(site: site, page: nil, error: CancellationError().localizedDescription) }
                        else { result = await operation(site) }
                        await admission.release(sourceLane)
                        if !Task.isCancelled { await onResult(result) }
                        return (sourceLane, result)
                    }
                }
            }
            await fill(maximum)
            for await (sourceLane, _) in group {
                running[sourceLane, default: 0] -= 1; active -= 1
                guard !Task.isCancelled else { group.cancelAll(); break }
                await fill(1)
            }
        }
    }
}
