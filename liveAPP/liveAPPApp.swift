//
//  liveAPPApp.swift
//  liveAPP
//
//  Created by user on 2025/8/24.
//

import SwiftUI

import UserNotifications
import AVFoundation
import Combine
#if os(iOS)
import BackgroundTasks
#endif

#if os(iOS)
import UIKit
import CoreMotion
#elseif os(macOS)
import AppKit
#endif



//
//  Event.swift
//  liveAPP
//
//  Created by user on 2025/9/13.

import os
import Foundation

extension Notification.Name {
    static let appLogNotification = Notification.Name("appLogNotification")
}

// 每個 log 項目
struct LogItem: Identifiable, Hashable {
    let id = UUID()
    let message: String
    let presentation: LogPresentation
    init(message: String) {
        self.message = message
        presentation = LogPresentation(message)
    }
}



// MARK: 日誌緩衝區
final class LogBuffer {
    static let shared = LogBuffer()

    private let queue = DispatchQueue(label: "log.buffer.queue")
    private var buffer: [String] = []
    private var flushWorkItem: DispatchWorkItem?
    private let flushDelay: TimeInterval = 0.05
    private let batchLimit = 100
    private let maxBufferSize = 5000

    var onNewLog: (([String]) -> Void)?

    func push(_ msg: String) {
        queue.async {
            self.buffer.append(msg)
            self.trimIfNeededLocked()
            self.scheduleFlushLocked()
        }
    }

    func push(_ messages: [String]) {
        guard !messages.isEmpty else { return }

        queue.async {
            self.buffer.append(contentsOf: messages)
            self.trimIfNeededLocked()
            self.scheduleFlushLocked()
        }
    }

    private func trimIfNeededLocked() {
        guard buffer.count > maxBufferSize else { return }
        let excess = buffer.count - maxBufferSize
        buffer.removeFirst(excess)
    }

    private func scheduleFlushLocked() {
        guard flushWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            self?.flushLocked()
        }
        flushWorkItem = workItem
        queue.asyncAfter(deadline: .now() + flushDelay, execute: workItem)
    }

    private func flushLocked() {
        flushWorkItem = nil
        guard !buffer.isEmpty else { return }

        let count = min(batchLimit, buffer.count)
        let logs = Array(buffer.prefix(count))
        buffer.removeFirst(count)

        DispatchQueue.main.async {
            self.onNewLog?(logs)
        }

        if !buffer.isEmpty {
            scheduleFlushLocked()
        }

    }

    func clear() {
        queue.async {
            self.flushWorkItem?.cancel()
            self.flushWorkItem = nil
            self.buffer.removeAll()
        }
    }
}


// MARK: - Documents 日誌持久化（供檔案 App 讀取）
/// 檔案 handle、待寫內容與歷史索引僅由 queue 存取。
/// 跨執行緒的統計快照另由 statisticsLock 保護；新增公開狀態時須維持此隔離契約。
final class AppLogPersister: @unchecked Sendable {
    static let shared = AppLogPersister()
    private let queue = DispatchQueue(label: "liveApp.logPersister", qos: .utility)
    private let historyReader = LogFileReader()
    func historyPage(start: Int? = nil, generation: Int? = nil) async throws -> LogFilePage {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.historyReader.page(url: self.logURL, start: start, expectedGeneration: generation)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    /// 在寫入佇列 flush 後複製快照，避免清空或追加造成範圍匯出混用版本。
    /// 僅管理 Caches/DiagnosticLogExports 的 UUID 工作目錄；七天前的匯出快取可清理。
    func diagnosticSnapshot() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    self.flushPending()
                    guard self.pendingLines.isEmpty, self.lastFlushSucceeded else {
                        throw NSError(domain: "LogExport", code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "日誌最近一次寫入失敗或仍待重試，請查看日誌 I/O 診斷後再匯出。"])
                    }
                    let manager = FileManager.default
                    let root = try manager.url(for: .cachesDirectory, in: .userDomainMask,
                        appropriateFor: nil, create: true).appendingPathComponent("DiagnosticLogExports", isDirectory: true)
                    try manager.createDirectory(at: root, withIntermediateDirectories: true)
                    for folder in try manager.contentsOfDirectory(at: root,
                        includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey]) {
                        let info = try folder.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey])
                        if UUID(uuidString: folder.lastPathComponent) != nil, info.isDirectory == true,
                           info.isSymbolicLink != true, let date = info.creationDate,
                           date < Date().addingTimeInterval(-7 * 86400) {
                            do { try manager.removeItem(at: folder) }
                            catch { NSLog("Diagnostic export cleanup failed: %@", error.localizedDescription) }
                        }
                    }
                    let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                    let snapshot = folder.appendingPathComponent("source.snapshot")
                    try self.importSealedExtensionLogs()
                    let archive = try LogArchiveStore.directory(beside: self.logURL)
                    var sources = try LogArchiveStore.files(in: archive)
                    if manager.fileExists(atPath: self.logURL.path) { sources.append(self.logURL) }
                    try Data().write(to: snapshot)
                    let output = try FileHandle(forWritingTo: snapshot)
                    defer { try? output.close() }
                    for noticeName in ["retention-notice.txt", "extension-retention-notice.txt"] {
                    let noticeURL = archive.appendingPathComponent(noticeName)
                    if manager.fileExists(atPath: noticeURL.path) {
                        let notice = try String(contentsOf: noticeURL, encoding: .utf8)
                        try output.write(contentsOf: Data(("[Retention] " + notice + "\n").utf8))
                    }
                    }
                    // 舊版活動檔只讀不清空，避免破壞可能仍在執行的舊擴展。
                    if let group = manager.containerURL(forSecurityApplicationGroupIdentifier: "group.nuclear.liveAPP") {
                        for name in ["early-log.txt", "log.txt"] {
                            let legacy = group.appendingPathComponent(name)
                            if manager.fileExists(atPath: legacy.path) { sources.append(legacy) }
                        }
                    }
                    for source in sources {
                        try output.write(contentsOf: Data("\n[ArchiveBoundary]\n".utf8))
                        let input = try FileHandle(forReadingFrom: source)
                        defer { try? input.close() }
                        var remaining = try input.seekToEnd()
                        try input.seek(toOffset: 0)
                        while remaining > 0 {
                            guard let data = try input.read(upToCount: Int(min(remaining, 65536))), !data.isEmpty else {
                                throw CocoaError(.fileReadCorruptFile)
                            }
                            try output.write(contentsOf: data)
                            remaining -= UInt64(data.count)
                        }
                    }
                    try output.synchronize()
                    continuation.resume(returning: snapshot)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private let logFileName = "log.txt"
    private let maxLogFileLines = 5000
    private let trimMargin = 2000

    // 記憶體累積 + 批次 flush：不再「每筆 log 開檔寫入」。
    // 累積滿 batchThreshold 筆或超過 flushDelay 秒（先到先 flush），
    // 一次 FileHandle.write 寫入整批，避免高頻單筆 open/seek/write/close。
    private var pendingLines: [String] = []
    private let batchThreshold = 50
    private let flushDelay: TimeInterval = 0.5
    private var flushWorkItem: DispatchWorkItem?

    // 持久化寫入 handle：啟動/首次寫入時 open 一次，重複使用，
    // clear/輪替前會關閉，下一批重新開啟；背景連續寫入重用，閒置才關閉。
    private var writeHandle: FileHandle?

    private var estimatedLineCount = 0
    private var estimatedFileBytes = 0
    private let maxFileBytes = 8 * 1024 * 1024
    private let maxPendingBytes = 2 * 1024 * 1024
    private var lastFlushSucceeded = true
    private var retryCount = 0
    private var retryScheduled = false
    private var closeAfterFlush = false
    private var idleCloseItem: DispatchWorkItem?
    private var idleCloseGeneration = UUID()
    private var flushGeneration = UUID()

    private var logURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent(logFileName)
    }

    init() {
        queue.async { [weak self] in
            self?.calibrateLineCount()
        }
    }

    deinit {
        // singleton 通常不析構；不依賴此處落盤，也不 queue.sync 造成同佇列析構死鎖。
        flushWorkItem?.cancel()
        ioFailureFlushItem?.cancel()
        idleCloseItem?.cancel()
        try? writeHandle?.close()
    }

    /// 分塊校準實際檔案大小與換行數，不把啟動歷史整份載入記憶體。
    private func calibrateLineCount() {
        guard FileManager.default.fileExists(atPath: logURL.path) else { return }
        do {
            let handle = try FileHandle(forReadingFrom: logURL)
            defer { try? handle.close() }
            var bytes = 0, lines = 0
            while let data = try handle.read(upToCount: 65536), !data.isEmpty {
                bytes += data.count
                lines += data.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
            }
            estimatedFileBytes = bytes
            estimatedLineCount = lines
        } catch { recordIOFailure(context: "calibrate", lastError: String(describing: error)) }
    }

    func append(line: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingLines.append(line)
            self.scheduleFlushIfNeeded()
        }
    }

    func append(lines: [String]) {
        guard !lines.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingLines.append(contentsOf: lines)
            self.scheduleFlushIfNeeded()
        }
    }

    /// 排入立即寫入；呼叫返回不表示完成，也不保證程序被終止前所有資料已保存。
    func flushNow() {
        queue.async { [weak self] in self?.flushPending() }
    }

    /// 背景切換先嘗試寫入，十秒閒置才關檔；前景取消閒置關檔。
    /// 完成代表本次嘗試已結束；失敗另有帶外診斷，不保證作業系統不會提前終止。
    func setBackground(_ background: Bool) async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.closeAfterFlush = background
                self.idleCloseItem?.cancel()
                self.idleCloseGeneration = UUID()
                if background {
                    self.flushPending()
                    self.scheduleIdleClose()
                }
                continuation.resume()
            }
        }
    }

    /// 撤銷排程並更新世代；即使舊工作已排入佇列，也不能提早 flush 新批次。
    private func cancelScheduledFlush() {
        flushWorkItem?.cancel()
        flushWorkItem = nil
        flushGeneration = UUID()
        retryScheduled = false
    }

    private func scheduleFlushIfNeeded() {
        // 寫入故障期間維持有限記憶體；拒收的紀錄以帶外摘要計數，避免回饋日誌迴圈。
        var bytes = pendingLines.reduce(0) { $0 + $1.utf8.count + 1 }
        var dropped = 0
        while bytes > maxPendingBytes, let last = pendingLines.last {
            bytes -= last.utf8.count + 1
            pendingLines.removeLast()
            dropped += 1
        }
        if dropped > 0 { recordIOFailure(context: "buffer.drop", lastError: "droppedRecords=\(dropped)") }
        guard !pendingLines.isEmpty, !retryScheduled else { return }
        if pendingLines.count >= batchThreshold { flushPending(); return }
        scheduleFlush(after: flushDelay)
    }

    private func scheduleFlush(after delay: TimeInterval) {
        guard flushWorkItem == nil else { return }
        let generation = flushGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.flushGeneration == generation else { return }
            self.flushPending()
        }
        flushWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func flushPending() {
        cancelScheduledFlush()
        guard !pendingLines.isEmpty else { return }
        let data = Data((pendingLines.joined(separator: "\n") + "\n").utf8)
        lastFlushSucceeded = appendRaw(data)
        if lastFlushSucceeded {
            pendingLines.removeAll(keepingCapacity: true)
            retryCount = 0
            if estimatedLineCount > maxLogFileLines + trimMargin || estimatedFileBytes > maxFileBytes {
                trimNow()
            }
        } else {
            retryCount += 1
            if retryCount >= 3 || !lastWriteCanRetry {
                recordIOFailure(context: "write.drop", lastError: "droppedRecords=\(pendingLines.count) attempts=\(retryCount)")
                pendingLines.removeAll(keepingCapacity: true)
                retryCount = 0
            } else {
                retryScheduled = true
                scheduleFlush(after: 2)
            }
        }
        if closeAfterFlush { scheduleIdleClose() }
    }

    /// 背景持續寫入時重用 handle；十秒沒有成功批次才關閉。
    private func scheduleIdleClose() {
        idleCloseItem?.cancel()
        let generation = UUID()
        idleCloseGeneration = generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.closeAfterFlush, self.idleCloseGeneration == generation else { return }
            self.closeWriter(synchronize: true)
            self.idleCloseItem = nil
        }
        idleCloseItem = item
        queue.asyncAfter(deadline: .now() + 10, execute: item)
    }

    /// 關檔錯誤走帶外診斷；背景同步是低頻收尾，不逐筆強制同步磁碟。
    private func closeWriter(synchronize: Bool = false) {
        guard let handle = writeHandle else { return }
        writeHandle = nil
        if synchronize {
            do { try handle.synchronize() }
            catch { recordIOFailure(context: "synchronize", lastError: String(describing: error)) }
        }
        do { try handle.close() }
        catch { recordIOFailure(context: "close", lastError: String(describing: error)) }
    }

    /// 只接收新協定已完成的不可變批次；不截斷擴展活動檔。
    func copyFromAppGroup() {
        queue.async { [weak self] in
            guard let self else { return }
            do { try self.importSealedExtensionLogs() }
            catch { self.recordIOFailure(context: "archive.import", lastError: String(describing: error)) }
        }
    }

    /// 目的檔名即交接識別；當複製完成但尚未移除來源就終止，下次不重複匯入。
    private func importSealedExtensionLogs() throws {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.nuclear.liveAPP") else { return }
        let source = group.appendingPathComponent("SealedExtensionLogs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        do {
            let destination = try LogArchiveStore.directory(beside: logURL)
            try SealedLogAccess.withLock(directory: source) {
            let notice = source.appendingPathComponent("retention-notice.txt")
            if FileManager.default.fileExists(atPath: notice.path) {
                try Data(contentsOf: notice).write(to: destination.appendingPathComponent("extension-retention-notice.txt"), options: .atomic)
            }
            for file in try LogArchiveStore.files(in: source) {
                let target = destination.appendingPathComponent(file.lastPathComponent)
                if !FileManager.default.fileExists(atPath: target.path) {
                    // 先複製到非 log 暫存，再 rename 發布，避免殘缺副本被誤認為已完成。
                    let temporary = destination.appendingPathComponent(UUID().uuidString + ".pending")
                    defer {
                        if FileManager.default.fileExists(atPath: temporary.path) {
                            do { try FileManager.default.removeItem(at: temporary) }
                            catch { recordIOFailure(context: "archive.pendingCleanup", lastError: String(describing: error)) }
                        }
                    }
                    try FileManager.default.copyItem(at: file, to: temporary)
                    try FileManager.default.moveItem(at: temporary, to: target)
                }
                try FileManager.default.removeItem(at: file)
            }
            }
            try LogArchiveStore.prune(destination)
        } catch {
            recordIOFailure(context: "archive.import", lastError: String(describing: error))
            throw error
        }
    }

    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelScheduledFlush()
            self.retryCount = 0
            self.pendingLines.removeAll()
            self.truncateFile()
        }
    }

    private let statisticsLock = NSLock()
    private var writtenBytes: UInt64 = 0
    /// 提供 UI 讀取的累積寫入量；不直接暴露持久化佇列內的可變狀態。
    var totalWrittenBytes: UInt64 {
        statisticsLock.lock()
        defer { statisticsLock.unlock() }
        return writtenBytes
    }

    // MARK: log 寫入失敗的帶外診斷（有界摘要：每 ioFailureFlushDelay 秒最多一則）
    private var ioFailureCount = 0
    private var ioLastError: String?
    private var ioFailureFlushItem: DispatchWorkItem?
    private let ioFailureFlushDelay: TimeInterval = 60

    private func recordIOFailure(context: String, lastError: String) {
        ioFailureCount += 1
        ioLastError = "\(context): \(lastError)"
        guard ioFailureFlushItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.flushIOFailures()
        }
        ioFailureFlushItem = item
        queue.asyncAfter(deadline: .now() + ioFailureFlushDelay, execute: item)
    }

    private func flushIOFailures() {
        ioFailureFlushItem = nil
        guard ioFailureCount > 0 else { return }
        let count = ioFailureCount
        let last = ioLastError ?? ""
        ioFailureCount = 0
        ioLastError = nil
        let windowSec = Int(ioFailureFlushDelay)
        os_log("[AppLogPersister] %{public}@", type: .error, "近 \(windowSec) 秒 \(count) 次 log 寫入失敗；最後: \(last)")
        SocketServer.shared.broadcastDiagnostic([
            "type": "diagnostic",
            "subsystem": "logio",
            "source": "mainapp",
            "count": count,
            "lastError": last
        ])
    }

    private var lastWriteCanRetry = true

    /// 寫入成功才計量；部分寫入失敗先回復原長度，回復失敗不得重送整批。
    @discardableResult private func appendRaw(_ data: Data) -> Bool {
        lastWriteCanRetry = true
        guard let handle = writeHandle ?? openWriteHandle() else {
            recordIOFailure(context: "open", lastError: "無法開啟主日誌")
            return false
        }
        var offset: UInt64?
        do {
            offset = try handle.seekToEnd()
            try handle.write(contentsOf: data)
            statisticsLock.lock()
            writtenBytes += UInt64(data.count)
            statisticsLock.unlock()
            estimatedFileBytes += data.count
            estimatedLineCount += data.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
            return true
        } catch {
            recordIOFailure(context: "append", lastError: String(describing: error))
            if let offset {
                do { try handle.truncate(atOffset: offset) }
                catch {
                    lastWriteCanRetry = false
                    recordIOFailure(context: "rollback", lastError: String(describing: error))
                }
            }
            closeWriter()
            return false
        }
    }

    private func openWriteHandle() -> FileHandle? {
        if !FileManager.default.fileExists(atPath: logURL.path) {
            _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: logURL) else {
            return nil
        }
        writeHandle = handle
        return handle
    }

    /// 清空成功才重設索引與統計；失敗保留可診斷狀態。
    private func truncateFile() {
        do {
            closeWriter()
            try Data().write(to: logURL, options: .atomic)
            historyReader.invalidate()
            estimatedLineCount = 0
            estimatedFileBytes = 0
            lastFlushSucceeded = true
        } catch { recordIOFailure(context: "clear", lastError: String(describing: error)) }
    }

    /// 輪替完整主檔，不裁掉前段；下一批依原路徑建立新的 log.txt。
    private func trimNow() {
        do {
            let root = try LogArchiveStore.directory(beside: logURL)
            closeWriter(synchronize: true)
            if FileManager.default.fileExists(atPath: logURL.path) {
                try FileManager.default.moveItem(at: logURL,
                    to: root.appendingPathComponent(LogArchiveStore.name(prefix: "main")))
            }
            historyReader.invalidate()
            estimatedFileBytes = 0
            estimatedLineCount = 0
            try LogArchiveStore.prune(root)
        } catch { recordIOFailure(context: "archive.rotate", lastError: String(describing: error)) }
    }

}


// MARK: 新日誌區塊
final class LogModel: ObservableObject {

    @Published private(set) var messages: [LogItem] = []

    let newMessages = PassthroughSubject<[LogItem], Never>()

    let queue = DispatchQueue(label: "liveApp.logModel")


    /// UI 更新頻率（秒）
    private let refreshInterval: TimeInterval = 0.1
    /// 每次最多吃幾筆 log
    private let batchLimit = 100
    /// Buffer安全大下
    private let maxMessages = 1000

    init() {

        LogBuffer.shared.onNewLog = { [weak self] logs in

            guard let self else { return }
            let items = logs.map { LogItem(message: $0) }
            self.messages.append(contentsOf: items)
            if self.messages.count > self.maxMessages * 2 {
                self.messages.removeFirst(self.messages.count - self.maxMessages)
            }
            self.newMessages.send(items)

        }

    }


   


    func clearLogs() {
        messages.removeAll()

        LogBuffer.shared.clear()
    }

    deinit {
        clearLogs()
        os_log("LogModel釋放緩衝區")
        
    }
}


final class LogReceiver {
    private let maxPush = 50

    private let groupID = "group.nuclear.liveAPP"
    private let logFileName = "log.txt"

    private let bufferQueue = DispatchQueue(label: "com.nuclear.LogReceiver.bufferQueue")

    private var lastReadOffset: UInt64 = 0
    private var buffer: [String] = []

    private let flushDebounce: TimeInterval = 0.2
    private var flushWorkItem: DispatchWorkItem?


    init() {
        // 讀取上次儲存 offset

        lastReadOffset = UInt64(userDefaults?.integer(forKey: "lastReadOffset") ?? 0)

        // 註冊 Darwin 通知
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            LogReceiver.notificationCallback,
            "liveAPP.log" as CFString,
            nil,
            .deliverImmediately
        )




    }

    deinit {


        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            CFNotificationName("liveAPP.log" as CFString),
            nil
        )

    }

    // MARK: - C callback
    private static let notificationCallback: CFNotificationCallback = { _, observer, _, _, _ in
        guard let observer else { return }

        let mySelf = Unmanaged<LogReceiver>.fromOpaque(observer).takeUnretainedValue()

        mySelf.readNewLines()

    }

    // MARK: - 讀新增 log
    private func readNewLines() {

        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            sendlog(message:"❌ LogReceiver: 無法取得 containerURL")
            return
        }
        let fileURL = containerURL.appendingPathComponent(logFileName)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            // open file
            guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
                sendlog(message:"❌ LogReceiver: 無法打開檔案 \(fileURL.path)")
                return
            }
            defer { try? fileHandle.close() }


            do {
                let fileSize = try fileHandle.seekToEnd()

                if self.lastReadOffset > fileSize {
                    self.lastReadOffset = fileSize // 重新校正 offset
                    sendlog(message:"lastRead \(self.lastReadOffset) fileSize:\(fileSize)")
                }

            } catch {
                sendlog(message: "Error seekToEnd: \(error)")
            }

            // seek 到上次 offset
            do {
                try fileHandle.seek(toOffset: self.lastReadOffset)
            } catch {
                sendlog(message:"❌ LogReceiver: seek 失敗, offset: \(self.lastReadOffset), error: \(error)")
                return
            }


            // 讀取新增資料
            let data = fileHandle.readDataToEndOfFile()

            guard !data.isEmpty else {
                sendlog(message:"LogReceiver: lastReadOffset = \(self.lastReadOffset), fileSize = \(fileHandle.seekToEndOfFile())")
                sendlog(message:"⚠️ LogReceiver: 無新增資料可讀")
                return
            }

            // 轉成字串
            guard let content = String(data: data, encoding: .utf8) else {
                sendlog(message:"❌ LogReceiver: 讀取資料編碼失敗")
                return
            }


            let normalizedContent = content
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .split(separator: "\n")
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

            let lines = Array(normalizedContent)


            guard !lines.isEmpty else {
                sendlog(message:"⚠️ LogReceiver: 讀取到的資料沒有換行符號")
                return
            }


            // 限制推送行數
            let newLines = Array(lines.suffix(self.maxPush))

            // 讀取新的 lines
            // 外層明確以 [self] 捕捉，與內層 workItem 的 [weak self] 並存不再觸發
            // ImplicitStrongCapture 警告（workItem 仍弱引用 self，維持不產生成環）。
            bufferQueue.async { [self] in

                self.buffer.append(contentsOf: newLines)

                // 更新 offset
                self.lastReadOffset += UInt64(data.count)

                // 短暫延遲 flush（debounce）
                self.flushWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    self?.flushBuffer()
                }
                self.flushWorkItem = workItem
                self.bufferQueue.asyncAfter(deadline: .now() + self.flushDebounce, execute: workItem)


            }





        }
    }

    // MARK: - 批次推送 buffer
    private func flushBuffer() {


            guard !self.buffer.isEmpty else { return }
            let linesToSend = self.buffer

            self.buffer.removeAll()

            LogBuffer.shared.push(linesToSend)
            AppLogPersister.shared.append(lines: linesToSend)

            // ✅ 批次更新 offset，降低 UserDefaults I/O
            userDefaults?.set(Int(lastReadOffset), forKey: "lastReadOffset")





        

    }
}



// MARK: RemoteLog
final class RemoteLogBuffer {
    static let shared = RemoteLogBuffer()

    private let queue = DispatchQueue(label: "remote.log.buffer.queue")
    private var buffer: [ExternalLogEntry<[String: String]>] = []

    /// 最多暫存幾筆，超過就丟
    private let maxBufferSize = 500

    func push(title: String, message: String) {
        let transport = userDefaults?.string(forKey: "externalLogTransport") ?? "http"
        if transport == "socket", !SocketServer.shared.hasExternalLogSubscribers { return }
        let item = [
            "title": title,
            "body": message,
            "time": formatTime()
        ]

        queue.async {
            self.buffer.append(ExternalLogEntry(transport: transport, item: item))
            if self.buffer.count > self.maxBufferSize {
                let excess = self.buffer.count - self.maxBufferSize
                self.buffer.removeFirst(excess)
                logger.debug("⚠️ RemoteLogBuffer 已滿，丟棄 \(excess) 條最舊日誌")
            }
        }
    }

    /// 通道切換不重播尚未送出的舊批次。
    func clear() { queue.async { self.buffer.removeAll() } }

    /// 只取出與目前通道相符的項目；切換前殘留的舊通道資料直接丟棄。
    func drain(max: Int, transport: String) -> [[String: String]] {
        queue.sync {
            ExternalLogPolicy.takeDrainable(&buffer, transport: transport, limit: max)
        }
    }
}

// MARK: RemoteLogSend
final class RemoteLogSender {

    static let shared = RemoteLogSender()

    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "RemoteLogSenderTimerQueue", qos: .utility)
    private let session = URLSession(configuration: .ephemeral)

    private let flushInterval: TimeInterval = 1.0
    private let batchLimit = 150

    private var started = false


    func stop() {
        timerQueue.async { [weak self] in
            guard let self, self.started else { return }
            self.timer?.cancel()
            self.timer = nil
            self.started = false
        }
    }

    func start() {
        timerQueue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true

            let t = DispatchSource.makeTimerSource(queue: self.timerQueue)
            t.schedule(deadline: .now() + self.flushInterval, repeating: self.flushInterval)
            t.setEventHandler { [weak self] in
                self?.flush()
            }
            self.timer = t
            t.resume()
        }
    }

    private func flush() {
        let transport = userDefaults?.string(forKey: "externalLogTransport") ?? "http"
        let logs = RemoteLogBuffer.shared.drain(max: batchLimit, transport: transport)
        guard !logs.isEmpty else { return }

        guard LPConfig.shared.logMode == 0 || LPConfig.shared.logMode == 2 else { return }

        if transport == "socket" {
            SocketServer.shared.broadcastExternalLogs(logs)
        } else {
            sendBatch(logs)
        }
    }

    private func sendBatch(_ logs: [[String: String]]) {
        let urla = LPConfig.shared.logURL
        guard let url = URL(string: urla) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "logs": logs
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }
        request.httpBody = body

        session.dataTask(with: request) { _, _, _ in
            // 失敗直接忽略（log 本來就不重要）
        }.resume()
    }

    deinit {
        timerQueue.sync {
            timer?.cancel()
            timer = nil
            started = false
        }
    }
}

func remotelog(title:String="liveApp",message:String) {

    let urla = LPConfig.shared.logURL
    guard let url = URL(string: urla) else {
        print("❌ URL 無效")
        return
    }

    // 2. 準備 URLRequest
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let timeString = formatTime()

    // 3. JSON 資料
    let json: [String: Any] = [
        "title":title,
        "body":message,
        "time":timeString
    ]

    guard let httpBody = try? JSONSerialization.data(withJSONObject: json, options: []) else {
        print("❌ JSON 轉換失敗")
        return
    }
    request.httpBody = httpBody

    // 4. 發送請求
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        if let error = error {
            print("❌ 發送失敗:", error)
            return
        }

        if let data = data,
           let responseString = String(data: data, encoding: .utf8) {
            print("✅ 收到回應:", responseString)
        }
    }

    task.resume()
}


// 全局共用時間 liveApp格式器
struct StaticFormatter {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_TW")
        f.dateFormat = "yyyy/MM/dd aHH:mm:ss.SSS"
        return f
    }()
}

func formatTime() -> String {
    let formatter = StaticFormatter.formatter
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    formatter.locale = Locale.current

    let now = Date()
    let timeString = formatter.string(from: now)

    return timeString

}


// MARK: 日誌通知
func sendlog(title:String = "liveApp",message: String) {

    guard LPConfig.shared.enableLog else { return }

    let timeString = formatTime()
    let full = "\(timeString): \(title):\(message)"

    // MARK: 日誌緩衝區
    LogBuffer.shared.push(full)
    AppLogPersister.shared.append(line: full)

    // 遠端 log 可以保留（但最好也 async）
    if LPConfig.shared.logMode == 0 || LPConfig.shared.logMode == 2 {

        RemoteLogSender.shared.start()
        RemoteLogBuffer.shared.push(title: title, message: message)

    } else {
        // 取消遠端 log
        RemoteLogSender.shared.stop()

    }

    logger.info("logMode:\(LPConfig.shared.logMode) \(title,privacy:.public):\(message,privacy:.public)")




}

func receiveSocketLog(title: String = "UseESocket", message: String) {
    guard LPConfig.shared.enableLog || LPConfig.shared.SocketLog else { return }

    //let timeString = formatTime()
    // 已經有時間戳了，避免重複

    let lines = message
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { "\(title):\($0)" }

    if lines.isEmpty {
        
        LogBuffer.shared.push("\(title):\(message)")


        AppLogPersister.shared.append(line: "\(title):\(message)")
    } else {
        LogBuffer.shared.push(lines)
        AppLogPersister.shared.append(lines: lines)
    }

    if (LPConfig.shared.logMode == 0 || LPConfig.shared.logMode == 2),
       userDefaults?.string(forKey: "externalLogTransport") != "socket" {
        RemoteLogSender.shared.start()
        RemoteLogBuffer.shared.push(title: title, message: message)
    }
}








#if os(iOS)
func showLogOnScreen(_ message: String) {
    DispatchQueue.main.async {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else { return }

        let alert = UIAlertController(title: "Log", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        rootVC.present(alert, animated: true)
    }
}

#endif

func postSystemNotification(title: String, body: String, imageURL: String? = nil, inlineImages: [String] = []) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    content.categoryIdentifier = "replykit_notification"

    let bestURL: URL
    if let firstEmoji = inlineImages.compactMap({ URL(string: $0) }).first {
        bestURL = firstEmoji
    } else if let imageURL = imageURL, let url = URL(string: imageURL) {
        bestURL = url
    } else {
        deliverNotification(content: content)
        return
    }

    // 走 PiPImageCache：與 PiP 疊層共用快取 + FIFO 下載佇列，
    // 避免同一張圖重複下載、以及通知路徑無限並行 dataTask 與 PiP 搶網路。
    Task {
        await PiPImageCache.shared.loadImage(urlString: bestURL.absoluteString) { image in
            guard let data = image?.pngData() else {
                deliverNotification(content: content)
                return
            }
            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".png")
            try? data.write(to: tempFile)
            if let attachment = try? UNNotificationAttachment(identifier: UUID().uuidString, url: tempFile) {
                content.attachments = [attachment]
            }
            deliverNotification(content: content)
        }
    }
}

private func deliverNotification(content: UNMutableNotificationContent) {
    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
    let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: trigger
    )
    UNUserNotificationCenter.current().add(request) { error in
        if let error = error {
            print("❌ 發送通知失敗: \(error)")
        } else {
            print("✅ 通知已發送")
        }
    }
}




//final class SocketUserDefaluts: ObservableObject {
//    @Published var server: CFMessagePortServer?
//
//    static let shared = SocketUserDefaluts()
//
//    private init() {}
//
//
//    func startSettingsServer() {
//        guard server == nil else { return } // 避免重複啟動
//        
//        server = CFMessagePortServer.shared
//
//        server?.start()
//
//
////            NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
////                guard let self = self else { return }
////                let defaults = UserDefaults.standard
////                for (key, value) in defaults.dictionaryRepresentation() {
////                    self.server?.broadcast(key: key, value: value)
////                }
////            }
////        } catch {
////            print("Failed to start SettingsServer: \(error)")
////        }
//    }
//}
//

@main
struct liveAPPApp: App {
    // 建立 delegate 實例
    let notificationDelegate = NotificationDelegate()

    @StateObject var logModel = LogModel()
    @AppStorage("AppLanguage", store: userDefaults) private var appLanguageRawValue = AppLanguage.system.rawValue



    enum OrientationCategory {
        case portrait
        case landscape
        case unknown
    }








    init() {

        #if os(iOS)
        MetricReports.shared.start()
        SettingsBackupManager.shared.start()
        // 更新後第一次啟動即搬移舊錄影，避免必須先開錄影清單才能在「檔案」找到它。
        _ = RecordingLibrary.shared
        #endif

        // 與關於頁共用同一份建置快照，便於從 log.txt 辨識產物。
        AppLogPersister.shared.append(lines: BuildInformation.current.report.components(separatedBy: "\n").map { "[BuildInfo] " + $0 })

        // App 啟動時就啟動 Socket Server
        // 啟動一次


        if LPConfig.shared.SocketLog  {

            sendlog(message: "已啟用Socket轉送 不依賴日誌文件變動監聽")

        } else {
            sendlog(message: "已停用Socket轉送 使用日誌文件變動監聽")

            SharedResources.shared.setupLogReceiver()

        }

        SocketServer.shared.start()

        // 註冊 BGTaskScheduler 處理常式
        BackgroundTaskManager.shared.registerTasks()

        // 週期把記憶體明細寫入日誌，供追查 footprint 成長來源
        MemorySampler.shared.start()
        MemorySampler.shared.checkpoint("app.start")

        // 預先初始化 BroadcastButton 的 RPSystemBroadcastPickerView，避免首次使用時指向錯誤
        let bundleID = (Bundle.main.bundleIdentifier ?? "nuclear.liveAPP") + ".ReplyKIT"
        let ext = userDefaults?.string(forKey: "broadcastExtension") ?? bundleID
        sendlog(message:"Ext->\(ext)")


        // 將 App Group 既有的 log 複製到 Documents/ 供檔案 App 讀取
        AppLogPersister.shared.copyFromAppGroup()



#if os(iOS)

        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                if granted {
                    print("麥克風權限允許")
                    // 可以啟動 ReplayKit 或推流
                } else {
                    print("麥克風權限拒絕")
                    // 提示用戶去設定裡開啟
                }
            }
        }
#elseif os(macOS)

AVCaptureDevice.requestAccess(for: .audio) { granted in
    DispatchQueue.main.async {
        if granted {
            print("麥克風權限允許")
            // 可以啟動錄音或推流
        } else {
            print("麥克風權限拒絕")
            // 提示用戶去設定裡開啟
        }
    }
}
        #endif



        // 註冊 delegate
        UNUserNotificationCenter.current().delegate = notificationDelegate

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("✅ 通知授權已取得")
            } else if let error = error {
                print("❌ 通知授權錯誤: \(error)")
            }
        }

        let category = UNNotificationCategory(
            identifier: "replykit_notification",
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])

        Task { @MainActor in
            TTSService.shared.refreshAudioSessionForCurrentSetting()
        }


    }


    

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(logModel)
                .environment(\.locale, AppLanguage(rawValue: appLanguageRawValue)?.locale ?? .autoupdatingCurrent)
                #if os(iOS)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    MemorySampler.shared.checkpoint("memory.warning")
                }
                #endif
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .inactive:
                        break

                    case .background:
                        sendlog(message: "App 進入背景，啟動短背景視窗並排程 Socket refresh")

                        // 通知 PIPService 進入背景
                        PIPService.shared.appDidEnterBackground()

                        // 釋放非關鍵記憶體，降低被 kill 風險
                        PIPService.shared.releaseNonCriticalMemory()
                        MemorySampler.shared.checkpoint("app.background.afterCleanup")
                        // 日誌頁以檔案為準；背景不清除可見歷史。
                        // 在短背景視窗內嘗試寫入並關檔；系統終止前仍無法保證零遺失。
                        Task { await AppLogPersister.shared.setBackground(true) }

                        // 先取得短背景窗口收尾 socket 未送出的 log，再排程機會型 refresh。
                        #if os(iOS)
                        BackgroundTaskManager.shared.beginSocketBackgroundWindow()
                        BackgroundTaskManager.shared.scheduleSocketRefresh()
                        #endif

                    case .active:
                        AppLogPersister.shared.copyFromAppGroup()
                        Task { await AppLogPersister.shared.setBackground(false) }
                        sendlog(message: "App 回到前景")
                        SocketServer.shared.start()

                        // 通知 PIPService 回到前景
                        PIPService.shared.appWillEnterForeground()
                        MemorySampler.shared.checkpoint("app.foreground")

                        // 取消背景窗口與 BGTaskScheduler 任務（前景不需要）
                        #if os(iOS)
                        BackgroundTaskManager.shared.cancelAll()
                        #endif

                    @unknown default:
                        break
                    }
                }


        }
    }
}



class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}


#if os(iOS)
extension UIDeviceOrientation {
    func matches(_ interfaceOrientation: UIInterfaceOrientation) -> Bool {
        switch (self, interfaceOrientation) {
        case (.portrait, .portrait), (.portraitUpsideDown, .portraitUpsideDown),
             (.landscapeLeft, .landscapeRight), (.landscapeRight, .landscapeLeft):
            return true
        default:
            return false
        }
    }
}

#endif

