import Foundation
import Darwin

/// App 與廣播擴展共用的程序鎖。程序退出時 OS 自動釋放，不使用可能殘留的布林旗標。
final class CaptureLease: @unchecked Sendable {
    private let descriptor: Int32
    private init(descriptor: Int32) { self.descriptor = descriptor }
    static func acquire() throws -> CaptureLease {
        // 有 App Group 時用它做跨程序鎖；側載（無 App Group）退回 app 自身暫存目錄，
        // 此時只具程序內意義，但不應因此讓 UI 永久停用或無法啟動直播。
        let lockURL: URL
        if let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.nuclear.liveAPP") {
            lockURL = directory.appendingPathComponent("capture-session.lock")
        } else {
            lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("capture-session.lock")
        }
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw NSError(domain: "Capture", code: 2, userInfo: [NSLocalizedDescriptionKey: "已有擷取工作正在執行，請先停止目前的直播"])
        }
        return CaptureLease(descriptor: descriptor)
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
