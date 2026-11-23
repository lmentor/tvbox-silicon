#if os(iOS)
import SwiftUI
import UIKit

/// A compact reading beside the title, following the player's control visibility.
struct PlayerBatteryIndicator: View {
    @State private var level: Float = -1
    @State private var state: UIDevice.BatteryState = .unknown
    @State private var monitoring = false

    private var percentage: Int? {
        guard level.isFinite, level >= 0 else { return nil }
        return Int((min(1, level) * 100).rounded())
    }
    private var tint: Color {
        if state == .charging || state == .full { return .green }
        if let percentage, percentage <= 20 { return .red }
        return .white
    }

    var body: some View {
        Text(percentage.map { "\($0)%" } ?? "--%")
        .font(.caption2.monospacedDigit())
        .foregroundStyle(tint)
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("电量")
        .accessibilityValue(percentage.map { "\($0)%" + (state == .charging ? "，正在充电" : "") } ?? "未知")
        .accessibilityIdentifier("player.battery")
        .onAppear {
            if !monitoring { PlayerBatteryMonitoring.acquire(); monitoring = true }
            refresh()
        }
        .onDisappear {
            if monitoring { PlayerBatteryMonitoring.release(); monitoring = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        level = UIDevice.current.batteryLevel
        state = UIDevice.current.batteryState
    }
}

/// Inline and full-screen players may overlap during presentation. Keep the
/// device monitor active until the last reading leaves, then restore its owner.
@MainActor private enum PlayerBatteryMonitoring {
    private static var readers = 0
    private static var wasEnabled = false

    static func acquire() {
        if readers == 0 {
            wasEnabled = UIDevice.current.isBatteryMonitoringEnabled
            UIDevice.current.isBatteryMonitoringEnabled = true
        }
        readers += 1
    }

    static func release() {
        guard readers > 0 else { return }
        readers -= 1
        if readers == 0 { UIDevice.current.isBatteryMonitoringEnabled = wasEnabled }
    }
}
#endif
