#if os(iOS)
import SwiftUI
import Perception
import TVCore

/// Playback resources remain in the detail page: choose a source, one of its
/// titles, then a line/episode without pushing a second results screen.
struct LocalQuickSearchView: View {
    @Environment(Store.self) private var store
    @Environment(\.isLocalPageActive) private var pageActive
    @Environment(\.scenePhase) private var scenePhase
    let model: LocalQuickSearchModel
    let query: String
    var metadata: TMDBMatch.Details? = nil
    var metadataNumbering = TMDBMatch.Numbering.season
    var metadataOffset = 0
    @State private var episodeDetails: [Episode.ID: String] = [:]
    @State private var selectedEpisode: Episode?
    @State private var choosingDownloads = false
    @State private var queuedNotice: Int?
    @State private var historyLineOwner: String?
    @State private var playbackTask: Task<Void, Never>?
    @State private var playbackRequest = UUID()
    @State private var loadingEpisode: String?
    @State private var loadingMode: PlaybackResumeMode?
    @State private var retryMode = PlaybackResumeMode.resume
    @State private var playbackError: String?
    @State private var signInProvider: String?
    @State private var signInShown = false
    @State private var retryEpisode: Episode?
    @State private var signInClient: CatalogClient?
    @State private var playbackOwner: String?
    @State private var signInCatalogRevision: UInt64?
    @State private var signInRequestOwner: UUID?
    @State private var signInRetryPending = false
    private struct DetailOwner: Equatable {
        let selection: UUID
        let video: Video?
    }
    private var detailOwner: DetailOwner { .init(selection: model.selectionRevision, video: model.detail) }

    private var client: CatalogClient? {
        guard let selection = model.selected, let config = store.subscription else { return nil }
        return CatalogClient(site: selection.site, origin: config.origin, jarURL: config.spiderURL).applying(config)
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 16) {
                playbackActions
                heading
                if !model.sources.isEmpty {
                    sourceStrip
                    resultStrip
                    groupedResources
                    detailSection
                } else if model.search.busy {
                    HStack(spacing: 10) { ProgressView(); Text("正在查找播放资源…").font(.subheadline) }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 16)
                } else {
                    Text(store.subscription == nil ? "添加订阅后即可搜索播放资源。" : "暂未找到匹配资源，可重新搜索。")
                        .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
                }
                if model.search.deadlineReached || model.deadlineReached {
                    Text("已搜索 15 秒，保留当前结果。可重新搜索或选择已有资源。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let playbackError {
                    Text(playbackError).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    if signInProvider != nil {
                        Button("登录此站点的网盘") { signInShown = true }.buttonStyle(.bordered)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("detail.quickSearch")
            .appOnChange(of: model.selectionRevision) { _, _ in
                cancelPlayback(); selectedEpisode = nil; historyLineOwner = nil; episodeDetails = [:]
            }
            .appOnChange(of: store.subscriptionRevision) { _, _ in cancelPlayback() }
            .appOnChange(of: model.selectedFlag) { _, _ in selectedEpisode = nil }
            .appOnChange(of: detailOwner, initial: true) { _, _ in restoreHistoryLine() }
            .task(id: detailOwner) {
                let items = model.detail?.episodes ?? []
                let labels = await Task.detached(priority: .userInitiated) {
                    EpisodeFileInfo.details(items, labels: EpisodeLabels.labels(items))
                }.value
                guard !Task.isCancelled else { return }
                episodeDetails = labels
            }
            .appOnChange(of: pageActive) { _, active in if !active { cancelPlayback() } }
            .appOnChange(of: scenePhase) { _, phase in
                if phase == .active { resumeSignedInPlayback() } else { suspendPlayback() }
            }
            .onDisappear { cancelPlayback() }
            .sheet(isPresented: $signInShown) {
                WithPerceptionTracking {
                    if let signInClient, let provider = signInProvider, let owner = playbackOwner,
                       let revision = signInCatalogRevision {
                        CatPawSignInView(client: signInClient, provider: provider) {
                            guard pageActive, owner == model.selected?.id, owner == playbackOwner,
                                  revision == store.subscriptionRevision,
                                  signInRequestOwner == model.selectionRevision else { return }
                            signInShown = false
                            signInRetryPending = true
                            resumeSignedInPlayback()
                        }
                    }
                }
            }
            .downloadPicker(isPresented: $choosingDownloads) {
                if let video = model.detail, let client {
                    DownloadPicker(video: downloadVideo(video), site: client.site, flag: model.selectedFlag ?? "", episodes: model.episodes) { count in
                        if count > 0 { queuedNotice = count }
                    }
                }
            }
        }
    }

    @ViewBuilder private var playbackActions: some View {
        if let video = model.detail, let client, !video.episodes.isEmpty {
            let selection = DetailPlaybackSelection(episodes: video.episodes, activeFlag: model.selectedFlag ?? "",
                                                    selectedEpisode: selectedEpisode, history: histories(video, client: client))
            VStack(alignment: .leading, spacing: 10) {
                DetailPlaybackControls(selection: selection, busy: loadingEpisode != nil, loadingMode: loadingMode) { mode in
                    if let episode = selection.episode { play(episode, mode: mode) }
                }
                HStack(spacing: 10) {
                    let favorite = FavoriteItem.video(FavoriteVideo(origin: client.origin, site: client.site, video: video))
                    let saved = store.favorites.contains(favorite)
                    Button { store.favorites.toggle(favorite) } label: {
                        Label(saved ? "已收藏" : "收藏", systemImage: saved ? "heart.fill" : "heart")
                            .font(.headline).foregroundStyle(saved ? Brand.rose : Color.primary)
                    }.controlButton().controlSize(.large)
                        .accessibilityIdentifier("detail.favorite")
                    Button { choosingDownloads = true } label: {
                        Label("下载", systemImage: "arrow.down.circle").font(.headline)
                    }.controlButton().controlSize(.large).disabled(model.episodes.isEmpty)
                        .accessibilityIdentifier("detail.download")
                }
                if let count = queuedNotice {
                    Text("已添加 \(count) 集到下载队列").font(.footnote).foregroundStyle(.secondary)
                }
            }
        } else {
            HStack(spacing: 8) {
                if model.loadingDetail || model.search.busy { ProgressView().controlSize(.small) }
                Image(systemName: "play.fill").foregroundStyle(Brand.accent)
                Text(model.groups.isEmpty ? "选择下方播放资源" : "选择下方具体资源后播放").font(.subheadline)
            }.frame(maxWidth: .infinity, minHeight: 64, alignment: .leading).padding(.horizontal, 13)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private var heading: some View {
        HStack(spacing: 10) {
            Text("播放资源").font(.title3.weight(.semibold))
            if model.search.busy { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
            Text("\(model.search.completed)/\(model.search.total)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Button {
                cancelPlayback()
                guard let config = store.subscription else { return }
                store.searchModel.suspend()
                model.start(query, config: config) { store.hiddenSources.contains($0, origin: config.origin) }
            } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44).contentShape(Rectangle()) }
                .buttonStyle(.plain).disabled(store.subscription == nil)
                .accessibilityLabel("重新搜索资源").accessibilityIdentifier("detail.quickSearch.retry")
        }
    }

    private var sourceStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(model.sources) { source in
                    WithPerceptionTracking {
                        Button {
                            cancelPlayback(); model.chooseSource(source.id)
                        } label: {
                            Text("\(SourceLabel(source.site.name).text) · \(model.search.videoCount(for: source.id))")
                                .font(.subheadline.weight(.medium)).lineLimit(1)
                                .padding(.horizontal, 14).frame(minHeight: 44)
                                .background(model.selectedSourceID == source.id ? Brand.accent.opacity(0.24) : Color.primary.opacity(0.07), in: Capsule())
                                .overlay { Capsule().strokeBorder(model.selectedSourceID == source.id ? Brand.accent.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: 1) }
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(model.selectedSourceID == source.id ? .isSelected : [])
                            .accessibilityIdentifier("detail.quickSearch.source." + source.id)
                    }
                }
            }
        }
    }

    private var resultStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                if let source = model.sources.first(where: { $0.id == model.selectedSourceID }) {
                    ForEach(model.search.videos(for: source.id)) { video in
                        WithPerceptionTracking {
                        let item = SearchVideoResult(site: source.site, video: video)
                        Button { cancelPlayback(); model.choose(item) } label: {
                            HStack(spacing: 12) {
                                PosterImage(url: video.poster, headers: video.posterHeaders)
                                    .frame(width: 55, height: 78).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(video.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                    Text(video.remarks).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    Text(SourceLabel(source.site.name).text).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if model.rootSelectionID == item.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.accent) }
                            }
                            .padding(12).frame(width: 282, alignment: .leading)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                            .overlay { WithPerceptionTracking { RoundedRectangle(cornerRadius: 18).strokeBorder(model.rootSelectionID == item.id ? Brand.accent : Color.primary.opacity(0.08), lineWidth: 1.5) } }
                            .contentShape(RoundedRectangle(cornerRadius: 18))
                        }.buttonStyle(.plain).accessibilityIdentifier("detail.quickSearch.result." + item.id)
                        }
                    }
                }
            }.padding(.vertical, 2)
        }.searchPosterThumbnails()
    }

    @ViewBuilder private var groupedResources: some View {
        if let group = model.groups.last {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button { cancelPlayback(); model.goBack() } label: {
                        Label("返回", systemImage: "chevron.left").frame(minHeight: 44)
                    }.buttonStyle(.plain).accessibilityLabel("返回上一层资源")
                        .accessibilityIdentifier("detail.quickSearch.back")
                    Text(model.groups.map { $0.selection.video.name }.joined(separator: " › "))
                        .font(.subheadline.weight(.semibold)).lineLimit(2)
                    Spacer(minLength: 0)
                }
                if group.loaded && group.videos.isEmpty {
                    Text("这个分类暂时没有资源，可返回选择其它分类。").font(.footnote).foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(group.videos) { video in
                                WithPerceptionTracking {
                                    let selected = model.selected?.video.id == video.id
                                    Button { cancelPlayback(); model.chooseChild(video) } label: {
                                        HStack(spacing: 10) {
                                            PosterImage(url: video.poster, headers: video.posterHeaders)
                                                .frame(width: 55, height: 78).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                                            VStack(alignment: .leading, spacing: 7) {
                                                Text(video.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                                Text(video.remarks).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                                if video.isFolder { Label("查看子资源", systemImage: "folder").font(.caption2).foregroundStyle(.secondary) }
                                            }.frame(maxWidth: .infinity, alignment: .leading)
                                            Image(systemName: video.isFolder ? "chevron.right" : selected ? "checkmark.circle.fill" : "play.circle")
                                                .foregroundStyle(selected ? Brand.accent : Color.secondary)
                                        }.padding(12).frame(width: 282, alignment: .leading)
                                            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                                            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(selected ? Brand.accent : Color.primary.opacity(0.08), lineWidth: 1.5) }
                                            .contentShape(RoundedRectangle(cornerRadius: 18))
                                    }.buttonStyle(.plain).accessibilityIdentifier("detail.quickSearch.child." + video.id)
                                }
                            }
                        }.padding(.vertical, 2)
                    }.searchPosterThumbnails().id(group.id)
                }
                if group.hasMore {
                    Button { cancelPlayback(); model.loadMoreResources() } label: {
                        Label("加载更多资源", systemImage: "chevron.down").frame(minHeight: 44)
                    }.buttonStyle(.plain).disabled(model.loadingDetail)
                }
                if let notice = model.resourceNotice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder private var detailSection: some View {
        if model.loadingDetail {
            HStack(spacing: 10) { ProgressView(); Text(model.selected?.video.isFolder == true ? "正在读取分类资源…" : "正在读取线路和选集…").font(.subheadline) }
                .padding(.vertical, 10)
        } else if let error = model.detailError {
            Text(error).font(.footnote).foregroundStyle(.secondary)
            Button("重试读取资源") { model.retry() }.buttonStyle(.bordered)
        } else if let video = model.detail {
            if model.flags.isEmpty {
                Text("这个结果暂时没有可播放的选集，请选择其它资源。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                episodeSection(video)
            }
        }
    }

    private func episodeSection(_ video: Video) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("线路").font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.flags, id: \.self) { flag in
                            WithPerceptionTracking {
                                Button { cancelPlayback(); model.selectFlag(flag) } label: {
                                    Text(flag.isEmpty ? "默认线路" : SourceLabel(flag).text)
                                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                                        .padding(.horizontal, 15).frame(minHeight: 44)
                                        .foregroundStyle(model.selectedFlag == flag ? Brand.onAccent : Color.primary)
                                        .background(model.selectedFlag == flag ? Brand.accent : Color.primary.opacity(0.06), in: Capsule())
                                }.buttonStyle(.plain).accessibilityAddTraits(model.selectedFlag == flag ? .isSelected : [])
                                    .accessibilityIdentifier("detail.line." + flag)
                            }
                        }
                    }
                }
            }
            let input = LocalCatalogEpisodeSnapshot.Input(episodes: model.episodes,
                details: DetailResourceMetadata.matching(metadata, title: video.name, year: video.year, flag: model.selectedFlag ?? ""),
                numbering: metadataNumbering, offset: metadataOffset,
                sourceTitle: video.name, flag: model.selectedFlag ?? "", fileDetails: episodeDetails)
            LocalCatalogEpisodePanel(input: input, owner: (model.selected?.id ?? "") + "|" + (model.selectedFlag ?? ""), loading: loadingEpisode != nil) {
                EmptyView()
            } episode: { value, list in
                episodeButton(value, video: video, list: list)
            }
        }
    }

    private func episodeButton(_ value: LocalCatalogDetailEpisode, video: Video, list: Bool) -> some View {
        let episode = value.episode
        let matched = DetailResourceMetadata.matching(metadata, title: video.name, year: video.year, flag: model.selectedFlag ?? "")
        let movie = matched?.mediaType == .movie
        return Button { play(episode) } label: {
            if list { LocalCatalogDetailEpisodeRow(value: value, movie: movie, loading: loadingEpisode == episode.id) }
            else {
                LocalCatalogDetailEpisodeCard(value: value, video: video, movieArtwork: movie ? matched?.backdrop ?? matched?.poster : nil,
                                              movie: movie, loading: loadingEpisode == episode.id)
            }
        }.buttonStyle(.plain).disabled(loadingEpisode != nil)
            .accessibilityLabel("播放 " + episode.name).accessibilityIdentifier("detail.quickSearch.episode." + episode.id)
            .overlay(alignment: .topTrailing) {
                if let client, download(episode, video: video, client: client)?.status == .completed { DownloadedBadge().padding(4) }
            }
            .overlay(alignment: .bottomTrailing) {
                if let client, store.favorites.contains(episodeFavorite(episode, video: video, client: client)) {
                    Image(systemName: "heart.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.rose).padding(4).allowsHitTesting(false)
                }
            }
            .contextMenu {
                WithPerceptionTracking {
                    Text(episode.name)
                    Button("从头播放", systemImage: "arrow.counterclockwise") { play(episode, mode: .beginning) }
                    if let client {
                        FavoriteMenuButton(item: episodeFavorite(episode, video: video, client: client), name: episode.name)
                        let saved = download(episode, video: video, client: client)
                        if saved == nil || saved?.status == .failed {
                            Button("下载", systemImage: "arrow.down.circle") {
                                DownloadLibrary.shared.download(DownloadSource(site: client.site, videoID: model.selected?.video.id ?? video.id, episode: episode),
                                                                title: video.name, poster: video.poster, posterHeaders: video.posterHeaders)
                            }
                        } else if let saved {
                            Button(L10n.text(saved.status == .completed ? "Delete Download" : "Cancel Download"), systemImage: "trash", role: .destructive) {
                                DownloadLibrary.shared.remove([saved.id])
                            }
                        }
                    }
                }
            }
    }

    private func histories(_ video: Video, client: CatalogClient) -> [PlaybackHistoryEntry] {
        let identifiers = Set([model.selected?.video.id, video.id].compactMap { $0 })
        return store.visibleHistory.filter { $0.context.matchesVideo(origin: client.origin, sourceKey: client.site.sourceKey, videoIDs: identifiers) }
    }

    private func restoreHistoryLine() {
        guard let selected = model.selected, let video = model.detail, let client, historyLineOwner != selected.id else { return }
        historyLineOwner = selected.id
        let watched = histories(video, client: client).first { model.flags.contains($0.context.episodeFlag) }?.context.episodeFlag
        if let flag = watched ?? CloudDrive.preferredFlag(model.flags) { model.selectFlag(flag) }
    }

    private func episodeFavorite(_ episode: Episode, video: Video, client: CatalogClient) -> FavoriteItem {
        .episode(FavoriteEpisode(video: FavoriteVideo(origin: client.origin, site: client.site, video: video),
                                 episodeFlag: episode.flag, episodeName: episode.name, episodeID: episode.id))
    }

    private func download(_ episode: Episode, video: Video, client: CatalogClient) -> DownloadItem? {
        DownloadLibrary.shared.item(for: DownloadSource(site: client.site, videoID: model.selected?.video.id ?? video.id, episode: episode))
    }

    /// Ordinary catalog downloads are keyed by the card's listing ID; a provider
    /// may return a different canonical detail ID used by playback and history.
    private func downloadVideo(_ video: Video) -> Video {
        guard let listing = model.selected?.video, listing.id != video.id else { return video }
        return Video(id: listing.id, name: video.name, poster: video.poster, posterHeaders: video.posterHeaders,
                     year: video.year, remarks: video.remarks, synopsis: video.synopsis, episodes: video.episodes,
                     category: video.category, area: video.area, director: video.director, actor: video.actor, panShare: video.panShare)
    }

    private func cancelPlayback() {
        playbackRequest = UUID(); playbackTask?.cancel(); playbackTask = nil; loadingEpisode = nil; loadingMode = nil
        playbackError = nil; signInProvider = nil; retryEpisode = nil
        choosingDownloads = false; queuedNotice = nil
        signInShown = false; signInClient = nil; playbackOwner = nil; signInCatalogRevision = nil
        signInRequestOwner = nil; signInRetryPending = false
    }

    private func resumeSignedInPlayback() {
        guard signInRetryPending, scenePhase == .active else { return }
        signInRetryPending = false
        guard pageActive, playbackOwner == model.selected?.id,
              signInCatalogRevision == store.subscriptionRevision, signInRequestOwner == model.selectionRevision,
              let episode = retryEpisode else { return }
        play(episode, mode: retryMode)
    }

    private func suspendPlayback() {
        // Approving a source QR code can require opening its official app. Keep
        // that owned sign-in sheet alive; source/result changes still clear it.
        playbackRequest = UUID(); playbackTask?.cancel(); playbackTask = nil; loadingEpisode = nil; loadingMode = nil
    }

    private func play(_ episode: Episode, mode: PlaybackResumeMode = .resume) {
        guard pageActive, scenePhase == .active, loadingEpisode == nil,
              let client, let selectedID = model.selected?.id, let video = model.detail, video.episodes.contains(episode) else { return }
        model.stop(); store.searchModel.suspend()
        let request = UUID(); playbackRequest = request
        let catalogRevision = store.subscriptionRevision
        loadingEpisode = episode.id; loadingMode = mode; selectedEpisode = episode
        playbackError = nil; signInProvider = nil; retryEpisode = episode; retryMode = mode
        signInClient = nil; signInCatalogRevision = nil; playbackOwner = model.selected?.id
        signInRequestOwner = model.selectionRevision; signInRetryPending = false
        playbackTask = Task {
            defer { if playbackRequest == request { playbackTask = nil; loadingEpisode = nil; loadingMode = nil } }
            do {
                let selection = DetailPlaybackSelection(episodes: video.episodes, activeFlag: episode.flag, selectedEpisode: episode,
                    history: histories(video, client: client))
                let resolved: Channel
                if let saved = download(episode, video: video, client: client), saved.status == .completed {
                    resolved = DownloadLibrary.shared.channel(for: saved)
                } else {
                    resolved = try await client.playback(episode)
                }
                guard !Task.isCancelled, playbackRequest == request, pageActive,
                      model.selected?.id == selectedID, model.detail?.id == video.id,
                      store.subscriptionRevision == catalogRevision else { return }
                store.playing = store.catalogChannel(resolved, video: video, episode: episode, client: client, resumePosition: selection.position(for: mode))
            } catch {
                guard !Task.isCancelled, playbackRequest == request,
                      model.selected?.id == selectedID, model.detail?.id == video.id,
                      store.subscriptionRevision == catalogRevision else { return }
                playbackError = error.localizedDescription
                if client.site.isCatPawOpen {
                    signInProvider = CatPawSignIn.provider(for: error.localizedDescription)
                    if signInProvider != nil { signInClient = client; signInCatalogRevision = catalogRevision }
                }
            }
        }
    }
}

/// Kept on the full detail page so search begins during navigation, before a lazy
/// below-the-fold result section or the remote metadata has appeared.
struct LocalQuickSearchLifecycle: ViewModifier {
    @Environment(Store.self) private var store
    @Environment(\.isLocalPageActive) private var pageActive
    @Environment(\.scenePhase) private var scenePhase
    @State private var onScreen = false
    let model: LocalQuickSearchModel
    let query: String
    let enabled: Bool
    func body(content: Content) -> some View {
        WithPerceptionTracking {
            content
                .onAppear { onScreen = true; startIfNeeded() }
                .onDisappear { onScreen = false; model.stop() }
                .appOnChange(of: enabled) { _, value in if value { startIfNeeded(force: true) } else { model.stop() } }
                .appOnChange(of: query) { _, _ in startIfNeeded() }
                .appOnChange(of: pageActive) { _, active in if active { startIfNeeded() } else { model.stop() } }
                .appOnChange(of: scenePhase) { _, phase in if phase == .active { startIfNeeded() } else { model.stop() } }
                .appOnChange(of: store.subscriptionRevision) { _, _ in
                    model.reset(); startIfNeeded(force: true)
                }
                .appOnChange(of: model.search.results.map(\.id)) { _, _ in model.reconcile() }
                .appOnChange(of: model.search.deadlineReached) { _, expired in if expired { model.expireDetails() } }
        }
    }

    private func startIfNeeded(force: Bool = false) {
        guard enabled, onScreen, pageActive, scenePhase == .active, let config = store.subscription else { return }
        guard force || model.search.keyword != query else { return }
        store.searchModel.suspend()
        model.start(query, config: config) { store.hiddenSources.contains($0, origin: config.origin) }
        model.reconcile()
    }
}
#endif
