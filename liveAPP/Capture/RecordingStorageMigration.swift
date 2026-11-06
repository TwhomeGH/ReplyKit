import Foundation

/// 將私有錄影庫搬到 Documents；同一磁碟以目錄搬移避免複製整場影片的額外空間。
enum RecordingStorageMigration {
    struct Result {
        let readableDirectories: [URL]
        let warning: String?
    }

    /// 不覆蓋已有目錄；失敗時保留舊路徑供 App 播放／分享，並明確提示尚未公開。
    /// - Parameters:
    ///   - legacy: 舊 Application Support 錄影目錄。
    ///   - destination: 新 Documents 錄影目錄。
    /// - Returns: 可讀目錄與需要顯示的搬移警告。
    static func migrate(legacy: URL, destination: URL) -> Result {
        let fm = FileManager.default
        let previous = destination.appendingPathComponent("PreviousLibrary", isDirectory: true)
        var warning: String?
        do {
            if fm.fileExists(atPath: legacy.path) {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fm.fileExists(atPath: destination.path) {
                    try fm.moveItem(at: legacy, to: destination)
                } else if !fm.fileExists(atPath: previous.path) {
                    try fm.moveItem(at: legacy, to: previous)
                } else {
                    throw NSError(domain: "RecordingStorage", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "新舊錄影目錄均已存在，未覆蓋任何檔案"])
                }
            }
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            warning = "部分舊錄影尚未搬到檔案共享目錄，請先在 App 匯出再刪除 App：\(error.localizedDescription)"
        }
        return Result(readableDirectories: [destination, previous, legacy].filter {
            fm.fileExists(atPath: $0.path)
        }, warning: warning)
    }
}
