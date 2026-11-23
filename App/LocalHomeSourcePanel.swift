import SwiftUI
import Perception
import TVCore

#if os(iOS)
enum LocalHomeSourceKind: String, CaseIterable, Identifiable {
    case sites, python, html, manga
    var id: String { rawValue }
}

/// All homepage destinations live in the same compact dock selector.
struct LocalHomeSourcePanel: View {
    @Environment(Store.self) private var store
    @Environment(\.localSourceCompactControls) private var compactControls
    @AppStorage(LocalHTMLHomeStore.key) private var htmlHomeData = Data()
    @State private var kind: LocalHomeSourceKind
    @State private var websiteShown = false
    @State private var htmlFailure = ""
    @State private var htmlQuery = ""
    @State private var manga = MangaStore.shared
    let pickedSites: [AppSection: Site]
    let homeSelected: Bool
    let mangaSelected: Bool
    let pick: (Site) -> Void
    let home: () -> Void
    let pickManga: (String) -> Void

    init(initialKind: LocalHomeSourceKind, pickedSites: [AppSection: Site], homeSelected: Bool, mangaSelected: Bool,
         pick: @escaping (Site) -> Void, home: @escaping () -> Void, pickManga: @escaping (String) -> Void) {
        _kind = State(initialValue: initialKind == .manga && MangaStore.shared.repositories.isEmpty ? .sites : initialKind)
        self.pickedSites = pickedSites
        self.homeSelected = homeSelected
        self.mangaSelected = mangaSelected
        self.pick = pick
        self.home = home
        self.pickManga = pickManga
    }

    private var sourceGroup: LocalSourceGroup { kind == .python ? .python : .subscription }
    private var activeSubscription: SubscriptionEntry? { store.managedSubscriptions(in: sourceGroup).first(where: \.enabled) }
    private var htmlHomes: LocalHTMLHomeStore { _ = htmlHomeData; return .load() }
    private var configCenterContext: (site: Site, document: Subscription)? {
        guard kind == .sites, let entry = activeSubscription,
              let document = store.documents[entry.address],
              let site = document.sites.first(where: { $0.raw["catPawOpen"] != nil }) else { return nil }
        return (site, document)
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                if !compactControls {
                    Picker("来源类别", selection: $kind) {
                        Text("站点").tag(LocalHomeSourceKind.sites)
                        Text("python").tag(LocalHomeSourceKind.python)
                        Text("html").tag(LocalHomeSourceKind.html)
                        if !manga.repositories.isEmpty { Text("漫画").tag(LocalHomeSourceKind.manga) }
                    }
                    .pickerStyle(.segmented).padding(.horizontal, 14).padding(.vertical, 8)
                    .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                    .accessibilityIdentifier("home.source.kind")
                    header.fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                }
                if kind == .html {
                    htmlSources
                } else if kind == .manga {
                    LocalMangaSourceList(selected: mangaSelected, pick: pickManga)
                } else {
                    let python = kind == .python
                    let candidates = store.localHomeSources(in: python ? .python : .subscription)
                    SitesView(pick: pick, pickable: candidates, picked: pickedSites[python ? .python : .sites]?.key,
                              panelKind: kind.rawValue, builtinHome: python ? nil : { chooseHome("builtin") },
                              homeSelected: homeSelected && htmlHomes.active == nil)
                        .id(kind)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .localGlassBackdrop()
            .appOnChange(of: manga.repositories.isEmpty) { _, empty in
                if empty && kind == .manga { kind = .sites }
            }
            .appOnChange(of: kind) { _, _ in dismissKeyboard() }
            .toolbar(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成", action: dismissKeyboard)
                }
            }
            .localGlassDialog(isPresented: $websiteShown, title: "接口配置", layout: .expanded) {
                WithPerceptionTracking {
                    ConfigCenterView {
                        guard let context = configCenterContext else { return nil }
                        return await CatPawOpen.configCenter(site: context.site, origin: context.document.origin,
                                                            jarURL: context.document.spiderURL)
                    }
                }
            }
        }
    }

    private var header: some View {
        WithPerceptionTracking {
            HStack(spacing: 0) {
                if kind == .sites {
                    Menu {
                        ForEach(store.managedSubscriptions(in: .subscription)) { entry in
                            Button {
                                dismissKeyboard()
                                Task { await store.setSubscription(entry, enabled: true) }
                            } label: {
                                if entry.enabled { Label(entry.title, systemImage: "checkmark") }
                                else { Text(entry.title) }
                            }
                        }
                        if store.managedSubscriptions(in: .subscription).isEmpty { Text("尚未导入订阅") }
                    } label: {
                        HStack(spacing: 6) {
                            Text(activeSubscription?.title ?? "选择订阅")
                                .font(.subheadline.weight(.semibold)).lineLimit(2)
                            Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }
                    .disabled(store.importing)
                    .accessibilityLabel("切换订阅，" + (activeSubscription?.title ?? "尚未选择"))
                    .accessibilityIdentifier("home.source.subscription")
                } else {
                    Spacer(minLength: 0).frame(minHeight: 44)
                }
                if kind == .sites {
                    Button { dismissKeyboard(); websiteShown = true } label: {
                        SettingsIcon(symbol: "globe", tint: Brand.cyan)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .disabled(configCenterContext == nil || store.importing)
                    .accessibilityLabel("打开接口配置").accessibilityIdentifier("home.source.config")
                    sourceSettingsLink
                } else if kind == .html {
                    RouteLink {
                        ScrollView { LocalHTMLHomeSettingsSection().padding(16) }
                            .navigationTitle("HTML 首页").navigationBarTitleDisplayMode(.inline)
                            .toolbar(.visible, for: .navigationBar)
                            .localGlassBackdrop()
                            .onAppear(perform: dismissKeyboard)
                    } label: {
                        SettingsIcon(symbol: "slider.horizontal.3", tint: Brand.indigo).frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("HTML 首页设置").accessibilityIdentifier("home.source.settings.html")
                } else {
                    sourceSettingsLink
                }
            }
            .buttonStyle(.plain).font(.system(size: 17, weight: .medium))
            .padding(.horizontal, 16).padding(.bottom, 4)
        }
    }

    private var sourceSettingsLink: some View {
        RouteLink {
            Group {
                if kind == .manga { LocalMangaSettingsView() }
                else { LocalSourceSettingsView(kind: sourceGroup) }
            }
            .toolbar(.visible, for: .navigationBar)
            .onAppear(perform: dismissKeyboard)
        } label: {
            SettingsIcon(symbol: "slider.horizontal.3", tint: Brand.indigo)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel(kind == .manga ? "漫画设置" : kind == .python ? "Python 设置" : "订阅设置")
        .accessibilityIdentifier("home.source.settings." + kind.rawValue)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private var htmlSources: some View {
        let homes = htmlHomes
        let query = htmlQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = homes.sources.filter { query.isEmpty || $0.name.localizedStandardContains(query) || ($0.address?.localizedStandardContains(query) ?? false) }
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("筛选 HTML 首页名称或地址", text: $htmlQuery)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search).accessibilityIdentifier("home.source.html.search")
                if !htmlQuery.isEmpty {
                    Button { htmlQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("清除 HTML 首页搜索")
                }
            }
            .padding(.leading, 12).frame(minHeight: 44).localGlassInputSurface()
            .padding(.horizontal, 16).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(matches) { source in
                            htmlRow(source.name, id: source.id, symbol: source.isFile ? "doc.text" : "globe",
                                    selected: homeSelected && homes.activeID == source.id)
                        }
                    }
                    if homes.sources.isEmpty {
                        Text("添加在线地址或导入 HTML 文件后，可在这里切换。")
                            .font(.footnote).foregroundStyle(.secondary).padding(.vertical, 12)
                    } else if matches.isEmpty {
                        Text("没有匹配的 HTML 首页").font(.footnote).foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                    if !htmlFailure.isEmpty { Text(htmlFailure).font(.footnote).foregroundStyle(.secondary) }
                }.padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
        .accessibilityIdentifier("home.source.html")
    }

    private func htmlRow(_ title: String, id: String, symbol: String, selected: Bool) -> some View {
        Button { chooseHome(id) } label: {
            HStack(spacing: 9) {
                MonogramIcon(seed: title, label: SourceLabel(title), size: 34, systemImage: symbol)
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.accent)
                }
            }
            .padding(10).frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }.tileButton().accessibilityIdentifier("home.source.html." + id)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func chooseHome(_ id: String) {
        var next = htmlHomes
        next.select(id)
        do { try next.save(); home() }
        catch { htmlFailure = error.localizedDescription }
    }
}
#endif
