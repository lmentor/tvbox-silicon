import Foundation
import TVCore

/// One actual full-screen cover, including ordinary video and history preparation.
/// A closed instance can never acquire new work through a late SwiftUI callback.
@MainActor final class PlayerPresentationLifetime {
    let id: UUID
    private(set) var closing = false
    private(set) var finished = false
    var canPresent: Bool { !closing && !finished }

    init(id: UUID = UUID()) { self.id = id }
    func close() { if !finished { closing = true } }
    func finish() { closing = true; finished = true }
}

/// Owns the player presentation while a saved episode gets a fresh source URL.
/// No playable URL is manufactured from the history entry.
struct HistoryPlaybackPreparation: Identifiable {
    let id: UUID
    let entry: PlaybackHistoryEntry
    let mode: PlaybackResumeMode
    let startedAt: Date
    var presentationID: UUID?
    var failure: String?
    /// A source can reveal reading/listening media only after it resolves. Its
    /// existing presentation opens once the preparation cover has dismissed.
    var handoff: Channel?

    var isPresented: Bool { handoff == nil }
}
