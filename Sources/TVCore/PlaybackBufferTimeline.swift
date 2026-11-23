import Foundation

/// One scrubber representation for native read-ahead and actual disk coverage.
/// The native queue describes only its current island after a seek.
public enum PlaybackBufferTimeline {
    public static func ranges(position: Double, buffered: Double, duration: Double,
                              cached: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        guard duration.isFinite, duration > 0 else { return [] }
        var ranges = cached
        if position.isFinite, buffered.isFinite, buffered > position {
            ranges.append(position...buffered)
        }
        ranges = ranges.compactMap { range in
            guard range.lowerBound.isFinite, range.upperBound.isFinite else { return nil }
            let start = max(0, range.lowerBound), end = min(duration, range.upperBound)
            return end > start ? start...end : nil
        }.sorted { $0.lowerBound < $1.lowerBound }
        var result: [ClosedRange<Double>] = []
        for range in ranges {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else { result.append(range) }
        }
        return result
    }
}
