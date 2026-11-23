#if os(iOS)
import SwiftUI
import Perception
import TVCore

/// The ordinary, home and index detail pages share one grouping/order/layout
/// presentation. Episode identity and playback order remain the source's values.
struct LocalCatalogEpisodePanel<Metadata: View, EpisodeContent: View>: View {
    let input: LocalCatalogEpisodeSnapshot.Input
    let owner: String
    let loading: Bool
    @ViewBuilder let metadata: () -> Metadata
    @ViewBuilder let episode: (LocalCatalogDetailEpisode, Bool) -> EpisodeContent
    @AppStorage("episodesReversed") private var reversesEpisodes = false
    @State private var selectedGroup = 0
    @State private var groupOwner: String?
    @State private var list = false
    @State private var prepared: LocalCatalogEpisodeSnapshot?

    var body: some View {
        WithPerceptionTracking {
            let snapshot = prepared?.input == input ? prepared : nil
            let entries = snapshot?.entries ?? []
            let ordered = snapshot?.ordered ?? []
            let count = (input.episodes.count + LocalCatalogDetailRules.groupSize - 1) / LocalCatalogDetailRules.groupSize
            let group = groupOwner == owner ? min(selectedGroup, max(0, count - 1)) : 0
            let visible = LocalCatalogDetailRules.page(ordered, group: group, descending: reversesEpisodes).map { entries[$0.index] }
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text("剧集").font(.headline)
                        Text("\(input.episodes.count) 集").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        if count > 1 {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 5) {
                                    ForEach(0..<count, id: \.self) { index in
                                        let start = index * LocalCatalogDetailRules.groupSize + 1
                                        let end = min((index + 1) * LocalCatalogDetailRules.groupSize, input.episodes.count)
                                        Button { groupOwner = owner; selectedGroup = index } label: {
                                            Text(start == end ? "\(start)" : "\(start)-\(end)")
                                                .font(.system(size: 11)).monospacedDigit().padding(.horizontal, 10).frame(minHeight: 44)
                                                .foregroundStyle(index == group ? Brand.accent : Color.secondary)
                                                .background(index == group ? Brand.accent.opacity(0.1) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                                                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(index == group ? Brand.accent.opacity(0.45) : Color.primary.opacity(0.12), lineWidth: 0.5) }
                                        }.buttonStyle(.plain).accessibilityLabel("剧集分段 \(start) 到 \(end)")
                                            .accessibilityAddTraits(index == group ? .isSelected : [])
                                            .accessibilityIdentifier("detail.episodeGroup.\(index)")
                                    }
                                }
                            }
                        } else { Spacer(minLength: 0) }
                    }
                    HStack(spacing: 4) {
                        metadata()
                        Spacer(minLength: 0)
                        if input.episodes.count > 1 {
                            Button { reversesEpisodes.toggle() } label: {
                                Label(reversesEpisodes ? "倒序" : "正序", systemImage: reversesEpisodes ? "arrow.up" : "arrow.down")
                                    .font(.system(size: 11)).padding(.horizontal, 8).frame(minHeight: 44)
                            }.buttonStyle(.plain).accessibilityLabel(reversesEpisodes ? "切换为正序" : "切换为倒序")
                                .accessibilityIdentifier("episodes.reverse")
                        }
                        Button { list.toggle() } label: {
                            Label(list ? "缩略图" : "列表", systemImage: list ? "rectangle.stack" : "list.bullet")
                                .font(.system(size: 11)).padding(.horizontal, 8).frame(minHeight: 44)
                                .foregroundStyle(list ? Brand.accent : Color.primary)
                        }.buttonStyle(.plain).accessibilityLabel(list ? "显示剧集缩略图" : "显示默认剧集列表")
                            .accessibilityIdentifier("detail.episodes.layout")
                    }
                }
                if loading {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在解析播放地址…").font(.system(size: 12)).foregroundStyle(.secondary) }
                        .accessibilityElement(children: .combine)
                }
                if snapshot == nil {
                    ProgressView().frame(maxWidth: .infinity).frame(height: 80)
                } else if list {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10, alignment: .top)], spacing: 10) {
                        ForEach(visible) { value in WithPerceptionTracking { episode(value, true) } }
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 16) {
                            ForEach(visible) { value in WithPerceptionTracking { episode(value, false) } }
                        }.padding(.vertical, 2)
                    }.id("\(owner):\(group):\(reversesEpisodes)")
                }
            }
            .task(id: input) {
                guard prepared?.input != input else { return }
                guard let value = await LocalCatalogEpisodeSnapshot.prepare(input), !Task.isCancelled else { return }
                prepared = value
            }
            .appOnChange(of: owner) { _, value in groupOwner = value; selectedGroup = 0 }
            .accessibilityIdentifier("detail.episodes")
        }
    }
}
#endif
