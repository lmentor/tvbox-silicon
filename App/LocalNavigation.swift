import SwiftUI
import Perception
import TVCore

#if os(iOS)
import UIKit
private struct LocalDockKey: EnvironmentKey { static let defaultValue = false }
private struct LocalDockInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct LocalDockTopKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }
private struct LocalHTMLDockClearanceKey: EnvironmentKey { static let defaultValue: CGFloat = 68 }
private struct LocalDockVisibleKey: EnvironmentKey { static let defaultValue = true }
private struct LocalHTMLDockHiddenKey: EnvironmentKey { static let defaultValue = Binding.constant(false) }
private struct LocalDockScrollEnabledKey: EnvironmentKey { static let defaultValue = false }
private struct LocalDockActivityKey: EnvironmentKey { static let defaultValue: (@MainActor @Sendable (UUID, Bool) -> Void)? = nil }
private struct LocalPageActiveKey: EnvironmentKey { static let defaultValue = true }
private struct LocalHomeSourcePanelKey: EnvironmentKey { static let defaultValue: (@MainActor @Sendable () -> Void)? = nil }
extension EnvironmentValues {
    var localDockScrollEnabled: Bool {
        get { self[LocalDockScrollEnabledKey.self] }
        set { self[LocalDockScrollEnabledKey.self] = newValue }
    }
    var localDockActivity: (@MainActor @Sendable (UUID, Bool) -> Void)? {
        get { self[LocalDockActivityKey.self] }
        set { self[LocalDockActivityKey.self] = newValue }
    }
    var localDockVisible: Bool {
        get { self[LocalDockVisibleKey.self] }
        set { self[LocalDockVisibleKey.self] = newValue }
    }
    var localHTMLDockHidden: Binding<Bool> {
        get { self[LocalHTMLDockHiddenKey.self] }
        set { self[LocalHTMLDockHiddenKey.self] = newValue }
    }
    var openLocalHomeSources: (@MainActor @Sendable () -> Void)? {
        get { self[LocalHomeSourcePanelKey.self] }
        set { self[LocalHomeSourcePanelKey.self] = newValue }
    }
    var localDockInset: CGFloat {
        get { self[LocalDockInsetKey.self] }
        set { self[LocalDockInsetKey.self] = newValue }
    }
    /// The reserved dock's top in global coordinates; pushed and full-bleed
    /// pages can have different safe-area origins but share this boundary.
    var localDockTop: CGFloat? {
        get { self[LocalDockTopKey.self] }
        set { self[LocalDockTopKey.self] = newValue }
    }
    /// Full dock clearance, including the music strip, even while the dock is hidden.
    var localHTMLDockClearance: CGFloat {
        get { self[LocalHTMLDockClearanceKey.self] }
        set { self[LocalHTMLDockClearanceKey.self] = newValue }
    }
    var isLocalPageActive: Bool {
        get { self[LocalPageActiveKey.self] }
        set { self[LocalPageActiveKey.self] = newValue }
    }
    var usesLocalDock: Bool {
        get { self[LocalDockKey.self] }
        set { self[LocalDockKey.self] = newValue }
    }
}

/// A stable stack per visited page. Switching tabs never destroys an in-flight detail or the music queue.
struct LocalAppNavigation: View {
    @Environment(Store.self) private var store
    @State private var visited: Set<AppSection> = [.home]
    @State private var sourcePanel: LocalHomeSourceKind?
    @State private var sourcePanelBlocksInput = false
    @State private var pickedSites: [AppSection: Site] = [:]
    @State private var manga = MangaStore.shared
    @State private var metadataRevision = TMDBServiceSettings.identity
    @State private var keyboardVisible = false
    @State private var dockHiddenByScroll = false
    @State private var activeScrollObservers: Set<UUID> = []
    @State private var htmlDockHidden = false
    @State private var restoredDestination = false
    @State private var preparedHomeSource = false
    @State private var homeRevision = 0
    @State private var homeResetID: UUID?
    @State private var previousHome: LocalHomeActionTarget?
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(LocalHTMLHomeStore.key) private var htmlHomeData = Data()
    @AppStorage(LocalHomeAction.enabledKey) private var homeActionEnabled = false
    @AppStorage(LocalHomeAction.modeKey) private var homeAction = LocalHomeAction.previous
    @AppStorage(LocalHomeAction.fixedKey) private var fixedHomeData = Data()
    @AppStorage(LocalDockPreferences.history) private var showsHistory = true
    @AppStorage(LocalDockPreferences.live) private var showsLive = true
    @AppStorage(LocalDockPreferences.music) private var showsMusic = true
    let page: (AppSection) -> AnyView
    private var entries: [AppSection] {
        var visible: [AppSection] = [.home]
        if showsHistory { visible.append(.history) }
        if showsLive { visible.append(.live) }
        if showsMusic { visible.append(.music) }
        visible.append(.settings)
        return visible
    }
    private let accessories: [AppSection] = [.search, .push]
    private var current: AppSection {
        switch store.section {
        case .discover: .home
        case .more: .settings
        default: store.section
        }
    }
    private var htmlHomeSelected: Bool {
        _ = htmlHomeData
        return current == .home && LocalHTMLHomeStore.load().active != nil
    }
    private var dockVisible: Bool { !keyboardVisible && !dockHiddenByScroll && !(htmlHomeSelected && htmlDockHidden) }

    var body: some View {
        WithPerceptionTracking {
            GeometryReader { viewport in
                WithPerceptionTracking {
                    let metrics = LocalDockLayout.metrics(containerWidth: viewport.size.width, mainCount: entries.count, accessoryCount: accessories.count)
                    let showsMusicStrip = store.music.showsStrip(videoPlaying: store.playing != nil)
                    let dockInset = metrics.inset(showsMusic: showsMusicStrip)
                    ZStack {
                        ForEach(Array(visited).sorted { $0.rawValue < $1.rawValue }) { section in
                            WithPerceptionTracking {
                                RouteStack(reset: section == .home ? homeResetID : nil) {
                                    WithPerceptionTracking {
                                        if section == .sites || section == .python {
                                            sourcePage(section)
                                        } else if section == .home {
                                            if preparedHomeSource { LocalHTMLHomeContent { page(section) } }
                                            else { Color.clear }
                                        } else { page(section) }
                                    }
                                }
                                .frame(width: viewport.size.width, height: viewport.size.height)
                                .environment(\.isLocalPageActive, current == section && !sourcePanelBlocksInput)
                                .environment(\.localDockInset, keyboardVisible ? 0 : dockInset)
                                .id(stackIdentity(section))
                                .opacity(current == section ? 1 : 0)
                                .disabled(current != section || sourcePanelBlocksInput)
                                .allowsHitTesting(current == section && !sourcePanelBlocksInput)
                                .accessibilityHidden(current != section || sourcePanelBlocksInput)
                                .zIndex(current == section ? 1 : 0)
                            }
                        }
                    }
                    .environment(\.localHTMLDockClearance, dockInset)
                    .environment(\.localDockTop, keyboardVisible ? nil : viewport.frame(in: .global).maxY - dockInset)
                    .frame(width: viewport.size.width, height: viewport.size.height)
                    .overlay(alignment: .bottom) {
                        WithPerceptionTracking {
                            VStack(spacing: LocalDockLayout.musicSpacing) {
                                if showsMusicStrip {
                                    MusicMiniPlayer().frame(height: LocalDockLayout.musicHeight)
                                        .localGlassSurface(cornerRadius: 28)
                                }
                                dock(metrics)
                            }
                            .padding(.horizontal, metrics.horizontalPadding)
                            .padding(.top, LocalDockLayout.topPadding).padding(.bottom, LocalDockLayout.bottomPadding)
                            .localDockHitRegions(frames: metrics.touchFrames(showsMusic: showsMusicStrip, rightToLeft: layoutDirection == .rightToLeft))
                            // Keep the same responders during fades. Hiding cancels
                            // their finger before SwiftUI animates any pixels away.
                            .disabled(!dockVisible || sourcePanelBlocksInput)
                            .allowsHitTesting(dockVisible && !sourcePanelBlocksInput)
                            .accessibilityHidden(!dockVisible || sourcePanelBlocksInput)
                            .opacity(dockVisible ? 1 : 0)
                        }
                    }
                }
            }
            .environment(\.usesLocalDock, true)
            .environment(\.localDockVisible, dockVisible)
            .environment(\.localHTMLDockHidden, $htmlDockHidden)
            .environment(\.localDockScrollEnabled, !keyboardVisible && !sourcePanelBlocksInput)
            .environment(\.localDockActivity, { id, active in scrolled(id: id, active: active) })
            .environment(\.openLocalHomeSources, { openHomeSources() })
            .onAppear { prepareHomeDestination(); visited.insert(current); rememberHome(); revealDock() }
            .task(id: sourceRevision) { prepareHomeDestination(); synchronizeSources() }
            .appOnChange(of: manga.repositories.isEmpty) { _, empty in
                if empty && current == .manga { selectSection(.home) }
                if empty && sourcePanel == .manga { sourcePanel = .sites }
            }
            .appOnChange(of: store.section) { old, _ in
                // This also covers navigation initiated by a page (for example
                // Continue Watching), not just clicks handled by the dock.
                if let target = homeTarget(for: old) { rememberHome(target) }
                rememberHome()
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                visited.insert(current)
                revealDock()
            }
            .appOnChange(of: entries) { previous, next in dockChanged(from: previous, to: next) }
            .appOnChange(of: htmlHomeData) { _, _ in rememberHome() }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
            // Keep the dock out of the keyboard's shrinking safe area until dismissal finishes.
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in keyboardVisible = false }
            .onReceive(NotificationCenter.default.publisher(for: TMDBServiceSettings.changed)) { _ in
                metadataRevision = TMDBServiceSettings.identity
            }
            .localGlassDialog(isPresented: Binding(get: { sourcePanel != nil }, set: { if !$0 { sourcePanel = nil } }), title: "",
                              maxWidth: 440, maxHeight: 520, layout: .sources,
                              animated: false,
                              onDismiss: { sourcePanelBlocksInput = false }) {
                RouteStack {
                    WithPerceptionTracking {
                        LocalHomeSourcePanel(initialKind: sourcePanel ?? .sites, pickedSites: pickedSites, homeSelected: current == .home,
                                             mangaSelected: current == .manga, pick: select, home: selectHome, pickManga: selectManga)
                    }
                }
                .environment(store)
                .toolbarBackground(.hidden, for: .navigationBar)
            }
            .onDisappear { revealDock() }
            .fullScreenCover(isPresented: Binding(get: { store.music.presentsPlayer }, set: { store.music.presentsPlayer = $0 })) {
                MusicNowPlayingScreen().environment(store)
            }
        }
    }

    private func stackIdentity(_ section: AppSection) -> String {
        if section == .manga {
            return "manga|" + (manga.currentSource?.key ?? "") + "|" + (manga.currentSource?.revision ?? "")
        }
        guard section == .sites || section == .python, let site = pickedSites[section] else {
            return section == .home || section == .discover ? section.rawValue + "|" + metadataRevision + "|\(homeRevision)" : section.rawValue
        }
        // Only the live stack uses this process-local hash. Persisted identity stays origin + original key.
        return section.rawValue + "|" + site.key + "|\(site.hashValue)"
    }

    @ViewBuilder private func sourcePage(_ section: AppSection) -> some View {
        if let site = pickedSites[section], let config = store.subscription {
            SiteView(site: site, origin: config.origin, jarURL: config.spiderURL)
                .id(site.key + "|" + site.origin(or: config.origin).absoluteString)
        } else {
            VStack(spacing: 18) {
                Image(systemName: section.icon).font(.system(size: 44)).foregroundStyle(.secondary)
                Text(section == .python ? "选择 python 来源" : "选择站点").font(.title2)
                Button("选择来源") { presentSources(section == .python ? .python : .sites) }.buttonStyle(.borderedProminent)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).screenBackdrop()
        }
    }

    private var sourceRevision: String {
        let readiness = store.subscriptions.map { entry in
            "\(entry.address)|\(entry.enabled)|\(store.documents[entry.address] != nil)|\(store.subscriptionErrors[entry.address] != nil)"
        }.joined(separator: "\n")
        return "\(store.subscriptionRevision)|\(store.importing)|" + readiness
    }

    private func prepareHomeDestination() {
        guard !preparedHomeSource else { return }
        var home = LocalHTMLHomeStore.load()
        let previous = home
        let preference = LocalHomeDestination(rawValue: UserDefaults.standard.string(forKey: LocalHomeDestination.key) ?? "") ?? .home
        home.restoreStartup(preference)
        if home != previous {
            do { try home.save() }
            catch { Diagnostics.shared.record(.warning, "home", "startup home could not be saved") }
        }
        preparedHomeSource = true
    }

    private func selection(for site: Site, origin: URL) -> LocalHomeSourceSelection {
        LocalHomeSourceSelection(origin: site.origin(or: origin).absoluteString, sourceKey: site.sourceKey, python: store.localSourceGroup(for: site) == .python)
    }

    private func synchronizeSources() {
        guard !store.importing else { return }
        let defaults = UserDefaults.standard
        let sites = store.subscription.map { config in store.orderedSites(config).filter { !$0.isBuiltIn } } ?? []
        if let config = store.subscription {
            for section in [AppSection.sites, .python] {
                let remembered = pickedSites[section].map { selection(for: $0, origin: config.origin) }
                    ?? LocalHomeSourceSelection.saved(python: section == .python, defaults: defaults)
                pickedSites[section] = sites.first { selection(for: $0, origin: config.origin) == remembered }
            }
        } else { pickedSites = [:] }
        guard !restoredDestination else { return }
        let preference = defaults.string(forKey: "local.home.defaultDestination") ?? "home"
        guard current == .home, preference == "lastSite" || preference == "lastPython",
              LocalHomeSourceSelection.saved(python: preference == "lastPython", defaults: defaults) != nil else {
            restoredDestination = true
            return
        }
        let desired = store.subscription.flatMap { config in
            LocalHomeSourceSelection.destination(preference, available: sites.map { selection(for: $0, origin: config.origin) }, defaults: defaults)
        }
        // Another category can already have a cached document when the target's restore has not begun.
        // Each category has one enabled owner; failed, disabled and deleted entries settle on home.
        let targetGroup: LocalSourceGroup = preference == "lastPython" ? .python : .subscription
        if desired == nil, store.subscriptions.contains(where: { entry in
            entry.enabled && (store.localSourceGroups[entry.address] ?? .subscription) == targetGroup
                && store.documents[entry.address] == nil && store.subscriptionErrors[entry.address] == nil
        }) { return }
        restoredDestination = true
        guard let config = store.subscription, let desired,
              let site = sites.first(where: { selection(for: $0, origin: config.origin) == desired }) else { return }
        select(site)
    }

    private func select(_ site: Site) {
        store.cancelResume()
        let section: AppSection = store.localSourceGroup(for: site) == .python ? .python : .sites
        pickedSites[section] = site
        if let config = store.subscription { selection(for: site, origin: config.origin).save() }
        if let config = store.subscription {
            rememberHome(.site(selection(for: site, origin: config.origin), title: site.name))
        }
        store.section = section
        visited.insert(section)
        sourcePanel = nil
    }

    private func selectHome() {
        store.cancelResume()
        // HTML selection has already been saved by the selector. Its source.id
        // controls actual source changes; returning to it preserves web history.
        // Explicit native Home still resets a pushed native detail stack.
        if LocalHTMLHomeStore.load().active == nil { homeRevision += 1 }
        homeResetID = UUID()
        store.section = .home
        visited.insert(.home)
        rememberHome()
        sourcePanel = nil
    }

    private func selectManga(_ key: String) {
        guard !manga.repositories.isEmpty, manga.sources.contains(where: { $0.key == key }) else { return }
        store.cancelResume()
        manga.selectedSource = key
        store.section = .manga
        visited.insert(.manga)
        rememberHome()
        sourcePanel = nil
    }

    private func homeTarget(for section: AppSection) -> LocalHomeActionTarget? {
        switch section {
        case .sites, .python:
            guard let site = pickedSites[section], let config = store.subscription else { return nil }
            return .site(selection(for: site, origin: config.origin), title: site.name)
        case .home, .discover:
            if let html = LocalHTMLHomeStore.load().active { return .html(id: html.id, title: html.name) }
            return .home
        case .manga:
            guard !manga.repositories.isEmpty, let source = manga.currentSource else { return nil }
            return .manga(key: source.key, title: source.name)
        default: return nil
        }
    }

    private func rememberHome(_ target: LocalHomeActionTarget? = nil) {
        guard let target = target ?? homeTarget(for: current), previousHome != target else { return }
        previousHome = target
        try? target.save(forKey: LocalHomeAction.previousKey)
    }

    private func homeDockTapped() {
        restoredDestination = true
        let isHome = current == .home || current == .sites || current == .python || current == .manga
        let remembered = previousHome ?? LocalHomeActionTarget.saved(forKey: LocalHomeAction.previousKey)
        guard let target = LocalHomeAction.destination(enabled: homeActionEnabled, mode: homeAction,
                                                       isHome: isHome, previous: remembered,
                                                       fixed: LocalHomeActionTarget.decode(fixedHomeData)),
              showHomeTarget(target) else {
            openHomeSources()
            return
        }
        revealDock()
    }

    /// Returning to an existing source does not reset its retained navigation or
    /// reload an HTML document. Selecting a different target updates only its owner.
    private func showHomeTarget(_ target: LocalHomeActionTarget) -> Bool {
        switch target {
        case .manga(let key, _):
            guard !manga.repositories.isEmpty, manga.sources.contains(where: { $0.key == key }),
                  manga.listedSources.contains(where: { $0.key == key }) else { return false }
            selectManga(key)
        case .site(let saved, _):
            guard let config = store.subscription,
                  let site = store.homeSourceSites(config).first(where: {
                      !$0.isBuiltIn && selection(for: $0, origin: config.origin) == saved
                  }) else { return false }
            select(site)
        case .home, .html:
            var homes = LocalHTMLHomeStore.load()
            let id: String
            if case .html(let savedID, _) = target {
                guard homes.canOpen(savedID) else { return false }
                id = savedID
            } else { id = "builtin" }
            if homes.activeID != id {
                homes.select(id)
                do { try homes.save() }
                catch { return false }
                // A native detail belongs to the former Home content. Returning
                // to the same content keeps it; changing that content pops it.
                homeResetID = UUID()
            }
            store.cancelResume()
            store.section = .home
            visited.insert(.home)
            rememberHome(target)
        }
        return true
    }

    private func openHomeSources() {
        restoredDestination = true
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        presentSources(current == .manga && !manga.repositories.isEmpty ? .manga : current == .python ? .python : htmlHomeSelected ? .html : .sites)
    }

    private func presentSources(_ kind: LocalHomeSourceKind) {
        store.cancelResume()
        // Remain blocked after a selection sets sourcePanel to nil. UIKit's
        // dismissal completion owns re-enabling the underlying retained page.
        sourcePanelBlocksInput = true
        sourcePanel = kind
    }

    private func scrolled(id: UUID, active: Bool) {
        if active { activeScrollObservers.insert(id) } else { activeScrollObservers.remove(id) }
        let hidden = !activeScrollObservers.isEmpty
        guard dockHiddenByScroll != hidden else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: hidden ? 0.16 : 0.18)) { dockHiddenByScroll = hidden }
    }

    private func revealDock() {
        activeScrollObservers.removeAll()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { dockHiddenByScroll = false }
    }

    private func dock(_ metrics: LocalDockLayout.Metrics) -> some View {
        let layout = metrics.stacked ? AnyLayout(VStackLayout(spacing: metrics.groupSpacing))
                                    : AnyLayout(HStackLayout(spacing: metrics.groupSpacing))
        return layout {
            dockGroup(entries, metrics: metrics)
            dockGroup(accessories, metrics: metrics)
        }
        .frame(maxWidth: .infinity).frame(height: metrics.height)
    }

    private func dockGroup(_ controls: [AppSection], metrics: LocalDockLayout.Metrics) -> some View {
        HStack(spacing: metrics.buttonSpacing) {
            ForEach(controls) { entry in WithPerceptionTracking { dockButton(entry, width: metrics.buttonWidth) } }
        }
        .padding(.horizontal, metrics.groupHorizontalPadding)
        .padding(.vertical, LocalDockLayout.groupPadding)
        .localGlassSurface(cornerRadius: 29)
        .allowsHitTesting(false).accessibilityHidden(true)
        .overlay {
            WithPerceptionTracking {
                LocalDockGroupTouchSurface(controls: controls.map(dockControl), spacing: metrics.buttonSpacing,
                                           horizontalPadding: metrics.groupHorizontalPadding)
            }
        }
    }

    private func dockButton(_ entry: AppSection, width: CGFloat) -> some View {
        let selected = dockSelected(entry)
        let color = dockColor(entry)
        let icon = switch entry {
        case .home: "house.fill"
        case .settings: "gearshape.fill"
        case .push where selected: "paperplane.fill"
        default: entry.icon
        }
        return Image(systemName: icon)
            .font(.system(size: 19, weight: .semibold))
            .frame(width: width, height: LocalDockLayout.controlHeight)
            .foregroundStyle(selected ? color : .primary)
            .background(selected ? color.opacity(0.16) : .clear, in: Capsule())
    }

    private func dockSelected(_ entry: AppSection) -> Bool {
        current == entry || entry == .home && (current == .sites || current == .python || current == .manga)
    }

    private func dockControl(_ entry: AppSection) -> LocalDockControl {
        let identifier = switch entry {
        case .home: "local.dock.home"
        case .history: "local.dock.history"
        case .live: "local.dock.live"
        case .music: "local.dock.music"
        case .search: "local.search"
        case .push: "local.push"
        default: "local.dock.settings"
        }
        return LocalDockControl(identifier: identifier, label: entry.title, selected: dockSelected(entry), action: { dockTapped(entry) })
    }

    private func dockChanged(from previous: [AppSection], to next: [AppSection]) {
        // A visibility change removes an entrance. Other routes, including Continue
        // Watching from Home, may still open a section whose button is hidden.
        guard previous.contains(current), !next.contains(current) else { return }
        selectSection(.home)
    }

    private func dockTapped(_ entry: AppSection) {
        restoredDestination = true
        if entry == .home { homeDockTapped() }
        else { selectSection(entry) }
    }

    private func dockColor(_ entry: AppSection) -> Color {
        switch entry {
        case .home: Color(light: Color(red: 0.04, green: 0.42, blue: 0.82), dark: Brand.cyan)
        case .history: Color(light: Color(red: 0.68, green: 0.36, blue: 0.02), dark: Brand.amber)
        case .music: Color(light: Color(red: 0.78, green: 0.18, blue: 0.34), dark: Brand.rose)
        case .settings: Color(light: Color(red: 0.36, green: 0.29, blue: 0.80), dark: Brand.indigo)
        default: Color(light: Color(red: 0.04, green: 0.46, blue: 0.44), dark: Brand.teal)
        }
    }

    private func selectSection(_ section: AppSection) {
        restoredDestination = true
        guard current != section else { return }
        store.cancelResume()
        visited.insert(section)
        store.section = section
    }
}

struct LocalContinueWatching: View {
    @Environment(Store.self) private var store
    @AppStorage("local.home.continueWatching") private var enabled = true
    var body: some View {
        WithPerceptionTracking {
            if enabled, !store.visibleHistory.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Button { store.cancelResume(); store.section = .history } label: {
                        HStack {
                            Text("继续观看").font(.title3.weight(.bold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                        }.contentShape(Rectangle()).frame(minHeight: 44)
                    }.buttonStyle(.plain).padding(.horizontal, 17)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(store.visibleHistory.prefix(12)) { entry in HistoryCard(entry: entry) }
                        }.padding(.horizontal, 17)
                    }
                }.accessibilityIdentifier("home.continueWatching")
            }
        }
    }
}
#endif
