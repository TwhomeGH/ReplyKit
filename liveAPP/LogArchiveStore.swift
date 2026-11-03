import Foundation

/// 主 App 的不可變日誌封存；所有操作由 AppLogPersister queue 呼叫。
enum LogArchiveStore {
    static func directory(beside log: URL) throws -> URL {
        let root = log.deletingLastPathComponent().appendingPathComponent("LogArchives", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 名稱以前置時間排序；UUID 防止同毫秒輪替或跨程序交接碰撞。
    static func name(prefix: String) -> String {
        String(format: "%020.0f", Date().timeIntervalSince1970 * 1000) + "-" + prefix + "-" + UUID().uuidString + ".log"
    }

    static func files(in root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            .filter { url in
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return url.pathExtension == "log" && values.isRegularFile == true && values.isSymbolicLink != true
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 封存有容量上限，清理最舊檔並持久化缺口摘要，不能宣稱無限保存整場。
    static func prune(_ root: URL) throws {
        let entries = try files(in: root)
        var total: Int64 = 0
        var sizes: [URL: Int64] = [:]
        for url in entries {
            let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            sizes[url] = size
            total += size
        }
        for url in entries {
            let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantFuture
            guard total > 256 * 1024 * 1024 || modified < Date().addingTimeInterval(-7 * 86400) else { continue }
            // 先記錄將清理的範圍，當程序中途停止時也不會假裝歷史完整。
            let notice = "封存保留上限：最近清理（或準備清理）的檔案 \(url.lastPathComponent)，時間 \(Date())。更早歷史可能已不可用。"
            try Data(notice.utf8).write(to: root.appendingPathComponent("retention-notice.txt"), options: .atomic)
            try FileManager.default.removeItem(at: url)
            total -= sizes[url] ?? 0
        }
    }
}
