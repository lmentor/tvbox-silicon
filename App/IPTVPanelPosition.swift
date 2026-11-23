import Foundation
import TVCore

/// Each panel opening (or deliberately selected guide date) owns one reveal.
/// Missing asynchronous data keeps it pending; user scrolling gives it up.
struct IPTVPanelPosition {
    private(set) var isPending = true

    mutating func cancel() { isPending = false }

    mutating func take<T>(_ target: T?) -> T? {
        guard isPending, let target else { return nil }
        isPending = false
        return target
    }

    static func stationID(in stations: [IPTVStation], currentID: String) -> String? {
        stations.first { $0.id == currentID }?.id
    }
}

struct IPTVGuidePanelSnapshot {
    let shows: [IPTVProgramme]
    let playing: IPTVProgramme?
    let target: IPTVProgramme?

    static func initialDay(programme: IPTVProgramme?, calendar: Calendar) -> Date? {
        programme.map { calendar.startOfDay(for: $0.start) }
    }

    init(shows: [IPTVProgramme], day: Date, calendar: Calendar, programme: IPTVProgramme?, now: Date) {
        let interval = calendar.dateInterval(of: .day, for: day)
        self.shows = shows.filter { show in
            interval.map { show.end > $0.start && show.start < $0.end } ?? false
        }
        if let programme {
            // A provider may correct the title while the selected replay is open.
            playing = self.shows.first { $0 == programme }
                ?? self.shows.first { $0.start == programme.start && $0.end == programme.end }
        } else {
            playing = self.shows.now(at: now)
        }
        if let playing { target = playing }
        else {
            let reference = programme?.start ?? now
            target = calendar.isDate(day, inSameDayAs: reference)
                ? self.shows.next(after: reference) ?? self.shows.last
                : self.shows.first
        }
    }
}
