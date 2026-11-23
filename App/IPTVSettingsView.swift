#if os(iOS)
import SwiftUI
import UIKit
import Perception
import TVCore

struct IPTVSettingsView: View {
    private let library = IPTVLibrary.shared
    @State private var editor: IPTVSettingsDestination?
    @State private var removing: IPTVRecord?
    @State private var error: String?
    @State private var reorder = LocalSettingsReorderSession()

    var body: some View {
        WithPerceptionTracking {
            SettingsPage(title: "直播", symbol: AppSection.live.icon) {
                SettingsGroup {
                    Button { editor = .add } label: {
                        Label("添加直播订阅", systemImage: "plus.circle").frame(minHeight: 44)
                    }
                    .disabled(library.loadError != nil)
                    .accessibilityIdentifier("iptv.add")
                    if let message = library.loadError ?? error {
                        Text(message).font(.footnote).foregroundStyle(.red)
                    }
                }
                SettingsGroup(title: "直播订阅") {
                    if library.records.isEmpty {
                        Text("尚未添加直播订阅").foregroundStyle(.secondary)
                    } else {
                        LocalSettingsReorderList(validIDs: library.records.map(\.id), enabled: true,
                            session: $reorder, move: move) {
                            ForEach(library.records) { record in
                                WithPerceptionTracking { row(record).localSettingsReorderRow(id: record.id) }
                            }
                        }
                    }
                }
            }
            .sheet(item: $editor) { destination in
                NavigationStack {
                    switch destination {
                    case .add: IPTVSubscriptionEditor(record: nil)
                    case .edit(let record): IPTVSubscriptionEditor(record: record)
                    case .rename(let record): IPTVNameEditor(record: record)
                    case .guide(let record): IPTVGuideSettingsEditor(record: record)
                    }
                }
            }
            .confirmationDialog("删除直播订阅？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible, presenting: removing) { record in
                Button("删除", role: .destructive) { apply { try library.delete(record.id) } }
                Button("取消", role: .cancel) {}
            } message: { record in Text(record.name) }
            .onDisappear { reorder.cancel() }
        }
    }

    private func row(_ record: IPTVRecord) -> some View {
        let refreshing = library.refreshingIDs.contains(record.id)
        let isFirst = record.id == library.records.first?.id
        let isLast = record.id == library.records.last?.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(record.name).font(.headline).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("启用 " + record.name, isOn: Binding(get: { record.enabled }, set: { enabled in
                    apply { try library.setEnabled(record.id, enabled: enabled) }
                })).labelsHidden()
                Menu {
                    Button("编辑订阅") { editor = .edit(record) }
                    Button("重命名") { editor = .rename(record) }
                    Button("节目单与时区") { editor = .guide(record) }
                    if refreshing {
                        Button("取消刷新") { library.cancel(record.id) }
                    } else {
                        Button("刷新订阅") {
                            Task {
                                do { try await library.refresh(record.id) }
                                catch is CancellationError {}
                                catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                    Button("上移") { move(record.id, by: -1) }.disabled(isFirst)
                    Button("下移") { move(record.id, by: 1) }.disabled(isLast)
                    Button("删除订阅", role: .destructive) { removing = record }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                .accessibilityLabel(record.name + "的操作")
                LocalSettingsReorderHandle(title: record.name, id: record.id, enabled: true, session: $reorder)
                    .accessibilityAction(named: "上移") { move(record.id, by: -1) }
                    .accessibilityAction(named: "下移") { move(record.id, by: 1) }
            }
            Text(counts(format: record.format, stations: record.stations.count, platforms: record.platforms.count))
                .font(.subheadline).foregroundStyle(.secondary)
            if refreshing {
                ProgressView("正在刷新").font(.footnote)
            } else if let date = record.lastUpdated {
                Text("上次成功更新 \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if record.requiresAuthorization {
                Text("请重新提供订阅地址、文件或所需请求头。").font(.footnote).foregroundStyle(.orange)
            }
            if let message = record.lastError { Text(message).font(.footnote).foregroundStyle(.red) }
        }
    }

    private func move(_ id: String, onto target: String) {
        let ids = library.records.map(\.id)
        guard let source = ids.firstIndex(of: id), let destination = ids.firstIndex(of: target) else { return }
        apply { try library.move(from: IndexSet(integer: source), to: destination + (source < destination ? 1 : 0)) }
    }

    private func move(_ id: String, by delta: Int) {
        let ids = library.records.map(\.id)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + delta) else { return }
        move(id, onto: ids[index + delta])
    }

    private func apply(_ action: () throws -> Void) {
        do { try action(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

private enum IPTVSettingsDestination: Identifiable {
    case add, edit(IPTVRecord), rename(IPTVRecord), guide(IPTVRecord)
    var id: String {
        switch self {
        case .add: "new"
        case .edit(let record): "edit-" + record.id
        case .rename(let record): "rename-" + record.id
        case .guide(let record): "guide-" + record.id
        }
    }
}

/// Retained by the editor so Preview/Save can commit a pending IME composition
/// before taking a snapshot of the name, without retaining a removed native field.
@MainActor private final class IPTVNameInputSession: ObservableObject {
    weak var field: UITextField?

    func commit() {
        guard let field else { return }
        if field.markedTextRange != nil { field.unmarkText() }
        field.sendActions(for: .editingChanged)
        field.resignFirstResponder()
    }
}

/// Mirrors DiscoverSearchInput's composition guards. SwiftUI only receives committed
/// characters; view updates never replace the text owned by a Chinese/Japanese IME.
private struct IPTVNameField: UIViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    @Binding var text: String
    let session: IPTVNameInputSession
    var placeholder = "名称（可选）"
    var identifier = "iptv.name"

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = .label
        field.tintColor = .systemBlue
        field.returnKeyType = .done
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        session.field = field
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        field.placeholder = placeholder
        field.accessibilityLabel = "直播订阅名称"
        field.accessibilityIdentifier = identifier
        field.isEnabled = enabled
        if field.markedTextRange == nil, field.text != text { field.text = text }
    }

    static func dismantleUIView(_ field: UITextField, coordinator: Coordinator) {
        if coordinator.parent.session.field === field { coordinator.parent.session.field = nil }
        field.delegate = nil
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: IPTVNameField
        init(_ parent: IPTVNameField) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            guard field.markedTextRange == nil else { return }
            let value = field.text ?? ""
            if parent.text != value { parent.text = value }
        }

        func textFieldDidEndEditing(_ field: UITextField) { changed(field) }
        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.session.commit()
            return true
        }
    }
}

private struct IPTVNameEditor: View {
    @Environment(\.dismiss) private var dismiss
    let record: IPTVRecord
    @State private var name: String
    @State private var error: String?
    @StateObject private var input = IPTVNameInputSession()

    init(record: IPTVRecord) {
        self.record = record
        _name = State(initialValue: record.name)
    }

    var body: some View {
        SettingsPage(title: "重命名直播订阅") {
            SettingsGroup(title: "名称") {
                IPTVNameField(text: $name, session: input, placeholder: "名称", identifier: "iptv.rename.name")
                    .frame(minHeight: 24).padding(.horizontal, 12).padding(.vertical, 10)
                    .localGlassInputSurface()
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    input.commit()
                    do {
                        try IPTVLibrary.shared.rename(record.id, name: name)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
    }
}

private func counts(format: String, stations: Int, platforms: Int) -> String {
    var parts = [format, "\(stations) 个频道"]
    if platforms > 0 { parts.append("\(platforms) 个平台") }
    return parts.filter { !$0.isEmpty }.joined(separator: " · ")
}

private struct IPTVGuideFields: View {
    @Binding var address: String
    @Binding var timeZoneID: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("节目单地址（留空自动选择）", text: $address)
                .keyboardType(.URL)
            TextField("来源时区，如 Asia/Shanghai", text: $timeZoneID)
            Text("留空时优先使用订阅内的节目单；订阅未提供时，使用 epg.cdn.loc.cc。回看需频道本身支持。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .textInputAutocapitalization(.never).autocorrectionDisabled()
    }
}

private struct IPTVGuideSettingsEditor: View {
    @Environment(\.dismiss) private var dismiss
    let record: IPTVRecord
    @State private var address: String
    @State private var timeZoneID: String
    @State private var error: String?

    init(record: IPTVRecord) {
        self.record = record
        _address = State(initialValue: record.guideOverride ?? "")
        _timeZoneID = State(initialValue: record.timeZoneID)
    }

    var body: some View {
        SettingsPage(title: "节目单与时区") {
            SettingsGroup(title: record.name) {
                IPTVGuideFields(address: $address, timeZoneID: $timeZoneID)
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    do {
                        try IPTVLibrary.shared.setGuide(record.id, override: address, timeZoneID: timeZoneID)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
    }
}

private struct IPTVSubscriptionEditor: View {
    @Environment(\.dismiss) private var dismiss
    private let library = IPTVLibrary.shared
    let record: IPTVRecord?
    @State private var name: String
    @StateObject private var nameInput = IPTVNameInputSession()
    @State private var address: String
    @State private var usesFile: Bool
    @State private var asSingle: Bool
    @State private var headerText: String
    @State private var guideOverride: String
    @State private var timeZoneID: String
    @State private var pickedData: Data?
    @State private var pickedFilename: String?
    @State private var picking = false
    @State private var preview: IPTVPreview?
    @State private var task: Task<Void, Never>?
    @State private var error: String?

    init(record: IPTVRecord?) {
        self.record = record
        _name = State(initialValue: record?.name ?? "")
        _address = State(initialValue: record?.address ?? "")
        _usesFile = State(initialValue: record?.filename != nil)
        _asSingle = State(initialValue: record?.asSingle ?? false)
        _guideOverride = State(initialValue: record?.guideOverride ?? "")
        _timeZoneID = State(initialValue: record?.timeZoneID ?? "Asia/Shanghai")
        let headers = record.map { IPTVLibrary.shared.headers(for: $0.id) } ?? [:]
        _headerText = State(initialValue: headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
    }

    var body: some View {
        SettingsPage(title: record == nil ? "添加直播订阅" : "编辑直播订阅") {
            if let preview {
                SettingsGroup(title: "订阅预览") {
                    Text(preview.name).font(.headline)
                    Text(counts(format: preview.format, stations: preview.stations.count, platforms: preview.platforms.count))
                    if !preview.warnings.isEmpty {
                        DisclosureGroup("解析提示（\(preview.warnings.count)）") {
                            Text(preview.warnings.joined(separator: "\n")).font(.footnote)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                        }
                    }
                    Button("返回编辑") { self.preview = nil; error = nil }
                }
            } else {
                SettingsGroup(title: "来源") {
                    IPTVNameField(text: $name, session: nameInput)
                        .frame(minHeight: 24).padding(.horizontal, 12).padding(.vertical, 10)
                        .localGlassInputSurface()
                    Picker("来源类型", selection: $usesFile) {
                        Text("远程地址").tag(false)
                        Text("本地文件").tag(true)
                    }.pickerStyle(.segmented)
                    if usesFile {
                        if let file = pickedFilename ?? record?.filename { Text(file).font(.subheadline).lineLimit(2) }
                        Button { picking = true } label: { Label("选择文件", systemImage: "folder") }
                    } else {
                        TextField("直播订阅地址", text: $address)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Toggle("作为单频道打开", isOn: $asSingle)
                    }
                }.disabled(task != nil)
                SettingsGroup {
                    DisclosureGroup("请求头") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("每行填写一个请求头，例如 User-Agent: Yingxia").font(.footnote).foregroundStyle(.secondary)
                            TextField("名称: 值", text: $headerText, axis: .vertical)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .lineLimit(2...8).privacySensitive()
                        }.padding(.top, 8)
                    }
                    DisclosureGroup("节目单与时区") {
                        IPTVGuideFields(address: $guideOverride, timeZoneID: $timeZoneID).padding(.top, 8)
                    }
                }.disabled(task != nil)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            if task != nil {
                HStack {
                    ProgressView("正在读取直播订阅")
                    Spacer()
                    Button("取消读取") { cancelRead() }
                }
            } else if let preview {
                Button("保存订阅") {
                    do {
                        try library.commit(preview, guideOverride: guideOverride, timeZoneID: timeZoneID)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("iptv.save")
            } else {
                Button("预览订阅") { startPreview() }.buttonStyle(.borderedProminent)
                    .disabled(usesFile ? pickedFilename == nil && record?.filename == nil
                                      : address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("iptv.preview")
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { cancelRead(); dismiss() } }
        }
        .localDocumentImporter(isPresented: $picking, kind: .playlistFile) { result in
            switch result {
            case .success(let selection): readFile(selection)
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        .onDisappear { cancelRead() }
    }

    private func cancelRead() {
        task?.cancel()
        task = nil
    }

    private func readFile(_ selection: LocalDocumentSelection) {
        cancelRead()
        error = nil
        pickedData = nil
        pickedFilename = nil
        task = Task {
            defer { selection.release(); if !Task.isCancelled { task = nil } }
            do {
                let data = try await selection.readData(maxBytes: IPTVLibrary.maximumDocumentBytes)
                try Task.checkCancellation()
                pickedData = data
                pickedFilename = selection.urls[0].lastPathComponent
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    private func startPreview() {
        guard task == nil else { return }
        nameInput.commit()
        error = nil
        task = Task {
            defer { if !Task.isCancelled { task = nil } }
            do {
                let headers = try parsedHeaders()
                let value: IPTVPreview
                if usesFile, let pickedData, let pickedFilename {
                    value = try await library.preview(data: pickedData, filename: pickedFilename,
                                                      name: name, headers: headers, replacing: record?.id)
                } else if usesFile, let record {
                    value = try await library.previewLocal(record.id, name: name, headers: headers)
                } else {
                    value = try await library.preview(address: address, name: name, headers: headers,
                                                      asSingle: asSingle, replacing: record?.id)
                }
                try Task.checkCancellation()
                preview = value
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    private func parsedHeaders() throws -> [String: String] {
        var result: [String: String] = [:], seen: Set<String> = []
        for (index, line) in headerText.components(separatedBy: .newlines).enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let valid = !key.isEmpty && key.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || "!#$%&'*+-.^_`|~".utf8.contains($0)
            }
            guard parts.count == 2, valid, seen.insert(key.lowercased()).inserted else {
                throw TVError.unsupported("第 \(index + 1) 行请求头格式错误或名称重复。")
            }
            result[key] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}
#endif
