#if os(iOS)
import Foundation
import TVCore
import Perception

@MainActor enum LocalBackupCoordinator {
    private struct RestoreJournal: Codable {
        let value: LocalBackupPayload
        let categories: Set<LocalBackupCategory>
        let liveSnapshot: Data?
    }

    private static var recoveryInProgress = false
    private static var directory: URL { URL.applicationSupportDirectory.appendingPathComponent("LocalBackups", isDirectory: true) }
    private static var undoFile: URL { directory.appendingPathComponent("undo.json") }
    private static var pendingFile: URL { directory.appendingPathComponent("pending.json") }
    static var undoAvailable: Bool { FileManager.default.fileExists(atPath: undoFile.path) }

    static func snapshot(_ store: Store, portable: Bool,
                         categories: Set<LocalBackupCategory> = Set(LocalBackupCategory.allCases)) async throws -> LocalBackupPayload {
        var value = LocalBackupPayload()
        func encode<T: Encodable>(_ item: T) throws -> Data {
            let data = try JSONEncoder().encode(item)
            return portable ? try LocalBackupArchive.portable(data) : data
        }
        if categories.contains(.history) { value.history = try store.playbackHistory.entries.map { try encode($0) } }
        if categories.contains(.favorites) { value.favorites = try store.favorites.items.map { try encode($0) } }
        if categories.contains(.settings) {
            for (key, item) in store.backupDefaults.dictionaryRepresentation() where LocalBackupArchive.isAllowedSetting(key) {
                value.settings[key] = try PropertyListSerialization.data(fromPropertyList: ["value": item], format: .binary, options: 0)
            }
        }
        if categories.contains(.sources) {
            value.subscriptions = try encode(store.subscriptions)
            let portableEntries = try JSONDecoder().decode([SubscriptionEntry].self, from: value.subscriptions)
            let groups = Dictionary(zip(store.subscriptions, portableEntries).map { original, saved in
                (saved.address, store.localSourceGroups[original.address] ?? .subscription)
            }, uniquingKeysWith: { first, _ in first })
            value.sourceGroups = try JSONEncoder().encode(groups)
            value.sources = try await LocalSourceLibrary.shared.backupSources(portable: portable)
            if !portable { value.documents = try store.documents.mapValues { try JSONEncoder().encode($0) } }
        }
        if portable && categories.contains(.liveSubscriptions) {
            value.liveSubscriptions = try IPTVLibrary.shared.portableRecords().map { try JSONEncoder().encode($0) }
        }
        return value
    }
    static func export(_ store: Store) async throws -> Data {
        let value = try await snapshot(store, portable: true)
        try validate(value)
        return try LocalBackupArchive(value).encoded()
    }
    static func inspect(_ data: Data) throws -> (LocalBackupArchive, LocalBackupPayload) {
        let result = try LocalBackupArchive.read(data)
        try validate(result.1)
        return result
    }
    private static func validate(_ value: LocalBackupPayload, categories: Set<LocalBackupCategory> = Set(LocalBackupCategory.allCases)) throws {
        let decoder = JSONDecoder()
        for row in value.history {
            let item = try decoder.decode(PlaybackHistoryEntry.self, from: row)
            guard item.position.isFinite, item.position >= 0, item.duration.isFinite, item.duration >= 0,
                  !item.context.sourceKey.isEmpty, !item.context.videoID.isEmpty else { throw LocalBackupArchive.Failure.invalid }
        }
        for row in value.favorites { _ = try decoder.decode(FavoriteItem.self, from: row) }
        if categories.contains(.sources) {
            let entries = try decoder.decode([SubscriptionEntry].self, from: value.subscriptions)
            _ = try decoder.decode([String: LocalSourceGroup].self, from: value.sourceGroups)
            guard entries.count <= 500, Set(entries.map(\.address)).count == entries.count,
                  entries.allSatisfy({ URL(string: $0.address) != nil }) else { throw LocalBackupArchive.Failure.invalid }
            _ = try LocalSourceLibrary.validateBackupSources(value.sources)
            for (_, data) in value.documents { _ = try decoder.decode(Subscription.self, from: data) }
        }
        if let records = value.liveSubscriptions {
            try IPTVLibrary.validatePortable(records.map { try decoder.decode(IPTVRecord.self, from: $0) })
        }
        for (key, bytes) in value.settings {
            guard LocalBackupArchive.isAllowedSetting(key),
                  let item = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any],
                  let content = item["value"] else { throw LocalBackupArchive.Failure.invalid }
            if let number = content as? NSNumber, !number.doubleValue.isFinite { throw LocalBackupArchive.Failure.invalid }
            if let data = content as? Data, data.count > 1024 * 1024 { throw LocalBackupArchive.Failure.invalid }
            if let string = content as? String, string.count > 32_768 { throw LocalBackupArchive.Failure.invalid }
        }
    }
    static func restore(_ incoming: LocalBackupPayload, categories: Set<LocalBackupCategory>, replacing: Bool, store: Store) async throws {
        let categories = categories.intersection(incoming.restoreCategories)
        guard !categories.isEmpty else { return }
        try validate(incoming)
        try beginRestore(store)
        defer { finishRestore(store) }
        store.stopForBackupRestore()
        let before = try await makeJournal(store, categories: categories)
        try await transaction(before: before, store: store) {
            try await apply(incoming, categories: categories, replacing: replacing, activate: false, store: store)
        }
    }
    static func undo(_ store: Store) async throws {
        let previous = try readJournal(undoFile)
        try beginRestore(store)
        defer { finishRestore(store) }
        store.stopForBackupRestore()
        let before = try await makeJournal(store, categories: previous.categories)
        try await transaction(before: before, store: store) {
            try await applyJournal(previous, store: store)
        }
        try FileManager.default.removeItem(at: undoFile)
    }
    static func recover(_ store: Store) async -> Bool {
        guard !recoveryInProgress, !store.restoringBackup || store.backupRecoveryRequired else { return false }
        guard FileManager.default.fileExists(atPath: pendingFile.path) else {
            if store.backupRecoveryRequired { finishRestore(store) }
            return true
        }
        recoveryInProgress = true
        defer { recoveryInProgress = false }
        do {
            let previous = try readJournal(pendingFile)
            if !store.restoringBackup { try beginRestore(store) }
            store.cloudSync?.suspendForLocalRestore(true)
            try await applyJournal(previous, store: store)
            try synchronizeDefaults(store)
            try FileManager.default.removeItem(at: pendingFile)
            finishRestore(store)
            return true
        } catch {
            store.importing = true; store.restoringBackup = true
            store.backupRecoveryRequired = true
            store.cloudSync?.suspendForLocalRestore(true)
            store.error = "上次恢复未完成，原始数据日志已保留。请到设置的备份迁移页面重试恢复：" + error.localizedDescription
            return false
        }
    }
    private static func beginRestore(_ store: Store) throws {
        guard !store.importing, !store.restoringBackup else {
            throw NSError(domain: "LocalBackup", code: 4, userInfo: [NSLocalizedDescriptionKey: "来源正在导入或更新，请完成后再恢复备份。"])
        }
        store.importing = true; store.restoringBackup = true
        store.cloudSync?.suspendForLocalRestore(true)
    }
    private static func finishRestore(_ store: Store) {
        let pending = FileManager.default.fileExists(atPath: pendingFile.path)
        store.importing = pending; store.restoringBackup = pending; store.backupRecoveryRequired = pending
        store.cloudSync?.suspendForLocalRestore(pending)
        if pending { store.error = "备份恢复尚未完成，已暂停数据修改与同步。请重试恢复，原始日志已保留。" }
    }
    private static func synchronizeDefaults(_ store: Store) throws {
        guard store.backupDefaults.synchronize() else {
            throw NSError(domain: "LocalBackup", code: 5, userInfo: [NSLocalizedDescriptionKey: "备份设置尚未写入存储，恢复日志已保留。"])
        }
    }
    private static func makeJournal(_ store: Store, categories: Set<LocalBackupCategory>) async throws -> RestoreJournal {
        let value = try await snapshot(store, portable: false, categories: categories)
        let liveSnapshot = categories.contains(.liveSubscriptions) ? try IPTVLibrary.shared.privateSnapshot() : nil
        return RestoreJournal(value: value, categories: categories, liveSnapshot: liveSnapshot)
    }
    private static func readJournal(_ file: URL) throws -> RestoreJournal {
        let bytes = try Data(contentsOf: file)
        let decoder = JSONDecoder()
        let journal: RestoreJournal
        if let scoped = try? decoder.decode(RestoreJournal.self, from: bytes) {
            journal = scoped
        } else {
            let legacy = try decoder.decode(LocalBackupPayload.self, from: bytes)
            journal = RestoreJournal(value: legacy, categories: [.sources, .history, .favorites, .settings], liveSnapshot: nil)
        }
        guard !journal.categories.isEmpty, journal.categories.contains(.liveSubscriptions) == (journal.liveSnapshot != nil) else {
            throw LocalBackupArchive.Failure.invalid
        }
        try validate(journal.value, categories: journal.categories)
        return journal
    }
    private static func applyJournal(_ journal: RestoreJournal, store: Store) async throws {
        try await apply(journal.value, categories: journal.categories, replacing: true, activate: true,
                        liveSnapshot: journal.liveSnapshot, store: store)
    }
    private static func transaction(before: RestoreJournal, store: Store, operation: () async throws -> Void) async throws {
        guard !FileManager.default.fileExists(atPath: pendingFile.path) else {
            throw NSError(domain: "LocalBackup", code: 3, userInfo: [NSLocalizedDescriptionKey: "上次恢复日志尚未处理完成，请重新打开应用后重试。原始数据恢复日志已保留。"])
        }
        var journalDirectory = directory
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try journalDirectory.setResourceValues(resourceValues)
        let bytes = try JSONEncoder().encode(before)
        try writeJournal(bytes, to: pendingFile)
        do {
            try await operation()
            try synchronizeDefaults(store)
            try writeJournal(bytes, to: undoFile)
            try FileManager.default.removeItem(at: pendingFile)
        } catch {
            let original = error
            do {
                try await applyJournal(before, store: store)
                try synchronizeDefaults(store)
                try FileManager.default.removeItem(at: pendingFile)
            } catch { throw error }
            throw original
        }
    }
    private static func writeJournal(_ bytes: Data, to file: URL) throws {
        try bytes.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private static func apply(_ value: LocalBackupPayload, categories: Set<LocalBackupCategory>, replacing: Bool,
                              activate: Bool, liveSnapshot: Data? = nil, store: Store) async throws {
        let decoder = JSONDecoder()
        if categories.contains(.liveSubscriptions) {
            if let liveSnapshot {
                try IPTVLibrary.shared.restorePrivate(liveSnapshot)
            } else if let records = value.liveSubscriptions {
                try IPTVLibrary.shared.restorePortable(records.map { try decoder.decode(IPTVRecord.self, from: $0) }, replace: replacing)
            }
        }
        if categories.contains(.sources) {
            try await LocalSourceLibrary.shared.restoreBackupSources(value.sources, replacing: replacing)
            try store.applyBackupSubscriptions(decoder.decode([SubscriptionEntry].self, from: value.subscriptions),
                groups: decoder.decode([String: LocalSourceGroup].self, from: value.sourceGroups), replacing: replacing, activate: activate,
                restoredDocuments: activate ? try value.documents.mapValues { try decoder.decode(Subscription.self, from: $0) } : nil)
        }
        if categories.contains(.history) {
            let incoming = try value.history.map { try decoder.decode(PlaybackHistoryEntry.self, from: $0) }
            var rows = replacing ? [:] : Dictionary(store.playbackHistory.entries.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })
            for row in incoming where rows[row.id] == nil || rows[row.id]!.updatedAt < row.updatedAt { rows[row.id] = row }
            store.playbackHistory.adopt(Array(rows.values))
            guard await store.playbackHistory.flushPersistence() else {
                throw NSError(domain: "LocalBackup", code: 1, userInfo: [NSLocalizedDescriptionKey: store.playbackHistory.persistenceError ?? "历史记录尚未写入存储，恢复日志已保留。"])
            }
            store.cloudSync?.changed("history")
        }
        if categories.contains(.favorites) {
            let incoming = try value.favorites.map { try decoder.decode(FavoriteItem.self, from: $0) }
            var items = replacing ? [] : store.favorites.items
            for item in incoming where !items.contains(where: { $0.key == item.key }) { items.append(item) }
            store.favorites.adopt(items.enumerated().map { CloudSyncItem(id: $0.element.key, value: $0.element, stamp: Date(timeIntervalSince1970: Double(items.count - $0.offset))) })
            if let error = store.favorites.persistenceError { throw NSError(domain: "LocalBackup", code: 2, userInfo: [NSLocalizedDescriptionKey: error]) }
            store.cloudSync?.changed("favorites")
        }
        if categories.contains(.settings) {
            if replacing { for key in store.backupDefaults.dictionaryRepresentation().keys where LocalBackupArchive.isAllowedSetting(key) { store.backupDefaults.removeObject(forKey: key) } }
            for (key, data) in value.settings {
                let item = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as! [String: Any]
                store.backupDefaults.set(item["value"], forKey: key)
            }
            store.autoPlayNext = store.backupDefaults.object(forKey: "autoPlayNextEpisode") as? Bool ?? true
            store.backupDefaults.removeObject(forKey: "local.hiddenFeatures")
        }
    }
}
#endif
