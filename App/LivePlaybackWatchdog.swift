import Foundation

/// A socket and an old pixel buffer are not proof that a live channel is still
/// playing. Track the presented media clock even after its first picture.
struct LivePlaybackWatchdog {
    private var waitingSince: TimeInterval?
    private var lastOutputTime: Double?
    private var hasOutput = false
    private var advancingSince: TimeInterval?
    private var lastAdvancedAt: TimeInterval?
    private(set) var hadSustainedOutput = false

    mutating func update(now: TimeInterval, playing: Bool, ready: Bool, hasPicture: Bool,
                         selectedVideo: Bool, outputTime: Double) -> Bool {
        guard playing else {
            waitingSince = nil
            lastOutputTime = nil
            advancingSince = nil
            lastAdvancedAt = nil
            return false
        }
        if waitingSince == nil { waitingSince = now }
        let outputAvailable = ready && (!selectedVideo || hasPicture) && outputTime.isFinite
        if outputAvailable {
            if let previous = lastOutputTime {
                // A timestamp discontinuity still proves that a new picture
                // arrived. Requiring increasing PTS would reject valid TS wraps.
                if abs(outputTime - previous) > 0.001 {
                    hasOutput = true
                    waitingSince = now
                    if advancingSince == nil || lastAdvancedAt.map({ now - $0 > 2 }) == true { advancingSince = now }
                    lastAdvancedAt = now
                    if let advancingSince, now - advancingSince >= 8 { hadSustainedOutput = true }
                }
            } else if selectedVideo {
                hasOutput = true
                waitingSince = now
            }
            lastOutputTime = outputTime
        }
        guard let waitingSince else { return false }
        return now - waitingSince >= (hasOutput ? 12 : 25)
    }
}
