import Foundation
import Darwin

/// App 與廣播擴展共用的程序鎖。程序退出時 OS 自動釋放，不使用可能殘留的布林旗標。
final class CaptureLease: @unchecked Sendable {
    private let descriptor: Int32
    private init(descriptor: Int32) { self.descriptor = descriptor }
    static func acquire() throws -> CaptureLease {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.nuclear.liveAPP") else {
            throw NSError(domain: "Capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "無法存取直播共用空間"])
        }
        let descriptor = open(directory.appendingPathComponent("capture-session.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw NSError(domain: "Capture", code: 2, userInfo: [NSLocalizedDescriptionKey: "已有擷取工作正在執行，請先停止目前的直播"])
        }
        return CaptureLease(descriptor: descriptor)
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
