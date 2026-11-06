import Foundation

/// 小型設定檔的原子寫入與保留政策；只處理本功能固定命名的檔案。
enum SettingsBackupStorage {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ConfigBackups", isDirectory: true)
    }
    static var pendingURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingSettingsRestore.json")
    }

    /// 保存目前與前一份自動備份；寫入失敗不覆蓋原檔，保留空間固定有界。
    static func save(_ document: SettingsBackupDocument, name: String = "settings-latest.json",
                     directory: URL = SettingsBackupStorage.directory) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(name)
        let data = try document.encoded()
        if name == "settings-latest.json", fm.fileExists(atPath: destination.path) {
            let old = try readData(destination)
            try old.write(to: directory.appendingPathComponent("settings-previous.json"), options: .atomic)
        }
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// 受控大小的讀取；限額同時套用於分享檔與待還原檔。
    static func read(_ url: URL) throws -> SettingsBackupDocument {
        try SettingsBackupDocument.decode(readData(url))
    }

    /// 檔案分享目錄可由外部修改；輪替舊檔也必須遵守讀取上限。
    private static func readData(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 2_097_153) ?? Data()
        guard data.count <= 2_097_152 else { throw SettingsBackupError.invalid("檔案超過 2 MB") }
        return data
    }

    /// 在任何共享偏好被讀取前套用已確認的還原。失敗保留待還原檔供重試。
    /// 不存取 userDefaults 全域，避免初始化遞迴。
    static func restorePending(shared: UserDefaults, standard: UserDefaults) {
        let url = pendingURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            #if os(iOS)
            // 確認後到重啟之間可能又啟動擴展；套用當下再取得互斥鎖。
            let lease = try CaptureLease.acquire()
            defer { withExtendedLifetime(lease) {} }
            #endif
            let document = try read(url)
            try SettingsBackupRegistry.apply(document, shared: shared, standard: standard)
            try FileManager.default.removeItem(at: url)
            standard.set("設定已還原；未包含的項目維持原值。", forKey: "settingsRestoreResult")
        } catch {
            standard.set("設定還原失敗：\(error.localizedDescription)", forKey: "settingsRestoreResult")
        }
    }
}
