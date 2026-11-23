#if os(iOS)
import SwiftUI
import Perception
import TVCore

/// Subscriptions prepare their sources ahead of selection; Home only opens them.
struct LocalMangaSourceList: View {
    @Environment(Store.self) private var appStore
    @State private var store = MangaStore.shared
    @State private var query = ""
    @State private var loading = false
    @State private var loadID: UUID?
    @State private var failure: String?
    @State private var refresh = 0
    let selected: Bool
    let pick: (String) -> Void

    private var revision: String { store.repositories.map(\.absoluteString).joined(separator: "\n") + "|\(refresh)" }
    private var entries: [MangaRepositoryEntry] {
        let filter = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.listedSources.filter {
            let visible = $0.key.flatMap { key in store.sources.first { $0.key == key } }.map {
                !appStore.hiddenSources.contains(LocalSearchManga.site($0), origin: LocalSearchManga.origin)
            } ?? true
            return visible && (filter.isEmpty || $0.name.localizedStandardContains(filter) || ($0.key?.localizedStandardContains(filter) ?? false))
        }
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("筛选漫画站点", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.search).accessibilityIdentifier("home.source.manga.search")
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44)
                        }.buttonStyle(.plain).accessibilityLabel("清除漫画站点搜索")
                    }
                }.padding(.leading, 12).frame(minHeight: 44).localGlassInputSurface()
                    .padding(.horizontal, 16).padding(.bottom, 10)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(entries) { entry in
                            WithPerceptionTracking { source(entry) }
                        }
                    }.padding(.horizontal, 16)
                    if loading { ProgressView().padding(16) }
                    if let failure {
                        VStack(spacing: 10) {
                            Text(failure).font(.footnote).foregroundStyle(.secondary)
                            Button("重新加载订阅") { refresh += 1 }
                        }.padding(16)
                    } else if entries.isEmpty && !loading {
                        Text(query.isEmpty ? "暂无漫画站点，请在漫画设置中更新订阅。" : "没有匹配的漫画站点")
                            .font(.footnote).foregroundStyle(.secondary).padding(16)
                    }
                    Color.clear.frame(height: 16)
                }
            }
            .accessibilityIdentifier("home.source.manga")
            .task(id: revision) { await loadLists() }
        }
    }

    private func source(_ entry: MangaRepositoryEntry) -> some View {
        let installed = store.sources.first { $0.key == entry.key }
        let chosen = selected && entry.key == store.currentSource?.key
        return Button { if let installed { pick(installed.key) } } label: {
            HStack(spacing: 9) {
                MonogramIcon(seed: entry.name, label: SourceLabel(entry.name), size: 34, systemImage: "book.closed")
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if installed == nil {
                        Text(loading || !store.preparingRepositories.isEmpty ? "正在准备…" : "暂不可用，请更新订阅")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if chosen { Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.accent) }
            }.padding(10).frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }.tileButton().disabled(installed == nil)
            .accessibilityIdentifier("home.source.manga." + entry.id)
            .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func loadLists() async {
        let id = UUID()
        loadID = id
        loading = true; failure = nil
        defer { if loadID == id { loading = false; loadID = nil } }
        for repository in store.repositories {
            do {
                if refresh == 0, !(store.repositoryEntries[repository.absoluteString] ?? []).isEmpty {
                    try await store.prepareRepository(repository)
                } else { try await store.refreshRepository(repository) }
                if store.repositoryErrors[repository.absoluteString]?.isEmpty == false {
                    failure = "部分漫画站点暂时无法准备，可重新加载订阅重试。"
                }
            }
            catch {
                guard !Task.isCancelled, loadID == id else { return }
                failure = MangaSources.title(of: repository) + "：" + error.mangaMessage
            }
            if Task.isCancelled || loadID != id { return }
        }
    }
}
#endif
