import SwiftUI
import TVCore

struct LocalCacheSettingsView: View {
    @AppStorage("local.videoCache.enabled") private var enabled = true
    @AppStorage("local.videoCache.sizeGB") private var size = 1
    @AppStorage("local.playback.prefetchNext") private var prefetch = true
    @State private var summary: MobileMediaServices.VideoCacheSummary?
    @State private var cacheStatus: String?
    @State private var clearing = false
    @State private var retrying = false
    var body: some View {
        SettingsPage(title: "视频缓存", symbol: "internaldrive") {
            SettingsGroup(title: "视频缓存", footer: "缓存容量由当前播放与下一集预加载共用，切换媒体和退出后释放。用户下载单独保留。") {
                Toggle("开启视频缓存", isOn: $enabled)
                Picker("缓存容量", selection: $size) { ForEach(1...4, id: \.self) { Text("\($0) GB").tag($0) } }.disabled(!enabled)
                Toggle("预加载下一集", isOn: $prefetch)
            }
            SettingsGroup(title: "缓存使用情况") {
                SettingsRow(symbol: "internaldrive", tint: Brand.cyan, title: summary?.usageText ?? "缓存用量暂不可用")
                SettingsRow(symbol: "arrow.triangle.2.circlepath", tint: .blue, title: "已复用 \(ByteCountFormatter.string(fromByteCount: Int64(summary?.hits ?? 0), countStyle: .binary))")
                if let status = enabled ? cacheStatus ?? summary?.statusText : "视频缓存已关闭" {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
                if enabled && (summary?.failure != nil || cacheStatus != nil) {
                    SettingsActionRow(title: retrying ? "重试中…" : "重试视频缓存") {
                        retrying = true
                        Task { await configureCache(); await refreshUsage(); retrying = false }
                    }.disabled(retrying || clearing)
                }
                SettingsActionRow(title: clearing ? "清理中…" : "清理视频缓存", destructive: true) {
                    clearing = true
                    Task {
                        do { try await MobileMediaServices.clearVideoCache(); await refreshUsage() }
                        catch { cacheStatus = "缓存服务暂不可用，下次播放会按当前设置重试。" }
                        clearing = false
                    }
                }.disabled(clearing)
            }
            SettingsGroup {
                SettingsLinkRow(symbol: "photo.stack", title: "图片、剧集和弹幕缓存") { CacheSettingsView() }
                SettingsLinkRow(symbol: "arrow.down.circle", title: "已下载视频") { DownloadsView() }
            }
        }
        .task(id: "\(enabled):\(size)") {
            await configureCache()
            while !Task.isCancelled {
                await refreshUsage()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
    }
    @MainActor private func configureCache() async {
        do {
            try await MobileMediaServices.configureVideoCache(enabled: enabled, sizeGB: size)
            guard !Task.isCancelled else { return }
            cacheStatus = nil
        } catch {
            if !Task.isCancelled { cacheStatus = "缓存服务暂不可用，可重试。" }
        }
    }
    @MainActor private func refreshUsage() async {
        do {
            let value = try await MobileMediaServices.videoCacheSummary()
            guard !Task.isCancelled else { return }
            summary = value; cacheStatus = nil
        } catch {
            guard !Task.isCancelled else { return }
            summary = nil; cacheStatus = "缓存用量暂不可用，可重试。"
        }
    }
}

struct LocalAdSettingsView: View {
    @AppStorage("local.hlsAdClean") private var enabled = true
    var body: some View {
        SettingsPage(title: "去广告", symbol: "shield.lefthalf.filled") {
            SettingsGroup(footer: "对可识别的 M3U8 广告片段进行清理。分离音视频的流保留同步；遇到异常可关闭后重试。") {
                Toggle("M3U8 去广告", isOn: $enabled)
            }
        }
    }
}

#if os(iOS)
struct LocalPlayerSettingsView: View {
    @AppStorage(PlaybackInfo.key) private var showsPlaybackInfo = false
    var body: some View {
        SettingsPage(title: "播放器", symbol: "play.rectangle") {
            SettingsGroup(title: "播放信息") {
                Toggle("显示视频技术信息", isOn: $showsPlaybackInfo)
            }
        }
    }
}
#endif
