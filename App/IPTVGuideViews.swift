#if os(iOS)
import SwiftUI
import TVCore

private struct IPTVGuideQuery: Equatable {
    let context: IPTVGuideContext
    let station: IPTVStation
    var day: Date?
    var retry = 0
}

private struct IPTVGuideContent<Content: View>: View {
    let query: IPTVGuideQuery
    var adjacent = false
    let content: (IPTVGuideSchedule?, String?) -> Content
    @State private var schedule: IPTVGuideSchedule?
    @State private var failure: String?
    @State private var loadedQuery: IPTVGuideQuery?

    var body: some View {
        // A changed date renders before its replacement task begins. Keep the old
        // response from spending the new date's pending programme reveal.
        content(loadedQuery == query ? schedule : nil, loadedQuery == query ? failure : nil)
            .task(id: query) {
                schedule = nil
                failure = nil
                loadedQuery = query
                var force = query.retry > 0
                while !Task.isCancelled {
                    let day = query.day ?? Date()
                    let calendar = query.context.calendar
                    var retryAt = Date().addingTimeInterval(60)
                    do {
                        let result = try await IPTVGuideStore.shared.schedule(query.context, station: query.station,
                                                                             day: day, force: force, adjacent: adjacent)
                        try Task.checkCancellation()
                        schedule = result
                        failure = nil
                        // A continuously visible row with max-age=0 can revalidate at the next
                        // minute. Newly opened views still consult the guide's HTTP policy.
                        retryAt = max(result.refreshAfter, Date().addingTimeInterval(60))
                    } catch {
                        guard !Task.isCancelled else { return }
                        failure = (error as? LocalizedError)?.errorDescription ?? "节目单暂时无法加载"
                    }
                    force = false
                    if query.day == nil, let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) {
                        retryAt = min(retryAt, midnight)
                    }
                    let seconds = min(86_400, max(1, retryAt.timeIntervalSinceNow))
                    do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
                }
            }
    }
}

private struct IPTVGuideBoundaries: TimelineSchedule {
    var dates: [Date]

    init(_ shows: [IPTVProgramme], catchupDays: Int? = nil) {
        dates = shows.flatMap { show in
            var boundaries = [show.start, show.end]
            if let days = catchupDays, days > 0 {
                boundaries.append(show.start.addingTimeInterval(Double(days) * 86_400 + 1))
            }
            return boundaries
        }
    }

    func entries(from start: Date, mode: TimelineScheduleMode) -> [Date] {
        [start] + Set(dates.filter { $0 > start }).sorted()
    }
}

struct IPTVGuideNow: View {
    let context: IPTVGuideContext
    let station: IPTVStation

    var body: some View {
        IPTVGuideContent(query: IPTVGuideQuery(context: context, station: station)) { result, _ in
            // The task needs a view even before the first visible text is available.
            TimelineView(IPTVGuideBoundaries(result?.shows ?? [])) { tick in
                if let show = result?.shows.now(at: tick.date) {
                    Text("正在播 · \(show.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else { Color.clear.frame(width: 0, height: 0).accessibilityHidden(true) }
            }
        }
    }
}

struct IPTVGuidePanel: View {
    let context: IPTVGuideContext
    let station: IPTVStation
    let lineIndex: Int
    let programme: IPTVProgramme?
    let onCatchup: (IPTVProgramme, IPTVLine) -> Void
    @State private var selectedDay: Date?
    @State private var retry = 0

    init(context: IPTVGuideContext, station: IPTVStation, lineIndex: Int, programme: IPTVProgramme? = nil,
         onCatchup: @escaping (IPTVProgramme, IPTVLine) -> Void) {
        self.context = context
        self.station = station
        self.lineIndex = lineIndex
        self.programme = programme
        self.onCatchup = onCatchup
        _selectedDay = State(initialValue: IPTVGuidePanelSnapshot.initialDay(programme: programme, calendar: context.calendar))
    }

    private var line: IPTVLine? {
        station.lines.indices.contains(lineIndex) ? station.lines[lineIndex] : station.lines.first
    }

    var body: some View {
        IPTVGuideContent(query: IPTVGuideQuery(context: context, station: station, day: selectedDay, retry: retry),
                         adjacent: true) { result, failure in
            TimelineView(IPTVGuideBoundaries(result?.shows ?? [], catchupDays: line?.catchup?.days)) { tick in
                let day = selectedDay ?? tick.date
                let snapshot = IPTVGuidePanelSnapshot(shows: result?.shows ?? [], day: day, calendar: context.calendar,
                                                     programme: programme, now: tick.date)
                IPTVPanelScrollView(target: snapshot.target) {
                    VStack(alignment: .leading, spacing: 12) {
                        datePicker
                        if context.zone.secondsFromGMT(for: day) != TimeZone.current.secondsFromGMT(for: day) {
                            Text("节目日期按 \(context.zone.identifier)，起止时间按设备时区显示。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let result {
                            if result.stale {
                                Text("显示上次更新的节目单 · \(result.updated.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            programmeList(snapshot, shows: result.shows, day: day, now: tick.date)
                        } else if let failure {
                            Text(failure).font(.callout).foregroundStyle(.secondary)
                            Button("重试节目单") { retry += 1 }.buttonStyle(.bordered)
                        } else {
                            ProgressView("正在加载节目单").font(.callout)
                        }
                    }
                }
                // Manual date selection owns a new viewport. Timer refreshes within
                // that day preserve the completed reveal and the user's scroll.
                .id(selectedDay)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var datePicker: some View {
        let day = Binding<Date>(get: { selectedDay ?? Date() }, set: {
            selectedDay = context.calendar.isDateInToday($0) ? nil : context.calendar.startOfDay(for: $0)
        })
        return HStack {
            stepButton(-1, date: day)
            DatePicker("节目日期", selection: day, displayedComponents: .date)
                .labelsHidden().environment(\.timeZone, context.zone)
                .frame(maxWidth: .infinity)
            stepButton(1, date: day)
        }
    }

    private func stepButton(_ offset: Int, date: Binding<Date>) -> some View {
        Button {
            if let next = context.calendar.date(byAdding: .day, value: offset, to: date.wrappedValue) {
                date.wrappedValue = next
            }
        } label: {
            Image(systemName: offset < 0 ? "chevron.left" : "chevron.right")
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain).accessibilityLabel(offset < 0 ? "前一天" : "后一天")
    }

    @ViewBuilder private func programmeList(_ snapshot: IPTVGuidePanelSnapshot, shows: [IPTVProgramme], day: Date, now: Date) -> some View {
        let calendar = context.calendar
        VStack(alignment: .leading, spacing: 10) {
            if calendar.isDate(day, inSameDayAs: now) {
                if let current = shows.now(at: now) { Text("正在播 · \(current.title)").font(.headline) }
                if let next = shows.next(after: now) {
                    Text("接下来 · \(clock(next.start, relativeTo: now)) \(next.title)").font(.subheadline)
                }
            }
            if let line {
                if line.isRecording {
                    Text("此线路为录像，可在播放器中拖动进度。").font(.caption).foregroundStyle(.secondary)
                } else if line.catchup == nil || line.catchup?.days.map({ $0 <= 0 }) == true {
                    Text("此线路未提供可用的回看地址，节目单可正常查看。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !IPTVGuideCatchup.supports(line, zone: context.zone) {
                    Text("此来源的回看格式暂不支持").font(.caption).foregroundStyle(.secondary)
                } else if line.catchup?.days == nil {
                    Text("此来源未标明回看保留天数，能否播放以来源实际提供为准。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if snapshot.shows.isEmpty { Text("暂无节目单").font(.callout).foregroundStyle(.secondary) }
            ForEach(snapshot.shows, id: \.self) { show in
                let playing = snapshot.playing == show
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(show.title).font(.subheadline)
                        Text("\(clock(show.start, relativeTo: day)) – \(clock(show.end, relativeTo: show.start))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if playing {
                            Text(programme == nil ? "正在播" : "正在回看").font(.caption).foregroundStyle(Color.accentColor)
                        }
                    }
                    Spacer(minLength: 2)
                    if let line, IPTVGuideCatchup.line(line, for: show, now: now, zone: context.zone) != nil {
                        Button("回看") {
                            if let checked = IPTVGuideCatchup.line(line, for: show, now: Date(), zone: context.zone) { onCatchup(show, checked) }
                        }.buttonStyle(.bordered).accessibilityLabel("回看\(show.title)")
                    }
                }
                .padding(10)
                .background(playing ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityAddTraits(playing ? .isSelected : [])
                .id(show)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clock(_ time: Date, relativeTo day: Date) -> String {
        if Calendar.current.isDate(time, inSameDayAs: day) { return time.formatted(date: .omitted, time: .shortened) }
        return time.formatted(.dateTime.month().day().hour().minute())
    }
}
#endif
