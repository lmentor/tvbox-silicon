#if os(iOS)
import SwiftUI
import Perception
import TVCore

/// Capability detection belongs to the owning source, including after suspension.
struct LocalCurrentSiteWebsiteAction: View {
    let site: Site
    let origin: URL
    let jarURL: URL?
    let open: () -> Void
    @State private var available = false
    var body: some View {
        Group {
            if available {
                Button(action: open) { Label("站点设置", systemImage: "globe") }
                    .accessibilityIdentifier("home.source.website")
            }
        }
        .task(id: site) {
            guard site.hasSiteSettings else { available = false; return }
            let url = await CatPawOpen.siteSettings(site: site, origin: origin, jarURL: jarURL)
            guard !Task.isCancelled else { return }
            available = url != nil
        }
    }
}

struct LocalHiddenSourceChoices: View {
    @Environment(Store.self) private var store
    let group: LocalSourceGroup
    private var sites: [Site] {
        store.subscription?.sites.filter { !$0.isBuiltIn && !$0.hidden && store.localSourceGroup(for: $0) == group } ?? []
    }
    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text("勾选的站点会显示在来源列表和默认搜索中。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let config = store.subscription {
                        Button("显示全部") { store.hiddenSources.setHidden(sites, origin: config.origin, hidden: false) }
                        ForEach(sites) { site in
                            let hidden = store.hiddenSources.contains(site, origin: config.origin)
                            Button { store.hiddenSources.setHidden([site], origin: config.origin, hidden: !hidden) } label: {
                                HStack {
                                    Text(SourceLabel(site.name).text).frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: hidden ? "circle" : "checkmark.circle.fill")
                                }
                            }.accessibilityValue(hidden ? "已隐藏" : "已显示")
                                .accessibilityIdentifier("sources.hidden.row." + site.key)
                        }
                    }
                    if sites.isEmpty { Text("暂无站点").foregroundStyle(.secondary) }
                }.buttonStyle(LocalSiteActionRowStyle()).padding(16).localDialogContentHeight()
            }
        }
    }
}

struct LocalHiddenMangaSources: View {
    @Environment(Store.self) private var store
    @State private var manga = MangaStore.shared
    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                LazyVStack(spacing: 10) {
                    Text("勾选的已安装漫画站点会显示在来源列表和默认搜索中。")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(manga.sources) { source in
                        let site = LocalSearchManga.site(source)
                        let hidden = store.hiddenSources.contains(site, origin: LocalSearchManga.origin)
                        Button { store.hiddenSources.setHidden([site], origin: LocalSearchManga.origin, hidden: !hidden) } label: {
                            HStack { Text(source.name); Spacer(); Image(systemName: hidden ? "circle" : "checkmark.circle.fill") }
                        }.accessibilityValue(hidden ? "已隐藏" : "已显示")
                    }
                    if manga.sources.isEmpty { Text("尚未安装漫画站点").foregroundStyle(.secondary) }
                }.buttonStyle(LocalSiteActionRowStyle()).padding(16).localDialogContentHeight()
            }
        }
    }
}
#endif
