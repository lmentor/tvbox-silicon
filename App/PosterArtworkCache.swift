import Foundation
import ImageIO
import TVCore
#if canImport(UIKit)
import UIKit
#endif

final class PosterBitmap: @unchecked Sendable {
    let image: CGImage
    let resource: PosterResource
    let revision: UInt64
    let maxPixels: Int
    init(_ image: CGImage, resource: PosterResource, revision: UInt64, maxPixels: Int = 720) {
        self.image = image; self.resource = resource; self.revision = revision; self.maxPixels = maxPixels
    }
}

private struct PosterArtworkRequest: Hashable, Sendable {
    let resource: PosterResource
    let maxPixels: Int
    init(_ resource: PosterResource, maxPixels: Int) {
        self.resource = resource; self.maxPixels = max(1, maxPixels)
    }
    var memoryKey: NSString { (resource.cacheKey + "|pixels=\(maxPixels)") as NSString }
}

/// Decoded covers have deterministic byte/count bounds and access-order eviction.
/// A lazy cell can paint a warm image before its asynchronous task starts.
private final class PosterMemory: @unchecked Sendable {
    static let shared = PosterMemory()
    private let lock = NSLock()
    private struct Bucket {
        struct Entry {
            let bitmap: PosterBitmap
            let cost: Int
            var access: UInt64
        }
        let countLimit: Int
        let costLimit: Int
        var entries: [NSString: Entry] = [:]
        var cost = 0
        var access: UInt64 = 0

        mutating func image(for key: NSString) -> PosterBitmap? {
            guard var entry = entries[key] else { return nil }
            access &+= 1; entry.access = access; entries[key] = entry
            return entry.bitmap
        }
        mutating func store(_ bitmap: PosterBitmap, for key: NSString) {
            if let previous = entries.removeValue(forKey: key) { cost -= previous.cost }
            // Inline covers retain their encoded URL as well as decoded pixels.
            let bytes = bitmap.image.bytesPerRow * bitmap.image.height + bitmap.resource.url.absoluteString.utf8.count
                + bitmap.resource.headers.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
            guard bytes <= costLimit else { return }
            while entries.count >= countLimit || cost > costLimit - bytes {
                guard let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key,
                      let removed = entries.removeValue(forKey: oldest) else { break }
                cost -= removed.cost
            }
            access &+= 1
            entries[key] = Entry(bitmap: bitmap, cost: bytes, access: access)
            cost += bytes
        }
        mutating func removeAll() { entries.removeAll(); cost = 0 }
    }
    private var cache = Bucket(countLimit: 96, costLimit: 48 * 1024 * 1024)
    // Large backdrops/logos must not evict all of a visible catalog's small covers.
    private var artwork = Bucket(countLimit: 24, costLimit: 48 * 1024 * 1024)
    private var revision = MediaCache.shared.revision
    #if canImport(UIKit)
    private var memoryWarning: NSObjectProtocol?
    #endif
    private init() {
        #if canImport(UIKit)
        memoryWarning = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                               object: nil, queue: nil) { [weak self] _ in
            self?.lock.withLock { self?.cache.removeAll(); self?.artwork.removeAll() }
        }
        #endif
    }

    func image(for request: PosterArtworkRequest) -> PosterBitmap? {
        return lock.withLock {
            let current = MediaCache.shared.revision
            if revision != current { cache.removeAll(); artwork.removeAll(); revision = current }
            return request.maxPixels <= 720 ? cache.image(for: request.memoryKey) : artwork.image(for: request.memoryKey)
        }
    }
    func store(_ bitmap: PosterBitmap) {
        lock.withLock {
            let current = MediaCache.shared.revision
            if revision != current { cache.removeAll(); artwork.removeAll(); revision = current }
            guard bitmap.revision == current else { return }
            let request = PosterArtworkRequest(bitmap.resource, maxPixels: bitmap.maxPixels)
            if request.maxPixels <= 720 { cache.store(bitmap, for: request.memoryKey) }
            else { artwork.store(bitmap, for: request.memoryKey) }
        }
    }
}

actor PosterLoader {
    static let shared = PosterLoader()
    private struct Pending {
        let id: UUID
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<PosterBitmap, Error>]
    }
    private var pending: [PosterArtworkRequest: Pending] = [:]
    private var queued: [(resource: PosterArtworkRequest, id: UUID)] = []
    private var running = 0
    private let concurrentLimit = 6
    private var revision = MediaCache.shared.revision

    nonisolated static func cached(_ resource: PosterResource, maxPixels: Int = 720) -> PosterBitmap? {
        PosterMemory.shared.image(for: PosterArtworkRequest(resource, maxPixels: maxPixels))
    }

    func load(_ resource: PosterResource, maxPixels: Int = 720) async throws -> PosterBitmap {
        try Task.checkCancellation()
        let current = MediaCache.shared.revision
        if revision != current {
            for request in pending.values {
                request.task?.cancel()
                for waiter in request.waiters.values { waiter.resume(throwing: CancellationError()) }
            }
            pending.removeAll(); queued.removeAll(); revision = current
        }
        if let image = Self.cached(resource, maxPixels: maxPixels) { return image }
        let resource = PosterArtworkRequest(resource, maxPixels: maxPixels)
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            let image: PosterBitmap = try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if var request = pending[resource] {
                    request.waiters[waiter] = continuation
                    pending[resource] = request
                } else {
                    let id = UUID()
                    pending[resource] = Pending(id: id, task: nil, waiters: [waiter: continuation])
                    queued.append((resource, id))
                    startQueued()
                }
            }
            try Task.checkCancellation()
            guard image.revision == MediaCache.shared.revision else { throw CancellationError() }
            return image
        } onCancel: {
            Task { await self.cancel(resource, waiter: waiter) }
        }
    }

    private func cancel(_ resource: PosterArtworkRequest, waiter: UUID) {
        guard var request = pending[resource], let continuation = request.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        if request.waiters.isEmpty {
            pending[resource] = nil
            request.task?.cancel()
            queued.removeAll { $0.id == request.id }
        } else {
            pending[resource] = request
        }
    }

    private func startQueued() {
        while running < concurrentLimit, !queued.isEmpty {
            let next = queued.removeFirst()
            guard var request = pending[next.resource], request.id == next.id else { continue }
            let current = revision
            running += 1
            // Neither flash I/O nor ImageIO may occupy the scheduling actor:
            // visible cells can cancel or join requests while a decode is busy.
            request.task = Task.detached(priority: .utility) {
                let result: Result<PosterBitmap, Error>
                do { result = .success(try await Self.read(next.resource, revision: current)) }
                catch { result = .failure(error) }
                await self.finish(next.resource, id: next.id, result: result)
            }
            pending[next.resource] = request
        }
    }

    private func finish(_ resource: PosterArtworkRequest, id: UUID, result: Result<PosterBitmap, Error>) {
        running -= 1
        defer { startQueued() }
        // Completion of a cancelled request never owns its replacement.
        guard let request = pending[resource], request.id == id else { return }
        pending[resource] = nil
        for waiter in request.waiters.values { waiter.resume(with: result) }
    }

    private nonisolated static func read(_ request: PosterArtworkRequest, revision: UInt64) async throws -> PosterBitmap {
        try Task.checkCancellation()
        let resource = request.resource
        let disk = MediaCache.shared
        let ticket = disk.ticket()
        let scope = PosterResource.artworkScope(resource.url)
        let cached = disk.data(for: resource.cacheKey, kind: .artwork, scope: scope)
        let data: Data
        if let cached { data = cached }
        else if resource.url.scheme?.lowercased() == "data" {
            guard let embedded = PosterResource.inlineImageData(for: resource.url) else { throw URLError(.cannotDecodeContentData) }
            data = embedded
        } else if let saved = try? Data(contentsOf: MusicDownloadLibrary.artworkFile(for: resource.url)) { data = saved }
        else { data = try await TMDBServiceSettings.artworkData(for: resource.url, headers: resource.headers) }
        try Task.checkCancellation()
        guard revision == disk.revision else { throw CancellationError() }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: request.maxPixels,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw NSError(domain: "PosterLoader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid poster image"])
        }
        try Task.checkCancellation()
        guard revision == disk.revision else { throw CancellationError() }
        if cached == nil {
            disk.store(data, for: resource.cacheKey, kind: .artwork, scope: scope, ttl: 30 * 86400, ticket: ticket)
        }
        try Task.checkCancellation()
        let bitmap = PosterBitmap(image, resource: resource, revision: revision, maxPixels: request.maxPixels)
        PosterMemory.shared.store(bitmap)
        return bitmap
    }
}
