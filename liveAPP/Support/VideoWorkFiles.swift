import Foundation

/// 僅管理本功能專屬暫存；目前程序目錄永不列為可回收，避免刪除進行中的任務。
enum VideoWorkFiles {
    static let session = UUID().uuidString
    static var root: URL { FileManager.default.temporaryDirectory.appendingPathComponent("ManagedVideoWork", isDirectory: true) }

    /// 建立本程序的暫存路徑；分類限由程式內部傳入。
    static func makeURL(kind: String, extension ext: String) throws -> URL {
        let folder = root.appendingPathComponent(session).appendingPathComponent(kind)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    /// 清理失敗必須可見；已移至成品位置的暫存不存在屬正常情況。
    @discardableResult
    static func discard(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do { try FileManager.default.removeItem(at: url); return true }
        catch { sendlog(message: "[VideoStorage] cleanup failed file=\(url.lastPathComponent) error=\(error)"); return false }
    }

    /// 回傳前次程序的專屬目錄，拒絕符號連結與未知名稱。
    static func abandoned() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).filter {
            let values = try $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return $0.lastPathComponent != session && UUID(uuidString: $0.lastPathComponent) != nil && values.isDirectory == true && values.isSymbolicLink != true
        }
    }

    /// 統計實際檔案大小；不跟隨符號連結，不將結果視為整個 App 空間。
    static func bytes(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        if values.isSymbolicLink == true { return 0 }
        if values.isDirectory != true { return Int64(values.fileSize ?? 0) }
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).reduce(0) { try $0 + bytes(at: $1) }
    }
}
