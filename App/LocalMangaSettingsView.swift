#if os(iOS)
import SwiftUI
import Perception
import TVCore

/// The local edition's entry point is always available, including before the
/// first subscription. Registering a list makes it visible in the Home selector.
struct LocalMangaSettingsView: View {
    @State private var store = MangaStore.shared
    @State private var address = ""
    @State private var importing = false
    @State private var message: String?
    @State private var operation: Task<Void, Never>?
    @State private var operationID: UUID?

    var body: some View {
        WithPerceptionTracking {
            SettingsPage(title: "漫画", symbol: "books.vertical.fill") {
                SettingsGroup(title: "添加漫画订阅", footer: "支持 Venera 漫画订阅。导入和更新订阅时会自动准备站点，可在首页弹窗的“漫画”列表中直接打开。") {
                    TextField("漫画订阅地址（index.json）", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.go).onSubmit(importAddress)
                        .disabled(importing).accessibilityIdentifier("manga.subscription.address")
                    HStack {
                        Button("使用 Venera 漫画订阅") { address = MangaSources.veneraRepository.absoluteString }
                            .disabled(importing).accessibilityIdentifier("manga.subscription.venera")
                        Spacer()
                        if importing {
                            ProgressView()
                            Button("取消", action: cancelImport)
                        } else {
                            Button("导入", action: importAddress)
                                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .accessibilityIdentifier("manga.subscription.import")
                        }
                    }.buttonStyle(.borderless).frame(minHeight: 44)
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }
                SettingsGroup(title: "漫画订阅", footer: "删除最后一个漫画订阅后，首页弹窗不再显示“漫画”；已安装站点、收藏和阅读记录会保留。") {
                    if store.repositories.isEmpty {
                        Text("尚未添加漫画订阅").foregroundStyle(.secondary)
                    }
                    ForEach(store.repositories, id: \.self) { url in
                        WithPerceptionTracking {
                            HStack(spacing: 8) {
                                RouteLink { MangaRepositoryView(url: url) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(MangaSources.title(of: url)).font(.body.weight(.medium))
                                        Text("\(store.repositoryEntries[url.absoluteString]?.count ?? 0) 个站点")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                }
                                Button(role: .destructive) {
                                    do { try store.deleteRepository(url); message = "已删除漫画订阅。" }
                                    catch { message = error.mangaMessage }
                                } label: {
                                    Image(systemName: "trash").frame(width: 44, height: 44).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(importing)
                                    .accessibilityLabel("删除漫画订阅 " + MangaSources.title(of: url))
                            }
                        }
                    }
                }
            }
            .onAppear { store.reloadSources() }
            .onDisappear { cancelImport() }
        }
    }

    private func importAddress() {
        guard !importing else { return }
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else {
            message = "请输入有效的 HTTP 或 HTTPS 漫画订阅地址。"
            return
        }
        let id = UUID()
        operationID = id; importing = true; message = nil
        operation = Task { @MainActor in
            defer { if operationID == id { importing = false; operation = nil; operationID = nil } }
            do {
                let count = try await store.importRepository(url)
                guard !Task.isCancelled, operationID == id else { return }
                address = ""
                let failures = store.repositoryErrors[url.absoluteString]?.count ?? 0
                message = failures == 0 ? "已准备 \(count) 个漫画站点，可在首页弹窗的“漫画”中直接打开。"
                    : "已导入 \(count) 个漫画站点，\(failures) 个站点准备失败。可在订阅详情中更新重试，其他站点可以正常打开。"
            } catch {
                guard !Task.isCancelled, operationID == id else { return }
                message = error.mangaMessage
            }
        }
    }

    private func cancelImport() {
        operation?.cancel(); operation = nil; operationID = nil
        if importing { message = "已取消导入。" }
        importing = false
    }
}
#endif
