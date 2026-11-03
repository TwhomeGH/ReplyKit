import Foundation
import Darwin

/// App 與擴展協調不可變日誌的發布、匯入和清理；不鎖主 log.txt。
enum SealedLogAccess {
    /// 同一目錄的所有參與者必須遵守此排他鎖；檔案描述符結束即釋放。
    static func withLock<T>(directory: URL, body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("handoff.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
