#if os(iOS)
import SwiftUI
import Perception
import TVCore

@MainActor @Perceptible final class IPTVUserStations {
    static let shared = IPTVUserStations()
    private static let key = "local.iptv.recent.v1"
    private(set) var recentIDs: [String]

    private init() {
        recentIDs = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
    }

    func didPlay(_ station: IPTVStation) {
        guard recentIDs.first != station.id else { return }
        recentIDs.removeAll { $0 == station.id }
        recentIDs.insert(station.id, at: 0)
        recentIDs = Array(recentIDs.prefix(100))
        UserDefaults.standard.set(recentIDs, forKey: Self.key)
    }
}

extension IPTVRecord {
    @MainActor func guideContext(for station: IPTVStation) -> IPTVGuideContext? {
        let addresses = IPTVGuideContext.resolvedAddresses(override: guideOverride, station: station.guideURL,
                                                          subscription: epgURLs)
        let usesChild = guideOverride?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            && station.guideURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let origin = self.address.flatMap(URL.init(string:))
        let base = usesChild ? station.guideOrigin ?? origin : origin
        let headers = usesChild ? station.guideHeaders ?? IPTVLibrary.shared.headers(for: id) : IPTVLibrary.shared.headers(for: id)
        return IPTVGuideContext(sourceID: id, address: addresses[0], stations: stations, timeZoneID: timeZoneID,
                                origin: base, headers: headers, fallbackAddresses: Array(addresses.dropFirst()),
                                fallbackOrigin: origin, fallbackHeaders: IPTVLibrary.shared.headers(for: id))
    }
}

private enum IPTVBrowserSelection: Hashable {
    case source(String), favorites, recent
}

@MainActor struct IPTVBrowserView: View {
    @Environment(Store.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("local.iptv.lastSource") private var lastSource = ""
    @AppStorage("local.iptv.lastGroup") private var group = ""
    @State private var selection: IPTVBrowserSelection?
    @State private var search = ""
    @State private var choosingSource = false
    private let library = IPTVLibrary.shared
    private let history = IPTVUserStations.shared

    var body: some View {
        WithPerceptionTracking {
            let records = library.records.filter(\.enabled)
            let requested = selection ?? .source(lastSource)
            let record = records.first(where: { $0.id == sourceID(requested) }) ?? records.first
            let chosen = isSource(requested) ? record.map { IPTVBrowserSelection.source($0.id) } ?? requested : requested
            let allStations = records.flatMap(\.stations)
            let byID = Dictionary(allStations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let saved = store.favorites.liveChannels
            let favoriteIDs = saved.compactMap { IPTVStationReference.id(for: $0) }
            let otherFavorites = saved.filter { channel in
                if let id = IPTVStationReference.id(for: channel) { return byID[id] == nil }
                return IPTVRoomAddress(channel.url) != nil
            }
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            VStack(spacing: 0) {
                if records.isEmpty {
                    Spacer()
                    Image(systemName: "dot.radiowaves.left.and.right").font(.largeTitle).foregroundStyle(Brand.teal)
                    Text(library.records.isEmpty ? "尚未添加直播订阅" : "直播订阅已全部停用").font(.headline).padding(.top, 12)
                    if let error = library.loadError { Text(error).font(.caption).foregroundStyle(.secondary).padding() }
                    RouteLink { IPTVSettingsView() } label: { Text("前往设置管理直播订阅") }
                        .buttonStyle(.borderedProminent).padding()
                    if !otherFavorites.isEmpty {
                        List(otherFavorites) { channel in
                            WithPerceptionTracking { savedRow(channel, records: records) }
                        }.listStyle(.plain).localDockScrollInsets()
                    } else { Spacer() }
                } else {
                    let groups = orderedGroups(record?.stations ?? [])
                    let selectedGroup = groups.contains(group) ? group : ""
                    let lineup = stations(chosen, record: record, group: selectedGroup, map: byID, favorites: favoriteIDs)
                    let displayed = query.isEmpty ? lineup : allStations.filter { matches($0, query: query) }
                    HStack(spacing: 8) {
                        Button { choosingSource = true } label: {
                            HStack(spacing: 10) {
                                IPTVSourceIcon(selection: chosen, size: 30)
                                Text(title(chosen, record: record))
                                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.down")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .frame(minHeight: 48)
                            .background { TileSurface(focused: false, radius: 18) }
                            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .accessibilityLabel("选择直播来源")
                        .accessibilityValue(title(chosen, record: record))
                        .accessibilityIdentifier("iptv.sources.open")
                        if let record, case .source = chosen {
                            let refreshing = library.refreshingIDs.contains(record.id)
                            Button {
                                Task { do { try await library.refresh(record.id) } catch is CancellationError {} catch { store.error = error.localizedDescription } }
                            } label: {
                                Group {
                                    if refreshing { ProgressView() }
                                    else { Image(systemName: "arrow.clockwise") }
                                }.frame(width: 44, height: 44).contentPanel(cornerRadius: 14)
                            }
                            .disabled(refreshing)
                            .accessibilityLabel(refreshing ? "正在刷新直播订阅" : "刷新直播订阅")
                        }
                        RouteLink { IPTVSettingsView() } label: {
                            Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44).contentPanel(cornerRadius: 14)
                        }.accessibilityLabel("直播订阅设置")
                    }
                    .buttonStyle(.plain).font(.body.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    if query.isEmpty, case .source = chosen, let error = record?.lastError {
                        Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                    }
                    let showGroups = query.isEmpty && !groups.isEmpty && isSource(chosen)
                    if sizeClass == .regular, showGroups {
                        HStack(alignment: .top, spacing: 0) {
                            ScrollView { VStack(alignment: .leading, spacing: 4) { groupButtons(groups, selected: selectedGroup) } }
                                .frame(width: 150)
                            Divider()
                            listing(displayed, records: records, chosen: chosen, query: query, record: record, otherFavorites: otherFavorites)
                        }
                    } else {
                        if showGroups {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack { groupButtons(groups, selected: selectedGroup) }.padding(.horizontal)
                            }
                        }
                        listing(displayed, records: records, chosen: chosen, query: query, record: record, otherFavorites: otherFavorites)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("直播")
            .searchable(text: $search, prompt: "搜索台名、台号或分组")
            .screenBackdrop()
            .task(id: records.map { $0.lastUpdated }) { store.favorites.migrateIPTVStations(allStations) }
            .sheet(isPresented: $choosingSource) {
                IPTVSourceSelectionSheet(records: records, selected: chosen) { value in
                    select(value)
                    choosingSource = false
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private func sourceID(_ value: IPTVBrowserSelection) -> String? {
        if case .source(let id) = value { return id }
        return nil
    }

    private func isSource(_ value: IPTVBrowserSelection) -> Bool { sourceID(value) != nil }

    private func title(_ value: IPTVBrowserSelection, record: IPTVRecord?) -> String {
        switch value {
        case .source: return record?.name ?? "直播订阅"
        case .favorites: return "我的收藏"
        case .recent: return "最近观看"
        }
    }

    private func select(_ value: IPTVBrowserSelection) {
        selection = value
        if let id = sourceID(value) { lastSource = id }
        group = ""
        search = ""
    }

    private func stations(_ value: IPTVBrowserSelection, record: IPTVRecord?, group: String,
                          map: [String: IPTVStation], favorites: [String]) -> [IPTVStation] {
        switch value {
        case .favorites: return favorites.compactMap { map[$0] }
        case .recent: return history.recentIDs.compactMap { map[$0] }
        case .source: return (record?.stations ?? []).filter { group.isEmpty || $0.group == group }
        }
    }

    private func orderedGroups(_ stations: [IPTVStation]) -> [String] {
        var seen = Set<String>()
        return stations.compactMap { !$0.group.isEmpty && seen.insert($0.group).inserted ? $0.group : nil }
    }

    private func matches(_ station: IPTVStation, query: String) -> Bool {
        [station.name, station.group, station.number ?? ""].contains { $0.localizedStandardContains(query) }
    }

    private func groupButtons(_ groups: [String], selected: String) -> some View {
        ForEach([""] + groups, id: \.self) { name in
            Button { group = name } label: {
                Text(name.isEmpty ? "全部" : name).font(.subheadline)
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .background(selected == name ? Brand.teal.opacity(0.16) : Color.clear, in: Capsule())
            }.buttonStyle(.plain).accessibilityAddTraits(name == selected ? .isSelected : [])
        }
    }

    private func listing(_ displayed: [IPTVStation], records: [IPTVRecord], chosen: IPTVBrowserSelection,
                         query: String, record: IPTVRecord?, otherFavorites: [Channel]) -> some View {
        let searchable = !query.isEmpty
        let platformRecord = !searchable && isSource(chosen) ? record : nil
        let owners = Dictionary(records.flatMap { source in source.stations.map { ($0.id, source.id) } },
                                uniquingKeysWith: { first, _ in first })
        let sources = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if let source = platformRecord {
                    ForEach(source.platforms) { platform in
                        RouteLink { IPTVPlatformView(sourceID: source.id, platform: platform) } label: {
                            Label(platform.name, systemImage: "dot.radiowaves.left.and.right")
                                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading).padding(.horizontal).contentPanel()
                        }
                    }
                }
                let extras = chosen == .favorites && query.isEmpty ? otherFavorites : []
                ForEach(extras) { channel in WithPerceptionTracking { savedRow(channel, records: records) } }
                if displayed.isEmpty && platformRecord?.platforms.isEmpty != false && extras.isEmpty {
                    Text(searchable ? "没有匹配的频道" : "暂无频道").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                }
                ForEach(displayed) { station in
                    WithPerceptionTracking {
                        let owner = owners[station.id].flatMap { sources[$0] }
                        stationRow(station, owner: owner, showSource: searchable || !isSource(chosen)) {
                            store.playIPTV(station, lineup: searchable ? owner?.stations ?? [station] : displayed)
                        }
                    }
                }
            }.padding().localDockScrollInsets()
        }
    }

    private func savedRow(_ channel: Channel, records: [IPTVRecord]) -> some View {
        let available = IPTVRoomAddress(channel.url).map { room in
            records.contains { $0.id == room.sourceID && $0.platforms.contains { $0.id == room.platformID } }
        } ?? false
        return HStack {
            if available {
                Button { store.playing = channel } label: {
                    Label(channel.name, systemImage: "play.circle").frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading) {
                    Text(channel.name)
                    RouteLink { IPTVSettingsView() } label: { Text("来源已停用或移除，管理直播订阅").font(.caption) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { store.toggleFavorite(channel) } label: {
                Image(systemName: "heart.fill").foregroundStyle(Brand.rose).frame(width: 44, height: 44)
            }.accessibilityLabel("取消收藏")
        }.buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 7).contentPanel()
    }

    private func stationRow(_ station: IPTVStation, owner: IPTVRecord?, showSource: Bool, play: @escaping () -> Void) -> some View {
        let reference = IPTVStationReference.channel(for: station)
        let logo = Channel(name: station.name, group: station.group, url: reference.url, logo: station.logo)
        let favorite = store.isFavorite(reference)
        return HStack(spacing: 8) {
            Button(action: play) {
                HStack(spacing: 12) {
                    ChannelLogo(channel: logo, size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text([station.number, station.name].compactMap { $0 }.joined(separator: "  ")).font(.headline)
                        if showSource, let owner { Text(owner.name).font(.caption).foregroundStyle(.secondary) }
                        if let context = owner?.guideContext(for: station) {
                            IPTVGuideNow(context: context, station: station)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { store.toggleFavorite(reference) } label: {
                Image(systemName: favorite ? "heart.fill" : "heart").foregroundStyle(favorite ? Brand.rose : .secondary)
                    .frame(width: 44, height: 44)
            }.buttonStyle(.plain).accessibilityLabel(favorite ? "取消收藏" : "收藏频道")
        }.padding(.horizontal, 12).padding(.vertical, 7).contentPanel()
    }
}

private struct IPTVSourceIcon: View {
    let selection: IPTVBrowserSelection
    let size: CGFloat

    private var symbol: String {
        switch selection {
        case .source: return "dot.radiowaves.left.and.right"
        case .favorites: return "heart.fill"
        case .recent: return "clock.arrow.circlepath"
        }
    }
    private var tint: Color {
        switch selection {
        case .source: return Brand.teal
        case .favorites: return Brand.rose
        case .recent: return Brand.indigo
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct IPTVSourceSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let records: [IPTVRecord]
    let selected: IPTVBrowserSelection
    let pick: (IPTVBrowserSelection) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text("常用").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                    row(.favorites, title: "我的收藏", subtitle: "已收藏的直播频道")
                    row(.recent, title: "最近观看", subtitle: "最近播放的直播频道")
                    Text("直播订阅").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 4).padding(.top, 12)
                    ForEach(records) { record in
                        row(.source(record.id), title: record.name, subtitle: summary(record))
                    }
                    if records.isEmpty {
                        Text("暂无已启用的直播订阅").foregroundStyle(.secondary).padding(.vertical, 16)
                    }
                }
                .padding(16)
                .frame(maxWidth: Layout.settingsWidth)
                .frame(maxWidth: .infinity)
            }
            .screenBackdrop()
            .navigationTitle("选择直播来源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    private func row(_ value: IPTVBrowserSelection, title: String, subtitle: String) -> some View {
        let chosen = selected == value
        return Button { pick(value) } label: {
            HStack(spacing: 12) {
                IPTVSourceIcon(selection: value, size: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(chosen ? Brand.teal : Color.secondary.opacity(0.35))
                    .accessibilityHidden(true)
            }
            .padding(14).frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .background { TileSurface(focused: false, radius: 18) }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(chosen ? Brand.teal.opacity(0.55) : .clear, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func summary(_ record: IPTVRecord) -> String {
        var parts = ["\(record.stations.count) 个频道"]
        if !record.platforms.isEmpty { parts.append("\(record.platforms.count) 个平台") }
        if !record.format.isEmpty { parts.append(record.format) }
        return parts.joined(separator: " · ")
    }
}
#endif
