import SwiftUI
import Perception
import TVCore

/// The Manga section: what the viewer is reading and saved, then the chosen Venera source's explore pages.
struct MangaView: View {
    @State private var store = MangaStore.shared
    @Environment(Store.self) private var appStore
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        WithPerceptionTracking {
            Group {
                #if os(iOS)
                if let source = store.currentSource {
                    MangaSourceBrowse(source: source.key).id(source.key + source.revision)
                } else {
                    MangaWelcome()
                }
                #else
                if store.sources.isEmpty && store.history.isEmpty && store.favorites.isEmpty {
                    MangaWelcome()
                } else {
                    ScrollView {
                        WithPerceptionTracking {
                            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                                if !store.history.isEmpty {
                                    MangaShelfRow(title: L10n.text("Continue Reading"), comics: store.history.prefix(20).map(\.comic),
                                                  captions: Dictionary(store.history.prefix(20).map { ($0.id, MangaProgressText.short($0)) }, uniquingKeysWith: { a, _ in a }),
                                                  route: Route { AnyView(MangaLibraryView(kind: .history)) })
                                }
                                if !store.favorites.isEmpty {
                                    MangaShelfRow(title: L10n.text("Favorites"), comics: store.favorites.prefix(30).map(\.comic), showsSource: store.sources.count > 1,
                                                  route: Route { AnyView(MangaLibraryView(kind: .favorites)) })
                                }
                                if store.sources.isEmpty {
                                    EmptyResults(symbol: "books.vertical", title: L10n.text("No Comic Sources"),
                                                 message: L10n.text("Add comic sources in Settings › Comic Sources to read comics here."))
                                } else {
                                    #if os(tvOS)
                                    MangaSourceBar()
                                    #endif
                                    if let source = store.currentSource {
                                        MangaSourceBrowse(source: source.key).id(source.key + source.revision)
                                    } else {
                                        EmptyResults(symbol: "eye.slash", title: "漫画来源已隐藏", message: "可在来源管理中重新显示已安装站点。")
                                    }
                                }
                            }
                            .padding(.vertical, Layout.gutter)
                            .frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity)
                        }
                    }
                }
                #endif
            }
            .background { WithPerceptionTracking { Backdrop() } }
            .modifier(MangaNoticeBanner())
            .onAppear { store.applyHiddenSources(appStore.hiddenSources) }
            .appOnChange(of: store.sources) { _, _ in store.applyHiddenSources(appStore.hiddenSources) }
            #if os(iOS)
            .modifier(LocalSitePageTitle(title: L10n.text("Manga")))
            #else
            .tabTitle(L10n.text("Manga"))
            #endif
            #if os(macOS)
            .toolbar { WithPerceptionTracking {

                    ToolbarItemGroup {
                        if !store.sources.isEmpty {
                            RouteLink { WithPerceptionTracking { MangaSearchView() } } label: { WithPerceptionTracking { Image(systemName: "magnifyingglass") } }.accessibilityLabel(L10n.text("Search"))
                        }
                    }

             }}
            #endif
        }
    }
}

/// Nothing to read yet: sources are managed in Settings (the section shows once one is installed).
private struct MangaWelcome: View {
    #if os(tvOS)
    private let icon: CGFloat = 132, titleSize: CGFloat = 46, text: CGFloat = 28, width: CGFloat = 960
    #else
    private let icon: CGFloat = 84, titleSize: CGFloat = 24, text: CGFloat = 15, width: CGFloat = 440
    #endif
    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 20) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: icon * 0.42, weight: .bold)).foregroundStyle(Brand.accent)
                    .frame(width: icon, height: icon).background(Brand.accent.opacity(0.14), in: Circle())
                    .accessibilityHidden(true)
                Text(L10n.text("Read Comics")).font(.system(size: titleSize, weight: .bold))
                #if os(iOS)
                Text("在设置中添加漫画订阅，站点准备后即可开始阅读。")
                    .font(.system(size: text)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: width)
                #else
                Text(L10n.text("Add comic sources in Settings › Comic Sources to read comics here."))
                    .font(.system(size: text)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: width)
                #endif
                // Goes straight to the sources. On Apple TV it is also the page's only focusable control: with none, focus
                // had nowhere to land when the section opened directly, and Back did nothing.
                RouteLink {
                    WithPerceptionTracking {
                        #if os(iOS)
                        LocalMangaSettingsView()
                        #else
                        MangaSourcesView()
                        #endif
                    }
                } label: { WithPerceptionTracking { Label(L10n.text("Comic Sources"), systemImage: "books.vertical") } }
                    .controlButton(prominent: true).padding(.top, 10)
                    .accessibilityIdentifier("manga.welcome.sources")
            }
            .padding(Layout.gutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tvFocusSection()
        }
    }
}

/// The installed sources as chips; the chosen one fills the page under it.
private struct MangaSourceBar: View {
    @State private var store = MangaStore.shared
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: Layout.headerSpacing) {
                SectionHeader(title: L10n.text("Comic Sources")).padding(.horizontal, Layout.gutter)
                ChipRow {
                    HStack(spacing: 10) {
                        ForEach(store.sources) { source in
                            WithPerceptionTracking {
                                Chip(title: source.name, selected: source.key == store.currentSource?.key) { store.selectedSource = source.key }
                            }
                        }
                        #if os(tvOS)
                        RouteLink { WithPerceptionTracking { MangaSearchView() } } label: { WithPerceptionTracking { Label(L10n.text("Search"), systemImage: "magnifyingglass") } }.mangaPill()
                        #endif
                    }
                }
                .padding(.horizontal, Layout.gutter)
            }
            .tvFocusSection()
        }
    }
}

/// One source's explore pages (shelves or a grid), with its categories and ranking a tap away.
private struct MangaBrowseCategory: Identifiable {
    let id: String
    let name: String
    let param: String?
    let isSearch: Bool
}

struct MangaSourceBrowse: View {
    let source: String
    @Environment(Store.self) private var appStore
    @Environment(\.openRoute) private var openRoute
    #if os(iOS)
    @State private var showsActions = false
    @State private var refreshAfterActions = false
    @State private var hideAfterActions = false
    @State private var accountAfterActions = false
    @State private var favoritesAfterActions = false
    @State private var showsSourceSettings = false
    @State private var showsFilters = false
    @State private var query = ""
    @State private var submitted = ""
    @State private var selectedCategory: MangaBrowseCategory?
    @State private var options: [String] = []
    @State private var ranking: String?
    @AppStorage("manga.browse.landscapePosters") private var landscapePosters = false
    @Environment(\.localDockInset) private var localDockInset
    @Environment(\.openLocalHomeSources) private var openHomeSources
    #endif
    @State private var info: MangaSourceInfo?
    @State private var failure: String?
    @State private var page = 0
    @State private var shelves: [MangaShelf] = []
    @State private var loadingShelves = false
    @State private var shelfFailure: String?
    @State private var refreshRevision = 0

    var body: some View {
        WithPerceptionTracking {
            #if os(iOS)
            mobilePresentations
            #else
            browsePage
            #endif
        }
    }

    private var browsePage: some View {
        WithPerceptionTracking {
            Group {
                #if os(iOS)
                mobileBrowser
                #else
                VStack(alignment: .leading, spacing: Layout.headerSpacing) {
                    if let info {
                        #if os(tvOS)
                        header(info)
                        #else
                        phoneHeader(info)
                        #endif
                        content(info)
                    } else if let failure {
                        EmptyResults(symbol: "exclamationmark.triangle", title: L10n.text("Unable to Load"), message: failure, action: L10n.text("Try Again")) {
                            Task { await load() }
                        }
                    } else { ProgressView().frame(maxWidth: .infinity).padding(40) }
                }
                #endif
            }
            .task(id: refreshRevision) {
                if refreshRevision > 0 {
                    await MangaRuntime.shared.refreshExplore(source)
                    guard !Task.isCancelled else { return }
                    info = nil; shelves = []
                }
                await load()
            }
        }
    }

    #if os(iOS)
    private var mobilePresentations: some View {
        browsePage
            .localGlassDialog(isPresented: $showsActions, title: info?.name ?? "漫画站点", maxWidth: 460, onDismiss: completeActions) { sourceActions }
            .sheet(isPresented: $showsSourceSettings, onDismiss: { refreshRevision += 1 }) { sourceSettings }
            .localGlassDialog(isPresented: $showsFilters, title: "筛选", maxWidth: 460) { filterContent }
    }

    private func completeActions() {
        if refreshAfterActions { refreshAfterActions = false; refreshRevision += 1 }
        if hideAfterActions, let installed = MangaStore.shared.sources.first(where: { $0.key == source }) {
            hideAfterActions = false
            appStore.hiddenSources.setHidden([LocalSearchManga.site(installed)], origin: LocalSearchManga.origin, hidden: true)
            MangaStore.shared.applyHiddenSources(appStore.hiddenSources)
        }
        if accountAfterActions { accountAfterActions = false; showsSourceSettings = true }
        if favoritesAfterActions { favoritesAfterActions = false; openRoute?(Route { AnyView(MangaLibraryView(kind: .favorites)) }) }
    }

    private var sourceActions: some View {
        WithPerceptionTracking {
            ScrollView {
                WithPerceptionTracking {
                    VStack(spacing: 10) {
                        if let info, info.canSignIn || !info.cookieFields.isEmpty || info.signInPage != nil {
                            Button { accountAfterActions = true; showsActions = false } label: { Label("登录账号", systemImage: "person.crop.circle") }
                                .accessibilityIdentifier("manga.actions.account")
                        } else if info?.settings.isEmpty == false {
                            Button { accountAfterActions = true; showsActions = false } label: { Label("站点设置", systemImage: "slider.horizontal.3") }
                        }
                        Button { favoritesAfterActions = true; showsActions = false } label: { Label("漫画收藏", systemImage: "heart") }
                        Button { refreshAfterActions = true; showsActions = false } label: { Label("刷新站点", systemImage: "arrow.clockwise") }
                            .accessibilityIdentifier("manga.actions.refresh")
                        Button { hideAfterActions = true; showsActions = false } label: { Label("隐藏站点", systemImage: "eye.slash") }
                            .accessibilityIdentifier("manga.actions.hide")
                    }.buttonStyle(LocalSiteActionRowStyle()).padding(16).localDialogContentHeight()
                }
            }
        }
    }

    private var sourceSettings: some View {
        NavigationStack {
            MangaSourceSettingsView(key: source, opensWebLogin: info?.canSignIn == false && info?.cookieFields.isEmpty == true && info?.settings.isEmpty == true)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showsSourceSettings = false } } }
        }
    }

    private var filterContent: some View {
        WithPerceptionTracking {
            ScrollView {
                WithPerceptionTracking {
                    if let info {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(activeOptions(info).enumerated()), id: \.offset) { index, option in
                                WithPerceptionTracking { filterRow(option, index: index, info: info) }
                            }
                        }.padding(16).localDialogContentHeight()
                    }
                }
            }
        }
    }

    private func filterRow(_ option: MangaSourceInfo.Option, index: Int, info: MangaSourceInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(info.text(option.label)).font(.subheadline.weight(.semibold))
            MangaFlow(spacing: 8) {
                ForEach(option.choices, id: \.value) { choice in
                    WithPerceptionTracking {
                        Chip(title: info.text(choice.text), selected: options.indices.contains(index) && option.contains(choice.value, in: options[index])) {
                            if options.indices.contains(index) { options[index] = option.selecting(choice.value, in: options[index]) }
                        }
                    }
                }
            }
        }
    }
    #endif

    private func load() async {
        failure = nil
        do {
            let result = try await MangaRuntime.shared.info(source)
            guard !Task.isCancelled else { return }
            info = result
            #if os(iOS)
            if options.isEmpty { options = MangaOptionRows.defaults(activeOptions(result)) }
            #endif
        } catch { if !Task.isCancelled { failure = error.mangaMessage } }
    }

    #if os(iOS)
    private var mobileBrowser: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                WithPerceptionTracking {
                    ScrollView {
                        WithPerceptionTracking {
                            VStack(alignment: .leading, spacing: Layout.headerSpacing) {
                                Color.clear.frame(height: 0).id("manga.top")
                                if let info {
                                    mobileCategories(info)
                                    mobileResources(info)
                                } else if let failure {
                                    EmptyResults(symbol: "exclamationmark.triangle", title: L10n.text("Unable to Load"), message: failure, action: L10n.text("Try Again")) {
                                        refreshRevision += 1
                                    }
                                } else { ProgressView().frame(maxWidth: .infinity).padding(40) }
                            }.padding(.vertical, Layout.gutter)
                                .frame(maxWidth: Layout.maxWidth).frame(width: viewport.size.width, alignment: .topLeading)
                        }
                    }
                    .frame(width: viewport.size.width, height: viewport.size.height)
                    .overlay(alignment: .bottomTrailing) {
                        WithPerceptionTracking {
                            VStack(spacing: 10) {
                                if let info, !activeOptions(info).isEmpty {
                                    Button { showsFilters = true } label: { Image(systemName: "line.3.horizontal.decrease").frame(width: 44, height: 44) }
                                        .accessibilityLabel("筛选").accessibilityIdentifier("manga.filters")
                                }
                                Button { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("manga.top", anchor: .top) } } label: {
                                    Image(systemName: "arrow.up").frame(width: 44, height: 44)
                                }.accessibilityLabel("回到顶部").accessibilityIdentifier("manga.top")
                            }.font(.headline).buttonStyle(.plain)
                                .padding(6).background(.regularMaterial, in: Capsule())
                                .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
                                .localDockHitRegion().padding(16).padding(.bottom, localDockInset).localDockHitRegions()
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { mobileHeader }
        .environment(\.mangaLandscapePosters, landscapePosters)
    }

    private var mobileHeader: some View {
        WithPerceptionTracking {
            HStack(spacing: 4) {
                Button { openHomeSources?() } label: {
                    HStack(spacing: 4) {
                        Text(info?.name ?? MangaStore.shared.name(of: source)).font(.headline).lineLimit(2)
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    }.frame(minWidth: 48, idealWidth: 86, maxWidth: 132, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("选择漫画来源").accessibilityIdentifier("manga.source.open")
                Button { landscapePosters.toggle() } label: {
                    Image(systemName: landscapePosters ? "rectangle.grid.1x2" : "square.grid.2x2").frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel(landscapePosters ? "切换为竖版海报网格" : "切换为横版海报网格")
                    .accessibilityIdentifier("manga.layout")
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                    TextField("搜索当前站点", text: Binding(get: { query }, set: { value in
                        query = value
                        if value.isEmpty, !submitted.isEmpty {
                            submitted = ""
                            if let info { options = MangaOptionRows.defaults(activeOptions(info)) }
                        }
                    })).font(.subheadline).submitLabel(.search).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .onSubmit {
                            guard let info, info.canSearch else { return }
                            submitted = query.trimmingCharacters(in: .whitespacesAndNewlines)
                            options = MangaOptionRows.defaults(activeOptions(info))
                        }.disabled(info?.canSearch != true).accessibilityIdentifier("manga.search")
                    if !query.isEmpty {
                        Button {
                            query = ""; submitted = ""
                            if let info { options = MangaOptionRows.defaults(activeOptions(info)) }
                        } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(minWidth: 28, minHeight: 44) }
                            .buttonStyle(.plain).accessibilityLabel("清除漫画搜索")
                    }
                }.padding(.horizontal, 9).frame(minWidth: 98, minHeight: 44)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                Button { showsActions = true } label: {
                    Image(systemName: "ellipsis").rotationEffect(.degrees(90)).frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("漫画站点更多操作").accessibilityIdentifier("manga.source.menu")
            }.padding(.horizontal, 16).padding(.vertical, 8).background(.regularMaterial)
        }
    }

    private func categories(_ info: MangaSourceInfo) -> [MangaBrowseCategory] {
        info.categoryParts.enumerated().flatMap { partIndex, part in
            part.categories.enumerated().map { index, name in
                MangaBrowseCategory(id: "category.\(partIndex).\(index)", name: name,
                                    param: part.params.indices.contains(index) ? part.params[index] : nil,
                                    isSearch: part.itemType == "search")
            }
        }
    }

    private func mobileCategories(_ info: MangaSourceInfo) -> some View {
        let categories = categories(info)
        let selected = submitted.isEmpty ? selectedCategory?.id ?? ranking.map { "ranking." + $0 } ?? "explore.\(page)" : ""
        let items = info.explore.indices.map { SourceStrip.Item(id: "explore.\($0)", name: info.text(info.explore[$0].title)) }
            + categories.map { SourceStrip.Item(id: $0.id, name: info.text($0.name)) }
            + info.rankingOptions.map { SourceStrip.Item(id: "ranking." + $0.value, name: info.text($0.text)) }
        return SourceStrip(items: items, selection: selected) { key in
            guard key != selected else { return }
            query = ""; submitted = ""; selectedCategory = nil; ranking = nil
            if key.hasPrefix("explore.") { page = Int(key.dropFirst("explore.".count)) ?? 0; shelves = [] }
            else if key.hasPrefix("ranking.") { ranking = String(key.dropFirst("ranking.".count)) }
            else { selectedCategory = categories.first { $0.id == key } }
            options = MangaOptionRows.defaults(activeOptions(info))
        }.padding(.horizontal, Layout.gutter)
    }

    private func activeOptions(_ info: MangaSourceInfo) -> [MangaSourceInfo.Option] {
        if !submitted.isEmpty || selectedCategory?.isSearch == true { return info.searchOptions }
        if selectedCategory != nil { return info.categoryOptions }
        return []
    }

    @ViewBuilder private func mobileResources(_ info: MangaSourceInfo) -> some View {
        if !submitted.isEmpty {
            MangaComicGrid(load: { cursor in
                try await MangaRuntime.shared.search(source, keyword: submitted, options: info.searchArguments(options), cursor: cursor)
            }, id: "search|\(source)|\(submitted)|\(options)|\(refreshRevision)")
        } else if let category = selectedCategory {
            MangaComicGrid(load: { cursor in
                if category.isSearch {
                    return try await MangaRuntime.shared.search(source, keyword: category.param ?? category.name, options: info.searchArguments(options), cursor: cursor)
                }
                return try await MangaRuntime.shared.category(source, name: category.name, param: category.param, options: options, cursor: cursor)
            }, id: "\(source)|\(category.id)|\(options)|\(refreshRevision)")
        } else if let ranking {
            MangaComicGrid(load: { cursor in try await MangaRuntime.shared.ranking(source, option: ranking, cursor: cursor) }, id: "\(source)|ranking|\(ranking)|\(refreshRevision)")
        } else { content(info) }
    }
    #endif

    #if !os(tvOS)
    /// As Watch Now's Recommendations: a heading, then the source as a glass capsule that opens its categories and a
    /// switch beside it for another source; a source with several explore pages lists them under it.
    private func phoneHeader(_ info: MangaSourceInfo) -> some View {
        let hasCategories = !info.categoryParts.isEmpty || !info.rankingOptions.isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Browse Comics")).font(.system(size: DiscoverLayout.heading, weight: .semibold)).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                Button {
                    if hasCategories { openRoute?(Route { AnyView(MangaCategoriesView(source: source)) }) }
                } label: {
                    HStack(spacing: 6) {
                        Text(info.name).lineLimit(1)
                        if hasCategories { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).frame(height: SourceStrip.controlSize)
                    .glassOrFill(.regular.interactive(), Color.primary.opacity(0.06), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("manga.source.open")
                MangaSourceSwitch()
                #if os(iOS)
                Spacer(minLength: 0)
                Button { showsActions = true } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                    .buttonStyle(.plain).accessibilityLabel("漫画站点更多操作").accessibilityIdentifier("manga.source.menu")
                #endif
            }
            if info.explore.count > 1 {
                SourceStrip(items: info.explore.indices.map { .init(id: "\($0)", name: info.text(info.explore[$0].title)) }, selection: "\(page)") { page = Int($0) ?? 0 }
            }
        }
        .padding(.horizontal, DiscoverLayout.gutter)
    }
    #endif

    /// Where a shelf's heading leads: the source's own "more" link, else the shelf as a grid.
    private func shelfRoute(_ shelf: MangaShelf, _ info: MangaSourceInfo) -> Route {
        let title = info.text(shelf.title), source = source, comics = shelf.comics
        if let jump = shelf.viewMore { return Route { AnyView(MangaJumpView(source: source, jump: jump, title: title)) } }
        return Route { AnyView(MangaShelfPage(title: title, comics: comics)) }
    }

    @ViewBuilder private func header(_ info: MangaSourceInfo) -> some View {
        let hasCategories = !info.categoryParts.isEmpty || !info.rankingOptions.isEmpty
        if info.explore.count > 1 || hasCategories {
            ChipRow {
                HStack(spacing: 10) {
                    if info.explore.count > 1 {
                        ForEach(Array(info.explore.enumerated()), id: \.offset) { index, item in
                            WithPerceptionTracking {
                                Chip(title: info.text(item.title), selected: index == page) { page = index }
                            }
                        }
                    }
                    if hasCategories {
                        RouteLink { WithPerceptionTracking { MangaCategoriesView(source: source) } } label: {
                            WithPerceptionTracking {
                                Label(info.text(info.categoryTitle ?? "").isEmpty ? L10n.text("Categories") : info.text(info.categoryTitle ?? ""), systemImage: "square.grid.2x2")
                            }
                        }
                        .mangaPill()
                    }
                }
            }
            .padding(.horizontal, Layout.gutter)
            .tvFocusSection()
        }
    }

    @ViewBuilder private func content(_ info: MangaSourceInfo) -> some View {
        if info.explore.isEmpty {
            EmptyResults(symbol: "magnifyingglass", title: L10n.text("Search This Source"),
                         message: L10n.text("This source has no explore page. Search it, or open its categories."))
        } else {
            let item = info.explore[min(page, info.explore.count - 1)]
            switch item.type {
            case "multiPartPage", "singlePageWithMultiPart":
                VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                    if loadingShelves && shelves.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(40) }
                    if let shelfFailure {
                        EmptyResults(symbol: "exclamationmark.triangle", title: L10n.text("Unable to Load"), message: shelfFailure, action: L10n.text("Try Again")) {
                            Task { await loadShelves() }
                        }
                    }
                    ForEach(shelves) { shelf in
                        WithPerceptionTracking {
                            MangaShelfRow(title: info.text(shelf.title), comics: shelf.comics, route: shelfRoute(shelf, info))
                        }
                    }
                }
                .task(id: "\(page)|\(refreshRevision)") { await loadShelves() }
            case "mixed":
                MangaMixedPage(source: source, page: page).id("\(page)|\(refreshRevision)")
            default:
                MangaComicGrid(load: { cursor in try await MangaRuntime.shared.explore(source, page: page, cursor: cursor).page }, id: "\(source)-\(page)-\(refreshRevision)")
            }
        }
    }

    private func loadShelves() async {
        let revision = refreshRevision, selectedPage = page
        loadingShelves = true; shelfFailure = nil
        defer { if revision == refreshRevision, selectedPage == page { loadingShelves = false } }
        do {
            let result = try await MangaRuntime.shared.explore(source, page: page, cursor: nil)
            await MangaImages.shared.prepareCovers(source: source, urls: result.shelves.flatMap { $0.comics.map(\.cover) })
            guard !Task.isCancelled, revision == refreshRevision, selectedPage == page else { return }
            shelves = result.shelves
        } catch { if !Task.isCancelled, revision == refreshRevision, selectedPage == page { shelves = []; shelfFailure = error.mangaMessage } }
    }
}

/// A "mixed" explore page: shelves and loose comics, page by page.
private struct MangaMixedPage: View {
    let source: String
    let page: Int
    @State private var shelves: [MangaShelf] = []
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                ForEach(shelves) { shelf in
                    WithPerceptionTracking {
                        MangaShelfRow(title: shelf.title, comics: shelf.comics, route: Route { AnyView(MangaShelfPage(title: shelf.title, comics: shelf.comics)) })
                    }
                }
                MangaComicGrid(load: { cursor in
                    let result = try await MangaRuntime.shared.explore(source, page: page, cursor: cursor ?? .page(1))
                    if cursor == nil { await MainActor.run { shelves = result.shelves } }
                    return result.page
                }, id: "\(source)-mixed-\(page)")
            }
        }
    }
}

/// Where a shelf's See All or a tag leads: a search or a category of the source.
struct MangaJumpView: View {
    let source: String
    let jump: MangaJump
    let title: String
    var body: some View {
        WithPerceptionTracking {
            switch jump {
            case .search(let keyword): MangaSourceResults(source: source, keyword: keyword)
            case .category(let name, let param): MangaCategoryComicsView(source: source, category: name, param: param, title: title.isEmpty ? name : title)
            }
        }
    }
}

// MARK: - Categories

struct MangaCategoriesView: View {
    let source: String
    @State private var info: MangaSourceInfo?
    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                WithPerceptionTracking {
                    VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                        if let info {
                            if !info.rankingOptions.isEmpty {
                                RouteLink { WithPerceptionTracking { MangaRankingView(source: source) } } label: { WithPerceptionTracking { Label(L10n.text("Ranking"), systemImage: "chart.bar.fill") } }
                                    .controlButton().padding(.horizontal, Layout.gutter)
                            }
                            ForEach(Array(info.categoryParts.enumerated()), id: \.offset) { _, part in
                                WithPerceptionTracking { categoryPart(part, info: info) }
                            }
                        } else { ProgressView().frame(maxWidth: .infinity).padding(40) }
                    }
                    .padding(.vertical, Layout.gutter)
                    .frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity)
                }
            }
            .background { WithPerceptionTracking { Backdrop() } }
            .screenTitle(title)
            .task { info = try? await MangaRuntime.shared.info(source) }
        }
    }

    private var title: String {
        guard let info else { return L10n.text("Categories") }
        let title = info.text(info.categoryTitle ?? "")
        return title.isEmpty ? L10n.text("Categories") : title
    }

    private func categoryPart(_ part: MangaSourceInfo.CategoryPart, info: MangaSourceInfo) -> some View {
        VStack(alignment: .leading, spacing: Layout.headerSpacing) {
            if !part.name.isEmpty { SectionHeader(title: info.text(part.name)) }
            MangaFlow(spacing: 10) {
                ForEach(Array(part.categories.enumerated()), id: \.offset) { index, name in
                    WithPerceptionTracking { categoryLink(part, index: index, name: name, info: info) }
                }
            }
        }
        .padding(.horizontal, Layout.gutter)
        .tvFocusSection()
    }

    private func categoryLink(_ part: MangaSourceInfo.CategoryPart, index: Int, name: String, info: MangaSourceInfo) -> some View {
        let param = part.params.indices.contains(index) ? part.params[index] : nil
        return RouteLink {
            WithPerceptionTracking {
                if part.itemType == "search" { MangaSourceResults(source: source, keyword: param ?? name) }
                else { MangaCategoryComicsView(source: source, category: name, param: param, title: info.text(name)) }
            }
        } label: { WithPerceptionTracking { Text(info.text(name)).lineLimit(1) } }
        .mangaPill()
    }
}

/// Option chips of a source (sort order, time range), one row per option.
struct MangaOptionRows: View {
    let options: [MangaSourceInfo.Option]
    let info: MangaSourceInfo
    @Binding var values: [String]
    var body: some View {
        WithPerceptionTracking {
            #if os(tvOS)
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                WithPerceptionTracking {
                    ChipRow {
                        HStack(spacing: 10) {
                            ForEach(option.choices, id: \.value) { choice in
                                WithPerceptionTracking {
                                    Chip(title: info.text(choice.text), selected: values.indices.contains(index) && option.contains(choice.value, in: values[index])) {
                                        if values.indices.contains(index) { values[index] = option.selecting(choice.value, in: values[index]) }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Layout.gutter)
                    .tvFocusSection()
                }
            }
            #else
            // As a source's category filters on Watch Now: one glass "Sort: Popular" chip per option, each a menu.
            if !options.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    CategoryFilterBar(filters: filters, choices: Dictionary(uniqueKeysWithValues: values.enumerated().map { ("\($0.offset)", $0.element) })) { next in
                        for index in options.indices where values.indices.contains(index) {
                            if let value = next["\(index)"] { values[index] = value }
                        }
                    }
                    ForEach(Array(options.enumerated()).filter { $0.element.type == "multi-select" }, id: \.offset) { index, option in
                        WithPerceptionTracking {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(info.text(option.label)).font(.subheadline.weight(.medium))
                                MangaFlow(spacing: 8) {
                                    ForEach(option.choices, id: \.value) { choice in
                                        WithPerceptionTracking {
                                            Chip(title: info.text(choice.text), selected: values.indices.contains(index) && option.contains(choice.value, in: values[index])) {
                                                if values.indices.contains(index) { values[index] = option.selecting(choice.value, in: values[index]) }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }.padding(.horizontal, Layout.gutter)
            }
            #endif
        }
    }

    private var filters: [CategoryFilter] {
        options.enumerated().filter { $0.element.type != "multi-select" }.map { index, option in
            CategoryFilter(key: "\(index)", name: info.text(option.label),
                           options: option.choices.map { CategoryFilter.Option(name: info.text($0.text), value: $0.value) },
                           initial: option.defaultValue ?? option.choices.first?.value)
        }
    }

    static func defaults(_ options: [MangaSourceInfo.Option]) -> [String] { options.map(\.initialValue) }
}

struct MangaCategoryComicsView: View {
    let source: String
    let category: String
    let param: String?
    let title: String
    @State private var info: MangaSourceInfo?
    @State private var values: [String] = []
    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                WithPerceptionTracking {
                    VStack(alignment: .leading, spacing: Layout.headerSpacing) {
                        if let info {
                            MangaOptionRows(options: info.categoryOptions, info: info, values: $values)
                            MangaComicGrid(load: { cursor in
                                try await MangaRuntime.shared.category(source, name: category, param: param, options: values, cursor: cursor)
                            }, id: values.joined(separator: "|"))
                        }
                    }
                    .padding(.vertical, Layout.gutter)
                    .frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity)
                }
            }
            .background { WithPerceptionTracking { Backdrop() } }
            .screenTitle(title)
            .task {
                info = try? await MangaRuntime.shared.info(source)
                if values.isEmpty, let info { values = MangaOptionRows.defaults(info.categoryOptions) }
            }
        }
    }
}

struct MangaRankingView: View {
    let source: String
    @State private var info: MangaSourceInfo?
    @State private var option = ""
    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                WithPerceptionTracking {
                    VStack(alignment: .leading, spacing: Layout.headerSpacing) {
                        if let info {
                            #if os(tvOS)
                            ChipRow {
                                HStack(spacing: 10) {
                                    ForEach(info.rankingOptions, id: \.value) { choice in
                                        WithPerceptionTracking {
                                            Chip(title: info.text(choice.text), selected: choice.value == option) { option = choice.value }
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, Layout.gutter)
                            #else
                            SourceStrip(items: info.rankingOptions.map { .init(id: $0.value, name: info.text($0.text)) }, selection: option) { option = $0 }
                                .padding(.horizontal, Layout.gutter)
                            #endif
                            if !option.isEmpty {
                                MangaComicGrid(load: { cursor in try await MangaRuntime.shared.ranking(source, option: option, cursor: cursor) }, id: option)
                            }
                        }
                    }
                    .padding(.vertical, Layout.gutter)
                    .frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity)
                }
            }
            .background { WithPerceptionTracking { Backdrop() } }
            .screenTitle(L10n.text("Ranking"))
            .task {
                info = try? await MangaRuntime.shared.info(source)
                if option.isEmpty { option = info?.rankingOptions.first?.value ?? "" }
            }
        }
    }
}

// MARK: - Search

/// Searches every installed source at once: one shelf per source, best first.
struct MangaSearchView: View {
    @State private var store = MangaStore.shared
    @State private var query = ""
    @State private var submitted = ""
    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                WithPerceptionTracking {
                    VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                        if submitted.isEmpty {
                            EmptyResults(symbol: "magnifyingglass", title: L10n.text("Search Comics"),
                                         message: L10n.text("Searches all %d installed sources.", store.sources.count))
                        } else {
                            ForEach(store.sources) { source in
                                WithPerceptionTracking {
                                    MangaSearchShelf(source: source, keyword: submitted)
                                }
                            }
                        }
                    }
                    .padding(.vertical, Layout.gutter)
                    .frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity)
                }
            }
            .background { WithPerceptionTracking { Backdrop() } }
            .catalogSearchable(text: $query, prompt: L10n.text("Comic title or author"))
            .onSubmit(of: .search) { submitted = query.trimmingCharacters(in: .whitespacesAndNewlines) }
            #if os(tvOS)
            // The tvOS keyboard has no return key that submits: search as the text settles.
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(900))
                if !Task.isCancelled { submitted = query.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            #endif
            .screenTitle(L10n.text("Search Comics"))
            .task {
            }
        }
    }
}

private struct MangaSearchShelf: View {
    let source: MangaInstalledSource
    let keyword: String
    @State private var comics: [MangaComic]?
    @State private var failure: String?
    var body: some View {
        WithPerceptionTracking {
            Group {
                if let comics, !comics.isEmpty {
                    MangaShelfRow(title: source.name, comics: comics,
                                  route: Route { [source, keyword] in AnyView(MangaSourceResults(source: source.key, keyword: keyword)) })
                } else if comics == nil, failure == nil {
                    HStack(spacing: 10) { Text(source.name).font(.headline); ProgressView() }.padding(.horizontal, Layout.gutter)
                } else {
                    HStack(spacing: 8) {
                        Text(source.name).font(.headline)
                        Text(failure ?? L10n.text("No results")).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, Layout.gutter)
                }
            }
            .task(id: keyword) {
                comics = nil; failure = nil
                do {
                    let info = try await MangaRuntime.shared.info(source.key)
                    guard info.canSearch else { comics = []; return }
                    let page = try await MangaRuntime.shared.search(source.key, keyword: keyword, options: info.searchArguments(MangaOptionRows.defaults(info.searchOptions)), cursor: nil)
                    await MangaImages.shared.prepareCovers(source: source.key, urls: page.comics.map(\.cover))
                    comics = page.comics
                } catch { failure = error.mangaMessage }
            }
        }
    }
}

/// One source's search results, with its search options.
struct MangaSourceResults: View {
    let source: String
    let keyword: String
    @State private var info: MangaSourceInfo?
    @State private var values: [String] = []
    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                WithPerceptionTracking {
                    VStack(alignment: .leading, spacing: Layout.headerSpacing) {
                        if let info {
                            MangaOptionRows(options: info.searchOptions, info: info, values: $values)
                            MangaComicGrid(load: { cursor in
                                try await MangaRuntime.shared.search(source, keyword: keyword, options: info.searchArguments(values), cursor: cursor)
                            }, id: keyword + values.joined(separator: "|"))
                        }
                    }
                    .padding(.vertical, Layout.gutter)
                    .frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity)
                }
            }
            .background { WithPerceptionTracking { Backdrop() } }
            .screenTitle(keyword)
            .task {
                info = try? await MangaRuntime.shared.info(source)
                if values.isEmpty, let info { values = MangaOptionRows.defaults(info.searchOptions) }
            }
        }
    }
}

// MARK: - Library

struct MangaLibraryView: View {
    enum Kind { case favorites, history }
    let kind: Kind
    @State private var store = MangaStore.shared
    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                WithPerceptionTracking {
                    LazyVGrid(columns: MangaLayout.columns, alignment: .leading, spacing: Layout.gridRowSpacing) {
                        WithPerceptionTracking {
                            switch kind {
                            case .favorites:
                                ForEach(store.favorites) { favorite in
                                    WithPerceptionTracking {
                                        MangaComicLink(comic: favorite.comic, showsSource: true)
                                            .contextMenu { WithPerceptionTracking { Button(L10n.text("Remove from Favorites"), systemImage: "heart.slash", role: .destructive) { store.toggleFavorite(favorite.comic) } } }
                                    }
                                }
                            case .history:
                                ForEach(store.history) { progress in
                                    WithPerceptionTracking {
                                        MangaComicLink(comic: progress.comic, caption: MangaProgressText.short(progress))
                                            .contextMenu { WithPerceptionTracking { Button(L10n.text("Remove from History"), systemImage: "trash", role: .destructive) { store.forget(progress) } } }
                                    }
                                }
                            }
                        }
                    }
                    .padding(Layout.gutter)
                    .frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity)
                }
            }
            .background { WithPerceptionTracking { Backdrop() } }
            .screenTitle(kind == .favorites ? L10n.text("Favorites") : L10n.text("Continue Reading"))
            #if !os(tvOS)
            .toolbar { WithPerceptionTracking {

                    if kind == .history, !store.history.isEmpty {
                        Button(L10n.text("Clear"), role: .destructive) { store.clearHistory() }
                    }

             }}
            #endif
        }
    }
}

enum MangaProgressText {
    static func short(_ progress: MangaLibrary.Progress) -> String {
        let page = L10n.text("p. %d", progress.page + 1)
        return progress.chapterTitle.isEmpty ? page : "\(progress.chapterTitle) · \(page)"
    }
}

/// Wrapping rows of chips.
struct MangaFlow: SwiftUI.Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.items.isEmpty, current.width + spacing + size.width > width { rows.append(current); current = ([], 0, 0) }
            current.width += (current.items.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.items.append(index)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

#if !os(tvOS)
/// The switch beside the source, as Watch Now's: another installed source (they are managed in Settings).
private struct MangaSourceSwitch: View {
    @State private var store = MangaStore.shared
    var body: some View {
        WithPerceptionTracking {
            Menu {
                WithPerceptionTracking {
                    Picker(L10n.text("Comic Sources"), selection: Binding(get: { store.currentSource?.key ?? "" }, set: { store.selectedSource = $0 })) {
                        ForEach(store.visibleSources) { perceptionArgument0 in WithPerceptionTracking { Text(perceptionArgument0.name).tag(perceptionArgument0.key) } }
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                WithPerceptionTracking {
                    Image(systemName: "arrow.left.arrow.right").font(.subheadline.weight(.semibold))
                        .frame(width: SourceStrip.controlSize, height: SourceStrip.controlSize)
                        .glassOrFill(.regular.interactive(), Color.primary.opacity(0.06), in: Circle())
                        .contentShape(Circle())
                }
            }
            .menuStyle(.button).buttonStyle(.plain).tint(.primary)
            .accessibilityLabel(L10n.text("Comic Sources"))
            .accessibilityIdentifier("manga.source.switch")
        }
    }
}
#endif
