import Foundation

/// One app-wide deadline or end-of-item request. Expiry is consumed once, even
/// when a background suspension delays delivery past the selected deadline.
public struct PlaybackSleepSchedule: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case off
        case deadline(Date)
        case endOfItem
    }

    public private(set) var mode: Mode = .off
    public private(set) var minutes: Int?
    public private(set) var revision = UUID()
    public var isOn: Bool { mode != .off }
    public var endsWithItem: Bool { mode == .endOfItem }

    public init() {}

    @discardableResult public mutating func start(minutes: Int, now: Date = Date()) -> Bool {
        guard (1...1440).contains(minutes) else { return false }
        mode = .deadline(now.addingTimeInterval(Double(minutes) * 60))
        self.minutes = minutes
        revision = UUID()
        return true
    }

    public mutating func stopAtEndOfItem() {
        mode = .endOfItem; minutes = nil; revision = UUID()
    }

    public mutating func cancel() {
        mode = .off; minutes = nil; revision = UUID()
    }

    public mutating func expire(at now: Date = Date()) -> Bool {
        guard case .deadline(let deadline) = mode, now >= deadline else { return false }
        cancel()
        return true
    }

    public mutating func itemEnded() -> Bool {
        guard endsWithItem else { return false }
        cancel()
        return true
    }

    public func remaining(at now: Date = Date()) -> Int? {
        guard case .deadline(let deadline) = mode else { return nil }
        return max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
    }
}
