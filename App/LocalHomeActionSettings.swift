#if os(iOS)
import SwiftUI
import Perception
import TVCore

struct LocalHomeActionSettings: View {
    @AppStorage(LocalHomeAction.enabledKey) private var enabled = false
    @AppStorage(LocalHomeAction.modeKey) private var mode = LocalHomeAction.previous
    @AppStorage(LocalHomeAction.fixedKey) private var fixedData = Data()
    @State private var choosing = false

    var body: some View {
        SettingsGroup(title: "动作") {
            Toggle("动作", isOn: $enabled)
                .accessibilityIdentifier("settings.home.action.enabled")
            if enabled {
                LocalGlassChoicePicker(title: "点击底栏首页", selection: $mode,
                                       options: LocalHomeAction.allCases.map { LocalGlassChoice($0, $0.title) })
                    .accessibilityIdentifier("settings.home.action.mode")
                if mode == .fixed {
                    Button { choosing = true } label: {
                        HStack(spacing: 10) {
                            Text("固定界面")
                            Spacer(minLength: 12)
                            Text(LocalHomeActionTarget.decode(fixedData)?.title ?? "请选择")
                                .foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("settings.home.action.fixed")
                }
                Text(mode == .previous ? "从其它页面返回时，直接显示离开首页前的内容；再次点击首页打开来源弹窗。" :
                        "从其它页面返回时，直接显示选定内容；再次点击首页打开来源弹窗。来源不可用时会打开弹窗。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("点击底栏首页时显示来源弹窗。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .localGlassDialog(isPresented: $choosing, title: "固定界面", maxWidth: 440, maxHeight: 520) {
            LocalFixedHomePicker(selected: LocalHomeActionTarget.decode(fixedData)) { target in
                guard let data = try? JSONEncoder().encode(target) else { return }
                fixedData = data
                choosing = false
            }
        }
    }
}

/// Choosing a shortcut changes only its preference, never the currently visited
/// page, active HTML source, startup preference or last-selected station.
private struct LocalFixedHomePicker: View {
    @Environment(Store.self) private var store
    @AppStorage(LocalHTMLHomeStore.key) private var htmlData = Data()
    @State private var kind: LocalHomeSourceKind
    @State private var query = ""
    @State private var manga = MangaStore.shared
    let selected: LocalHomeActionTarget?
    let choose: (LocalHomeActionTarget) -> Void

    init(selected: LocalHomeActionTarget?, choose: @escaping (LocalHomeActionTarget) -> Void) {
        self.selected = selected
        self.choose = choose
        let initial: LocalHomeSourceKind
        switch selected {
        case .site(let source, _): initial = source.python ? .python : .sites
        case .html: initial = .html
        case .manga: initial = MangaStore.shared.repositories.isEmpty ? .sites : .manga
        default: initial = .sites
        }
        _kind = State(initialValue: initial)
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 10) {
                Picker("来源类别", selection: $kind) {
                    Text("站点").tag(LocalHomeSourceKind.sites)
                    Text("python").tag(LocalHomeSourceKind.python)
                    Text("html").tag(LocalHomeSourceKind.html)
                    if !manga.repositories.isEmpty { Text("漫画").tag(LocalHomeSourceKind.manga) }
                }
                .pickerStyle(.segmented)
                TextField("筛选名称", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(LocalGlassTextFieldStyle())
                let entries = targets
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(entries, id: \.self) { target in
                            targetRow(target)
                        }
                        if entries.isEmpty {
                            Text(query.isEmpty ? "此类别暂无可选内容，请先在设置中添加来源。" : "没有匹配内容")
                                .font(.footnote).foregroundStyle(.secondary).padding(.vertical, 20)
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .padding(.horizontal, 16).padding(.bottom, 16)
            .accessibilityIdentifier("settings.home.action.picker")
            .appOnChange(of: manga.repositories.isEmpty) { _, empty in
                if empty && kind == .manga { kind = .sites }
            }
        }
    }

    private var targets: [LocalHomeActionTarget] {
        let values: [LocalHomeActionTarget]
        if kind == .manga {
            values = manga.sources.filter { source in manga.listedSources.contains { $0.key == source.key } }
                .map { .manga(key: $0.key, title: $0.name) }
        } else if kind == .html {
            _ = htmlData
            values = LocalHTMLHomeStore.load().sources.map { .html(id: $0.id, title: $0.name) }
        } else if let config = store.subscription {
            let python = kind == .python
            values = store.localHomeSources(in: python ? .python : .subscription).map { site in
                return .site(LocalHomeSourceSelection(origin: site.origin(or: config.origin).absoluteString,
                                                      sourceKey: site.sourceKey, python: python), title: site.name)
            }
        } else { values = [] }
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return terms.isEmpty ? values : values.filter { target in terms.allSatisfy { target.title.localizedStandardContains($0) } }
    }

    private func targetRow(_ target: LocalHomeActionTarget) -> some View {
        Button { choose(target) } label: {
            HStack(spacing: 10) {
                Text(target.title).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if matchesSelection(target) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.accent) }
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 48)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(matchesSelection(target) ? .isSelected : [])
    }

    private func matchesSelection(_ target: LocalHomeActionTarget) -> Bool {
        switch (target, selected) {
        case (.site(let source, _), .site(let saved, _)): source == saved
        case (.html(let id, _), .html(let savedID, _)): id == savedID
        case (.manga(let key, _), .manga(let savedKey, _)): key == savedKey
        default: false
        }
    }
}
#endif
