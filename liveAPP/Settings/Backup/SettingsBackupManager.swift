import Foundation
import Combine
import UIKit
import ReplayKit

/// 全 App 單一備份排程；兩秒合併偏好通知，內容未改變不重寫檔案。
@MainActor
final class SettingsBackupManager: ObservableObject {
    static let shared = SettingsBackupManager()
    @Published private(set) var lastSaved: Date?
    @Published private(set) var message: String?
    @Published private(set) var files: [URL] = []
    @Published private(set) var restorePending = false
    private var observers: [NSObjectProtocol] = []
    private var scheduled: Task<Void, Never>?
    private var lastContent: Data?
    /// 收到偏好變更才需要在下一次背景／節流到期時實際檢查內容。
    private var needsSave = true

    /// 只註冊一次；背景前補存已收到的偏好，凍結期間不假裝能執行備份。
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.schedule() }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.saveAutomatic() }
        })
        message = UserDefaults.standard.string(forKey: "settingsRestoreResult")
        refresh()
        schedule()
    }

    /// 節流而非無限延後：連續操作仍約每兩秒檢查一次設定快照。
    private func schedule() {
        needsSave = true
        guard scheduled == nil else { return }
        scheduled = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            self?.scheduled = nil
            self?.saveAutomatic()
        }
    }

    /// 自動備份不含網址／金鑰。失敗可見且記錄，不以成功時間掩蓋失敗。
    func saveAutomatic() {
        scheduled?.cancel()
        scheduled = nil
        // 還原待下次啟動期間保留確認時的備份，不用舊服務狀態覆蓋它。
        guard !restorePending else { return }
        let latest = SettingsBackupStorage.directory.appendingPathComponent("settings-latest.json")
        // 沒有待存變更、已有內容快取且檔案還在時，前景／背景反覆切換不必重新 capture。
        guard needsSave || lastContent == nil || !FileManager.default.fileExists(atPath: latest.path) else {
            return
        }
        do {
            let document = try SettingsBackupRegistry.capture(shared: userDefaults ?? .standard,
                standard: .standard, includesSecrets: false)
            let content = try JSONSerialization.data(withJSONObject: ["shared": document.shared,
                "standard": document.standard], options: [.sortedKeys])
            if lastContent == nil, FileManager.default.fileExists(atPath: latest.path) {
                do {
                    let previous = try SettingsBackupStorage.read(latest)
                    lastContent = try JSONSerialization.data(withJSONObject: ["shared": previous.shared,
                        "standard": previous.standard], options: [.sortedKeys])
                } catch {
                    // 損壞的舊檔仍由 save 保留為 previous，不能永久阻止新的有效備份。
                    report(error)
                }
            }
            guard content != lastContent || !FileManager.default.fileExists(atPath: latest.path) else {
                lastContent = content
                needsSave = false
                return
            }
            _ = try SettingsBackupStorage.save(document)
            lastContent = content
            needsSave = false
            lastSaved = document.createdAt
            refresh()
        } catch { report(error) }
    }

    /// 明確匯出才允許帶入敏感設定；固定輸出名稱避免每次分享無限堆積。
    func export(includesSecrets: Bool) throws -> URL {
        let document = try SettingsBackupRegistry.capture(shared: userDefaults ?? .standard,
            standard: .standard, includesSecrets: includesSecrets)
        let url = try SettingsBackupStorage.save(document,
            name: includesSecrets ? "settings-export-sensitive.json" : "settings-export.json")
        refresh()
        return url
    }

    /// 確認後只寫入待還原檔，避免已運行的服務讀到混合的新舊設定。
    func stageRestore(_ document: SettingsBackupDocument) throws {
        guard !CaptureCoordinator.shared.isBusy, !VideoCompressionModel.shared.busy,
              !RPScreenRecorder.shared().isRecording,
              PIPService.diagnosticInstance?.isRunningOrStarting != true,
              !PIPTestService.shared.isRunning else {
            throw SettingsBackupError.invalid("請先停止擷取、壓縮與 PiP")
        }
        if let snapshot = StreamDiagnosticsModel.shared.snapshots["ReplayKit"],
           Date().timeIntervalSince(snapshot.sampledAt) < 15,
           snapshot.phase.lowercased().contains("publishing") {
            throw SettingsBackupError.invalid("請先停止 ReplayKit 直播")
        }
        // 即使主 App 未收到擴展回報，有 App Group 時仍由程序鎖阻止直播中還原。
        let lease = try CaptureLease.acquire()
        defer { withExtendedLifetime(lease) {} }
        try SettingsBackupRegistry.validate(document)
        let current = try SettingsBackupRegistry.capture(shared: userDefaults ?? .standard,
            standard: .standard, includesSecrets: document.includesSecrets)
        _ = try SettingsBackupStorage.save(current, name: "settings-before-restore.json")
        let url = SettingsBackupStorage.pendingURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try document.encoded().write(to: url, options: .atomic)
        restorePending = true
        message = "已排定還原。請完整關閉 App 後重新開啟；重新開啟前不要再修改設定。"
        refresh()
    }

    /// 重新掃描本功能已知檔名；不列出或刪除使用者自行放入的檔案。
    func refresh() {
        let directory = SettingsBackupStorage.directory
        let names = ["settings-latest.json", "settings-previous.json", "settings-before-restore.json",
                     "settings-export.json", "settings-export-sensitive.json"]
        files = names.map { directory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        restorePending = FileManager.default.fileExists(atPath: SettingsBackupStorage.pendingURL.path)
        let latest = directory.appendingPathComponent("settings-latest.json")
        if FileManager.default.fileExists(atPath: latest.path) {
            do { lastSaved = try SettingsBackupStorage.read(latest).createdAt }
            catch { report(error) }
        } else { lastSaved = nil }
    }

    /// 撤回尚未套用的還原，不修改任何現有設定或備份。
    func cancelRestore() throws {
        try FileManager.default.removeItem(at: SettingsBackupStorage.pendingURL)
        refresh()
        message = "已取消待還原設定。"
    }

    func report(_ error: Error) {
        message = error.localizedDescription
        let detail = error as NSError
        sendlog(title: "設定備份", message: "作業失敗 domain=\(detail.domain) code=\(detail.code)，詳情請查看備份頁")
    }
}
