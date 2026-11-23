import SwiftUI
import Perception
import TVCore

struct LocalSearchSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let config: Subscription
    @State private var preferences: LocalSearchPreferences
    @State private var selectedGroup: String?
    @State private var query = ""
    private var changed: () -> Void
    init(config: Subscription, changed: @escaping () -> Void = {}) {
        self.config = config
        self.changed = changed
        let preferences = LocalSearchPreferences.load(config: config)
        _preferences = State(initialValue: preferences)
        _selectedGroup = State(initialValue: preferences.groups.first?.id)
    }
    private var sites: [Site] { (config.sites + LocalSearchManga.sites).filter { $0.searchable && $0.canBrowse(jarURL: config.spiderURL) } }
    private var visible: [Site] { sites.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespacesAndNewlines)) } }
    private var groupIndex: Int? { preferences.groups.firstIndex { $0.id == selectedGroup } }
    private func enabled(_ site: Site) -> Bool {
        let id = LocalSearchPreferences.memberID(for: site)
        if preferences.mode == .default { return !preferences.disabledSiteIDs.contains(id) }
        return groupIndex.map { preferences.groups[$0].siteIDs.contains(id) } ?? false
    }
    private func set(_ site: Site, _ enabled: Bool) {
        let id = LocalSearchPreferences.memberID(for: site)
        if preferences.mode == .default {
            if enabled { preferences.disabledSiteIDs.remove(id) } else { preferences.disabledSiteIDs.insert(id) }
        } else if let index = groupIndex {
            preferences.groups[index].siteIDs.removeAll { $0 == id }
            if enabled { preferences.groups[index].siteIDs.append(id) }
        }
    }
    var body: some View {
        WithPerceptionTracking {
            #if os(iOS)
            settingsForm
                .textFieldStyle(LocalGlassTextFieldStyle())
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
            #else
            NavigationStack {
                settingsForm
                    .navigationTitle("搜索设置")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                    }
            }
            #endif
        }
    }

    private var settingsForm: some View {
        WithPerceptionTracking {
            Form {
                Section {
                    #if os(iOS)
                    LocalGlassChoicePicker(title: "搜索模式", selection: $preferences.mode,
                                           options: LocalSearchPreferences.Mode.allCases.map { .init($0, $0.title) })
                    LocalGlassChoicePicker(title: "搜索结果", selection: $preferences.resultOrder,
                                           options: LocalSearchPreferences.ResultOrder.allCases.map { .init($0, $0.title) })
                    LocalGlassChoicePicker(title: "关键词", selection: $preferences.keywordMode,
                                           options: LocalSearchPreferences.KeywordMode.allCases.map { .init($0, $0.title) })
                    #else
                    Picker("搜索模式", selection: $preferences.mode) {
                        ForEach(LocalSearchPreferences.Mode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                    }.pickerStyle(.segmented)
                    Picker("搜索结果", selection: $preferences.resultOrder) {
                        ForEach(LocalSearchPreferences.ResultOrder.allCases, id: \.self) { order in Text(order.title).tag(order) }
                    }.pickerStyle(.segmented)
                    Picker("关键词", selection: $preferences.keywordMode) {
                        ForEach(LocalSearchPreferences.KeywordMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                    }.pickerStyle(.segmented)
                    #endif
                    Text(preferences.mode == .all ? "按设置顺序查询全部订阅、Python 和已安装漫画站点，不受默认开关影响。" : preferences.mode == .default ? "勾选默认搜索的站点；关闭的站点仍可在全部模式中搜索。" : "按分组顺序查询，各组内保持设置中的站点顺序；同一站点只查询一次，首先显示全部分组。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(preferences.resultOrder == .default ? "默认顺序按设置排列，稍后返回的结果插入对应位置。" : "结果优先按返回时间追加，已显示的结果保持原位。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(preferences.keywordMode == .default ? "默认搜索保留站点返回的结果。" : preferences.keywordMode == .contains ? "模糊搜索只显示标题包含关键词的结果。" : "精确搜索只显示标题与关键词相同的结果。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.listRowBackground(Color.clear)
                if preferences.mode == .groups {
                    Section("搜索分组") {
                        ForEach(Array(preferences.groups.enumerated()), id: \.element.id) { index, group in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Button { selectedGroup = group.id } label: {
                                        Image(systemName: selectedGroup == group.id ? "checkmark.circle.fill" : "circle")
                                            .frame(width: 44, height: 44).contentShape(Rectangle())
                                    }.accessibilityLabel("选择分组 \(group.name)")
                                    TextField("分组名称", text: $preferences.groups[index].name).frame(minHeight: 44)
                                }
                                HStack(spacing: 12) {
                                    Spacer(minLength: 0)
                                    Button { preferences.groups.swapAt(index, index - 1) } label: {
                                        Image(systemName: "arrow.up").frame(width: 44, height: 44).contentShape(Rectangle())
                                    }.disabled(index == 0).accessibilityLabel("上移分组 \(group.name)")
                                    Button { preferences.groups.swapAt(index, index + 1) } label: {
                                        Image(systemName: "arrow.down").frame(width: 44, height: 44).contentShape(Rectangle())
                                    }.disabled(index + 1 == preferences.groups.count).accessibilityLabel("下移分组 \(group.name)")
                                    Button(role: .destructive) {
                                        preferences.groups.removeAll { $0.id == group.id }
                                        if selectedGroup == group.id { selectedGroup = preferences.groups.first?.id }
                                    } label: {
                                        Image(systemName: "trash").frame(width: 44, height: 44).contentShape(Rectangle())
                                    }.accessibilityLabel("删除分组 \(group.name)")
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                        Button("新增分组") {
                            let group = LocalSearchPreferences.Group(name: "分组 \(preferences.groups.count + 1)")
                            preferences.groups.append(group); selectedGroup = group.id
                        }.disabled(preferences.groups.count >= 32)
                    }.listRowBackground(Color.clear)
                }
                Section(preferences.mode == .all ? "搜索顺序" : preferences.mode == .default ? "默认参与的站点" : "当前分组的站点") {
                    TextField("筛选站点", text: $query)
                    if preferences.mode != .all {
                        HStack {
                            Button("全选") { visible.forEach { set($0, true) } }
                            Spacer()
                            Button("全不选") { visible.forEach { set($0, false) } }
                        }
                    }
                    ForEach(visible) { site in
                        if preferences.mode == .all { Text(site.name) }
                        else { Toggle(site.name, isOn: Binding(get: { enabled(site) }, set: { set(site, $0) })) }
                    }
                }.listRowBackground(Color.clear)
                    .disabled(preferences.mode == .groups && groupIndex == nil)
            }
            .appOnChange(of: preferences) { _, value in value.save(config: config); changed() }
        }
    }
}
