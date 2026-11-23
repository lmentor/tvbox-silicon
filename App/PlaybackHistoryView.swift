import SwiftUI
import Perception
import TVCore

enum WatchingHistoryItem: Identifiable {
    case video(PlaybackHistoryEntry)
    case manga(MangaLibrary.Progress)
    var id: String {
        switch self { case .video(let entry): "video:" + entry.id; case .manga(let progress): "manga:" + progress.id }
    }
    var updated: Date {
        switch self { case .video(let entry): entry.updatedAt; case .manga(let progress): progress.updated }
    }
}

/// Watching combines video and manga progress without changing their storage or identities.
struct PlaybackHistoryView: View {
    @Environment(Store.self) private var store
    @Environment(\.isEnabled) private var isEnabled
    #if os(iOS)
    @Environment(\.isLocalPageActive) private var isPageActive
    #endif
    @State private var query = ""
    @State private var confirmsClear = false
    @State private var clearIDs = Set<String>()
    @State private var clearMangaIDs = Set<String>()
    @State private var mangaStore = MangaStore.shared
    @State private var mangaReading: MangaReading?
    @State private var mangaTask: Task<Void, Never>?
    @State private var mangaRequest: UUID?
    @State private var preparingMangaID: String?
    @State private var mangaFailure: String?
    @AppStorage("local.library.historyLayout") private var layout = "list"
    private var history: PlaybackHistory { store.playbackHistory }
    private var entries: [WatchingHistoryItem] {
        let videos = store.visibleHistory.map(WatchingHistoryItem.video)
        let comics = mangaStore.history.map(WatchingHistoryItem.manga)
        return (videos + comics).filter { item in
            guard !query.isEmpty else { return true }
            switch item {
            case .video(let entry):
                return entry.context.displayTitle.localizedCaseInsensitiveContains(query) || entry.context.sourceName.localizedCaseInsensitiveContains(query)
            case .manga(let progress):
                return progress.comic.title.localizedCaseInsensitiveContains(query) || mangaStore.name(of: progress.comic.sourceKey).localizedCaseInsensitiveContains(query)
            }
        }.sorted { $0.updated == $1.updated ? $0.id < $1.id : $0.updated > $1.updated }
    }

    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                WithPerceptionTracking {
                    VStack(alignment: .leading, spacing: Layout.headerSpacing) {
                        header
                        if let error = history.persistenceError { StatusNotice(text: L10n.text("Unable to save playback history: %@", error)) }
                        if let mangaFailure { StatusNotice(text: mangaFailure) }
                        if entries.isEmpty {
                            EmptyPage(symbol: AppSection.history.icon, title: "你的观看旅程即将开始",
                                      message: "播放或阅读后，这里会自动记录观看和漫画阅读进度。",
                                      action: "浏览站点", actionSymbol: AppSection.sites.icon, perform: { if canInteract { store.section = .sites } })
                        } else if layout == "horizontal" {
                            LazyVGrid(columns: Layout.posterColumns, spacing: Layout.gridRowSpacing) {
                                ForEach(entries) { item in
                                    WithPerceptionTracking {
                                        switch item {
                                        case .video(let entry): WatchingHistoryCard(entry: entry)
                                        case .manga(let progress): mangaCard(progress)
                                        }
                                    }
                                }
                            }
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(entries) { item in
                                    WithPerceptionTracking {
                                        switch item {
                                        case .video(let entry): historyRow(entry)
                                        case .manga(let progress): mangaRow(progress)
                                        }
                                    }
                                }
                            }
                        }
                    }.pageContainer()
                }
            }
            .catalogSearchable(text: $query, prompt: L10n.text("Search history"))
            .screenBackdrop().historyDetailsDestination().tabTitle(AppSection.history.title)
            .disabled(!canInteract)
            .fullScreenCover(item: $mangaReading) { reading in MangaReaderView(reading: reading) }
            .onDisappear { cancelMangaPreparation() }
            .appOnChange(of: canInteract) { _, active in if !active { cancelMangaPreparation() } }
            .appOnChange(of: store.resumingHistoryID) { _, id in if id != nil { cancelMangaPreparation() } }
            .confirmationDialog("清空当前显示的观看记录？", isPresented: $confirmsClear, titleVisibility: .visible) {
                Button("清空观看记录", role: .destructive) {
                    guard canInteract else { return }
                    if let preparingMangaID, clearMangaIDs.contains(preparingMangaID) { cancelMangaPreparation() }
                    history.remove(clearIDs); clearIDs.removeAll()
                    mangaStore.forget(ids: clearMangaIDs); clearMangaIDs.removeAll()
                }
                Button("取消", role: .cancel) { clearIDs.removeAll(); clearMangaIDs.removeAll() }
            }
        }
    }

    private var canInteract: Bool {
        #if os(iOS)
        isEnabled && isPageActive && store.section == .history
        #else
        isEnabled && store.section == .history
        #endif
    }

    private func resume(_ entry: PlaybackHistoryEntry, mode: PlaybackResumeMode = .resume) {
        guard canInteract else { return }
        cancelMangaPreparation()
        store.resume(entry, mode: mode)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack { Text("观看 · \(entries.count) 条").font(.title3.bold()); Spacer(); actions }
                VStack(alignment: .leading, spacing: 10) { Text("观看 · \(entries.count) 条").font(.title3.bold()); HStack { actions } }
            }
            Text(store.historySubscriptions.first.map { "当前订阅：\($0.title)" } ?? "未启用订阅期间")
                .font(.subheadline).foregroundStyle(.secondary)
            Text(store.historyScope == nil ? "包含未启用订阅期间、已启用的 Python 来源和漫画阅读记录。" : "包含当前订阅、已启用的 Python 来源和漫画阅读记录。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var actions: some View {
        Group {
            Button {
                guard canInteract else { return }
                layout = layout == "list" ? "horizontal" : "list"
            } label: {
                Image(systemName: layout == "list" ? "square.grid.2x2" : "list.bullet")
            }.controlButton().accessibilityLabel(layout == "list" ? "切换为横排" : "切换为列表")
            Button {
                guard canInteract else { return }
                captureClearSelection()
                confirmsClear = true
            } label: {
                Label("清空观看记录", systemImage: "trash").lineLimit(1)
            }.controlButton().disabled(entries.isEmpty)
        }
    }

    private func captureClearSelection() {
        clearIDs = Set(entries.compactMap { if case .video(let entry) = $0 { return entry.id }; return nil })
        clearMangaIDs = Set(entries.compactMap { if case .manga(let progress) = $0 { return progress.id }; return nil })
    }

    private func mangaCard(_ progress: MangaLibrary.Progress) -> some View {
        Button { resumeManga(progress) } label: {
            MangaCard(comic: progress.comic, caption: mangaCaption(progress))
        }.cardButton()
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 6) {
                    ArtworkBadgeButton(symbol: "arrow.counterclockwise", label: "从头阅读") { resumeManga(progress, beginning: true) }
                    ArtworkBadgeButton(symbol: "xmark", label: "移除阅读记录", destructive: true) {
                        guard canInteract else { return }
                        if preparingMangaID == progress.id { cancelMangaPreparation() }
                        mangaStore.forget(progress)
                    }
                }.padding(8)
            }
            .overlay { if preparingMangaID == progress.id { ProgressView().padding(12).background(.regularMaterial, in: Circle()) } }
            .accessibilityIdentifier("history.manga." + progress.id)
    }

    private func mangaRow(_ progress: MangaLibrary.Progress) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { resumeManga(progress) } label: {
                HStack(alignment: .top, spacing: 12) {
                    MangaCover(source: progress.comic.sourceKey, url: progress.comic.cover)
                        .frame(width: 54, height: 78).clipped().clipShape(RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(progress.comic.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                        Text("漫画 · " + mangaStore.name(of: progress.comic.sourceKey)).font(.caption).foregroundStyle(.secondary)
                        Text(MangaProgressText.short(progress)).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if preparingMangaID == progress.id { ProgressView() }
                    else { Text(progress.updated, style: .date).font(.caption2).foregroundStyle(.secondary) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            HStack(spacing: 12) {
                Button("从头阅读", systemImage: "arrow.counterclockwise") { resumeManga(progress, beginning: true) }
                Spacer(minLength: 0)
                Button("继续阅读", systemImage: "book") { resumeManga(progress) }
                Button(role: .destructive) {
                    guard canInteract else { return }
                    if preparingMangaID == progress.id { cancelMangaPreparation() }
                    mangaStore.forget(progress)
                } label: { Image(systemName: "xmark") }.accessibilityLabel("移除 " + progress.comic.title + " 的阅读记录")
            }.font(.subheadline).buttonStyle(.borderless)
        }.padding(14).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityIdentifier("history.manga." + progress.id)
    }

    private func mangaCaption(_ progress: MangaLibrary.Progress) -> String {
        "漫画 · " + mangaStore.name(of: progress.comic.sourceKey) + " · " + MangaProgressText.short(progress)
    }

    private func resumeManga(_ progress: MangaLibrary.Progress, beginning: Bool = false) {
        guard canInteract else { return }
        store.cancelResume()
        cancelMangaPreparation()
        let request = UUID()
        mangaRequest = request; preparingMangaID = progress.id; mangaFailure = nil
        mangaTask = Task { @MainActor in
            defer { if mangaRequest == request { preparingMangaID = nil; mangaRequest = nil; mangaTask = nil } }
            do {
                let details = try await MangaRuntime.shared.details(progress.comic.sourceKey, id: progress.comic.id)
                guard !Task.isCancelled, mangaRequest == request, canInteract,
                      store.resumingHistoryID == nil, store.playing == nil else { return }
                let position = progress.position(in: details.chapters, fromBeginning: beginning)
                mangaReading = MangaReading(comic: details.comic.merged(progress.comic), chapters: details.chapters,
                                            chapter: position.chapter, page: position.page)
            } catch {
                if !Task.isCancelled, mangaRequest == request { mangaFailure = error.mangaMessage }
            }
        }
    }

    private func cancelMangaPreparation() {
        mangaTask?.cancel(); mangaTask = nil; mangaRequest = nil; preparingMangaID = nil
    }
    private func historyRow(_ entry: PlaybackHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { resume(entry) } label: {
                HStack(alignment: .top, spacing: 12) {
                    HistoryPoster(entry: entry)
                        .frame(width: 54, height: 78).clipped().clipShape(RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.context.displayTitle).font(.headline).foregroundStyle(.primary).lineLimit(2)
                        Text([SourceLabel(entry.context.sourceName).text, entry.context.episodeFlag, entry.context.episodeName].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text(HistoryFormat.status(entry)).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(entry.updatedAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            HStack(spacing: 12) {
                Button("从头播放", systemImage: "arrow.counterclockwise") { resume(entry, mode: .beginning) }
                Spacer(minLength: 0)
                Button(entry.completed ? "重新观看" : "继续观看", systemImage: "play.fill") { resume(entry) }
                Button(role: .destructive) {
                    guard canInteract else { return }
                    history.remove(entry.id)
                } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("移除 \(entry.context.displayTitle) 的观看记录")
            }.font(.subheadline).buttonStyle(.borderless)
        }.padding(14).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }
}

enum HistoryMetrics {
    /// Continue Watching card width on Watch Now; the History page lets the grid size its cards.
    #if os(tvOS)
    static let card: CGFloat = DiscoverLayout.posterWidth
    #elseif os(macOS)
    static let card: CGFloat = 150
    #else
    static let card: CGFloat = 120
    #endif
}

enum HistoryFormat {
    static func status(_ entry: PlaybackHistoryEntry) -> String {
        if let reading = entry.context.readingProgress { return entry.completed ? "已看完 · \(reading.totalPages) 页" : "看到第 \(reading.page + 1) / \(reading.totalPages) 页" }
        return entry.completed ? "已看完" : "看到 \(EpisodeSkipSettings.formatTime(entry.position))"
    }
}

/// The independent Watching grid uses ordinary buttons only. Its controls and page
/// checks are separate from the homepage's native long-press menu.
struct WatchingHistoryCard: View {
    @Environment(Store.self) private var store
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.openHistoryDetails) private var openDetails
    @Environment(\.openRoute) private var openRoute
    #if os(iOS)
    @Environment(\.isLocalPageActive) private var isPageActive
    #endif
    let entry: PlaybackHistoryEntry

    private var canInteract: Bool {
        #if os(iOS)
        isEnabled && isPageActive && store.section == .history
        #else
        isEnabled && store.section == .history
        #endif
    }

    var body: some View {
        WithPerceptionTracking {
            Button { resume() } label: { HistoryCardLabel(entry: entry, details: true) }
                .cardButton()
                .accessibilityIdentifier("history.resume." + entry.context.videoID)
                .overlay(alignment: .topTrailing) {
                    WithPerceptionTracking {
                        HStack(spacing: 6) {
                            ArtworkBadgeButton(symbol: "arrow.counterclockwise", label: "从头播放") { resume(mode: .beginning) }
                            if let route = detailsRoute {
                                ArtworkBadgeButton(symbol: "info", label: L10n.text("Show Details")) {
                                    guard canInteract else { return }
                                    store.cancelResume()
                                    if let openDetails { openDetails(route) } else { openRoute?(route) }
                                }
                            }
                            ArtworkBadgeButton(symbol: "xmark", label: L10n.text("Remove from history"), destructive: true) {
                                guard canInteract else { return }
                                store.playbackHistory.remove(entry.id)
                            }
                        }.padding(8)
                    }
                }
                .disabled(!canInteract)
        }
    }

    private func resume(mode: PlaybackResumeMode = .resume) {
        guard canInteract else { return }
        store.resume(entry, mode: mode)
    }

    private var detailsRoute: Route? {
        guard openDetails != nil || openRoute != nil, let client = store.historyClient(entry) else { return nil }
        return Route { AnyView(VideoDetailView(video: entry.listVideo, client: client)) }
    }
}

/// Shared artwork and captions contain no gestures, modal state or route ownership.
struct HistoryCardLabel: View {
    @Environment(Store.self) private var store
    @AppStorage(HistoryFileDetails.key) private var showsFileDetails = false
    let entry: PlaybackHistoryEntry
    var details = false

    var body: some View { WithPerceptionTracking { cardLabel } }

    /// The short episode label when history kept a netdisk file's name (#521, #522): the card cut a long name off after
    /// the show's, so every episode of a series looked the same. With file details on, its size and quality follow
    /// the number (#595).
    private var episodeLabel: String {
        EpisodeLabels.historyLabel(entry.context.episodeName, showsDetails: showsFileDetails)
    }

    private var cardLabel: some View {
        VStack(alignment: centredCaptions ? .center : .leading, spacing: 8) {
            Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay { WithPerceptionTracking { HistoryPoster(entry: entry) } }
                .coverOverlay(alignment: .bottom) {
                    WithPerceptionTracking {
                        if entry.duration > 0 {
                            // White on the artwork, as in the TV app: the accent is near-black in light mode.
                            GeometryReader { proxy in
                                WithPerceptionTracking {
                                    Capsule().fill(.white.opacity(0.25))
                                        .overlay(alignment: .leading) { WithPerceptionTracking { Capsule().fill(.white).frame(width: proxy.size.width * entry.progress) } }
                                }
                            }
                            .frame(height: 5).padding(10)
                        }
                    }
                }
                .coverOverlay(animated: true) {
                    WithPerceptionTracking {
                        // Preparing this title; choosing another card switches to that one.
                        if store.resumingHistoryID == entry.id {
                            ZStack {
                                Color.black.opacity(0.5)
                                ProgressView().controlSize(.large).tint(.white)
                            }
                        }
                    }
                }
                .posterClip(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(entry.context.displayTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                .cardCaption()
            if details {
                Text("\(episodeLabel) · \(SourceLabel(entry.context.sourceName).text)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).cardCaption()
                Text(HistoryFormat.status(entry)).font(.caption).monospacedDigit().foregroundStyle(.tertiary).lineLimit(1)
                    .cardCaption()
            } else {
                // The bar on the poster already says how far; the line names the episode.
                Text(episodeLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1).cardCaption()
            }
        }
        .frame(width: details ? nil : HistoryMetrics.card)
        .frame(maxWidth: details ? .infinity : nil, alignment: .leading)
    }

    /// On Apple TV's Watch Now the captions are centred under the cover, as Discover's.
    private var centredCaptions: Bool {
        #if os(tvOS)
        !details
        #else
        false
        #endif
    }

}

extension EnvironmentValues { @Entry var openHistoryDetails: ((Route) -> Void)? = nil }

extension View {
    /// Lets the history cards under it open a title's page (from the cards' visible controls or homepage menu). Outside the cards' lazy grids:
    /// a navigation destination inside a lazy container is not supported.
    func historyDetailsDestination() -> some View { modifier(HistoryDetailsDestination()) }
}

private struct HistoryDetailsDestination: ViewModifier {
    @Environment(\.openRoute) private var openRoute
    @State private var route: Route?
    func body(content: Content) -> some View {
        WithPerceptionTracking {
            content
                .environment(\.openHistoryDetails) { if let openRoute { openRoute($0) } else { route = $0 } }
                .appNavigationDestination(item: $route) { route in
                    WithPerceptionTracking {
                        #if os(macOS)
                        route.build().musicBar()
                        #else
                        route.build()
                        #endif
                    }
                }
        }
    }
}
