#if os(iOS)
import SwiftUI
import Perception

struct SleepTimerPanel: View {
    var item: SleepTimerItem
    var offersEnd = true
    var close: () -> Void
    private var timer: SleepTimer { .shared }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 14) {
                if timer.isOn {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        WithPerceptionTracking {
                            VStack(alignment: .leading, spacing: 4) {
                                if let remaining = timer.remaining(at: context.date) {
                                    Text(remaining).font(.title2.weight(.semibold)).monospacedDigit()
                                }
                                Text(timer.status(item: item)).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text("到点后音量会逐渐减小，播放暂停并保留当前位置。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(SleepTimer.durations, id: \.self) { minutes in
                        choice("\(minutes) 分钟", selected: timer.minutes == minutes && timer.isOn) {
                            timer.start(minutes: minutes)
                        }
                    }
                }
                if offersEnd {
                    choice(item.title, selected: timer.endsWithItem) { timer.stopAtEndOfItem() }
                }
                choice("关闭定时", selected: !timer.isOn) { timer.cancel() }
            }
            .accessibilityIdentifier("sleepTimer.choices")
        }
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { action(); close() } label: {
            HStack(spacing: 8) {
                Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 12).frame(minHeight: 44)
            .background(.primary.opacity(selected ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
#endif
