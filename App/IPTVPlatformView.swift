#if os(iOS)
import SwiftUI
import Perception
import TVCore

@MainActor struct IPTVPlatformView: View {
    let sourceID: String
    let platform: IPTVPlatform
    var folder: IPTVPlatformRoom? = nil

    @Environment(Store.self) private var store
    @State private var areas: [LiveArea] = []
    @State private var area: String?
    @State private var rooms: [IPTVPlatformRoom] = []
    @State private var query = ""
    @State private var generation = UUID()
    @State private var page = 1
    @State private var hasMore = false
    @State private var busy = true
    @State private var error: String?
    @State private var accountOpen = false

    private var enabled: Bool {
        IPTVLibrary.shared.records.contains { $0.id == sourceID && $0.enabled && $0.platforms.contains(platform) }
    }
    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        WithPerceptionTracking {
            roomList
                .screenTitle(folder?.title ?? platform.name)
                .liveSearchable(folder == nil && platform.searchable, text: $query, prompt: "搜索直播间")
                .onChange(of: query) { _ in restart() }
                .onChange(of: area) { _ in restart() }
                .task(id: Request(generation: generation, page: page, enabled: enabled)) {
                    if enabled { await load() }
                }
                .sheet(isPresented: $accountOpen, onDismiss: restart) {
                    NavigationStack {
                        if platform.account == "douyin" { DouyinAccountView() } else { BilibiliAccountView() }
                    }
                }
        }
    }

    private var roomList: some View {
        List {
            if enabled {
                controls
                ForEach(rooms) { room in WithPerceptionTracking { roomAction(room) } }
                status
            } else {
                Text("该直播来源已更新或停用，请返回直播页重新选择。").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var controls: some View {
        if folder == nil, areas.count > 1 {
            Picker("分区", selection: $area) {
                ForEach(areas) { item in Text(item.name).tag(Optional(item.id)) }
            }
            .pickerStyle(.menu)
        }
        if let account = platform.account, !SourceAccounts.signedIn(account) {
            Button("登录" + (account == "douyin" ? "抖音" : "哔哩哔哩")) { accountOpen = true }
        }
    }

    @ViewBuilder private var status: some View {
        if let error {
            Text(error).foregroundStyle(.secondary)
            Button("重试") { restart() }
        } else if busy {
            ProgressView().frame(maxWidth: .infinity)
        } else if rooms.isEmpty {
            Text(trimmed.isEmpty ? "暂无直播间" : "没有找到直播间").foregroundStyle(.secondary)
        } else if hasMore {
            Button("加载更多直播间") { page += 1 }
        }
    }

    @ViewBuilder private func roomAction(_ room: IPTVPlatformRoom) -> some View {
        if room.folder || room.listsChannels {
            NavigationLink {
                IPTVPlatformView(sourceID: sourceID, platform: platform, folder: room)
            } label: { row(room) }
        } else {
            let channel = room.channel(sourceID: sourceID, platform: platform)
            Button { store.playing = channel } label: { row(room) }
                .disabled(room.offline)
                .contextMenu {
                    Button(store.isFavorite(channel) ? "取消收藏" : "收藏直播间") { store.toggleFavorite(channel) }
                }
        }
    }

    private func row(_ room: IPTVPlatformRoom) -> some View {
        HStack(spacing: 12) {
            if let cover = room.cover {
                PosterImage(url: cover, headers: [:])
                    .frame(width: 84, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(room.title).lineLimit(2)
                if room.offline { Text("未开播").font(.caption).foregroundStyle(.secondary) }
                else if !room.caption.isEmpty { Text(room.caption).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private struct Request: Equatable {
        let generation: UUID
        let page: Int
        let enabled: Bool
    }

    private func restart() {
        generation = UUID()
        page = 1
        rooms = []
        error = nil
        busy = true
    }

    private func load() async {
        let active = generation, index = page, keyword = trimmed
        busy = true
        do {
            if !keyword.isEmpty { try await Task.sleep(for: .milliseconds(280)) }
            if folder == nil, keyword.isEmpty, area == nil {
                let choices = try await platform.areas(sourceID: sourceID)
                try Task.checkCancellation()
                guard generation == active else { return }
                areas = choices
                area = choices.first?.id ?? ""
                return
            }
            let result: (rooms: [IPTVPlatformRoom], more: Bool)
            if let folder, folder.listsChannels {
                result = (try await platform.channels(sourceID: sourceID, group: folder), false)
            } else {
                result = try await platform.list(sourceID: sourceID, area: folder?.id ?? area ?? "", query: keyword,
                                                 page: index, filters: folder?.folderFilters ?? [:])
            }
            try Task.checkCancellation()
            guard generation == active, page == index else { return }
            var seen = Set(rooms.map(\.id))
            let new = result.rooms.filter { seen.insert($0.id).inserted }
            rooms.append(contentsOf: new)
            hasMore = result.more && !new.isEmpty
            error = nil
            busy = false
        } catch {
            guard !Task.isCancelled, generation == active, page == index else { return }
            self.error = error.localizedDescription
            busy = false
        }
    }
}
#endif
