import Foundation
import SwiftUI

/// 分塊篩選固定快照；不修改主日誌，不把整個檔案載入記憶體。
enum LogDiagnosticExport {
    /// 解析既有中文時間戳；其他格式交由目前語系及英文短日期解析。
    static func date(in line: String, zone: TimeZone) -> Date? {
        let pattern = #"^(\d{4})/(\d{1,2})/(\d{1,2})\s*(凌晨|清晨|早上|上午|中午|下午|晚上)?\s*(\d{1,2}):(\d{2}):(\d{2})"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            func part(_ n: Int) -> String {
                guard let range = Range(match.range(at: n), in: line) else { return "" }
                return String(line[range])
            }
            var hour = Int(part(5)) ?? 0
            let period = part(4)
            if !period.isEmpty {
                hour %= 12
                if ["中午", "下午", "晚上"].contains(period) { hour += 12 }
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return calendar.date(from: DateComponents(year: Int(part(1)), month: Int(part(2)),
                day: Int(part(3)), hour: hour, minute: Int(part(6)), second: Int(part(7))))
        }
        guard let separator = line.range(of: ": ") else { return nil }
        let prefix = String(line[..<separator.lowerBound])
        for locale in [Locale.current, Locale(identifier: "en_US")] {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = zone
            formatter.dateStyle = .short
            formatter.timeStyle = .medium
            if let date = formatter.date(from: prefix) { return date }
        }
        return nil
    }

    /// 遮蔽 RTMP URL 與常見具名憑證；不宣稱能識別任意聊天文字中的秘密。
    static func redacted(_ line: String) -> String {
        var value = line
        for pattern in [#"(?i)rtmps?://[^\s\"<>]+"#,
                        #"(?i)(?:password|passwd|token|streamkey|stream_key|authorization|密碼|金鑰)\s*[=:：]\s*(?:\"[^\"]*\"|[^\s,;]+)"#] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                value = regex.stringByReplacingMatches(in: value,
                    range: NSRange(value.startIndex..., in: value), withTemplate: "[已遮蔽]")
            }
        }
        return value
    }

    /// 只讀 snapshot；續行跟隨最近一筆時間戳。輸出不含範圍外事件。
    /// - Returns: 可分享的 UTF-8 檔；時間區間包含起點與終點。
    static func extract(snapshot: URL, start: Date, end: Date, zone: TimeZone) throws -> URL {
        let nameFormatter = DateFormatter()
        nameFormatter.locale = Locale(identifier: "en_US_POSIX")
        nameFormatter.timeZone = zone
        nameFormatter.dateFormat = "yyyyMMdd-HHmm"
        let name = "diagnostic-\(nameFormatter.string(from: start))-\(nameFormatter.string(from: end)).txt"
        let output = snapshot.deletingLastPathComponent().appendingPathComponent(name)
        let input = try FileHandle(forReadingFrom: snapshot)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        func write(_ text: String) throws { try writer.write(contentsOf: Data(text.utf8)) }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        try write("診斷日誌\n範圍：\(formatter.string(from: start)) ～ \(formatter.string(from: end))\n時區：\(zone.identifier)（原日誌未保存時區，依此解讀）\n僅包含快照當時已寫入的日誌；已遮蔽常見憑證，分享前請檢視。\n\n")
        var pending = Data()
        var selected = false
        var lines = 0
        var undated = 0
        func consume(_ data: Data) throws {
            let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
            if line == "[ArchiveBoundary]" { selected = false; return }
            if line.hasPrefix("[Retention]") { try write(line + "\n"); return }
            if let timestamp = date(in: line, zone: zone) {
                selected = timestamp >= start && timestamp <= end
            } else if line.first?.isNumber == true && line.contains(":") {
                selected = false
                undated += 1
            }
            if selected { try write(redacted(line) + "\n"); lines += 1 }
        }
        while let chunk = try input.read(upToCount: 65536), !chunk.isEmpty {
            try Task.checkCancellation()
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                try consume(Data(pending[..<newline]))
                pending.removeSubrange(...newline)
            }
            guard pending.count <= 8 * 1024 * 1024 else {
                throw NSError(domain: "LogExport", code: 2, userInfo: [NSLocalizedDescriptionKey: "單行超過 8 MiB，匯出已停止，請使用完整日誌。"])
            }
        }
        if !pending.isEmpty { try consume(pending) }
        try write("\n[匯出摘要] 選取 \(lines) 行；疑似日期但無法解析 \(undated) 行。無日期續行依前一筆時間歸屬。\n")
        try writer.synchronize()
        return output
    }
}

/// 範圍匯出與分享入口；檔案置於快取，不改動 log.txt。
struct LogDiagnosticExportView: View {
    @State private var mode = 3
    @State private var start = Calendar.current.startOfDay(for: Date())
    @State private var end = Date()
    @State private var busy = false
    @State private var result: URL?
    @State private var error: String?
    @State private var work: Task<Void, Never>?

    var body: some View {
        Form {
            Section("匯出範圍") {
                Picker("時間", selection: $mode) {
                    Text("本次啟動到現在").tag(3)
                    Text("上次前景到背景").tag(4)
                    Text("最近一小時").tag(1)
                    Text("今天").tag(0)
                    Text("自訂範圍").tag(2)
                }
                if mode == 2 {
                    DatePicker("開始", selection: $start)
                    DatePicker("結束", selection: $end)
                }
                if mode == 3 {
                    Text("本次啟動：" + AppSession.launchDate.formatted(date: .abbreviated, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if mode == 4 {
                    if let interval = AppSession.lastForegroundInterval {
                        Text("上次前景 active → 背景：" + interval.start.formatted(date: .abbreviated, time: .standard)
                            + " ～ " + interval.end.formatted(date: .abbreviated, time: .standard))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("尚無上次前景到背景區間。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Text("時區：" + TimeZone.current.identifier)
                Text("保留範圍內所有紀錄及多行續文。本次啟動以 App 啟動標記為起點；上次前景到背景以前景 active 起點到進背景為止；今天與最近一小時以按下產生時為準。原始日誌不變。")
                    .font(.caption)
            }.disabled(busy)
            Section {
                Button("產生診斷檔") { export() }
                    .disabled(busy || (mode == 2 && start > end)
                        || (mode == 4 && AppSession.lastForegroundInterval == nil))
                if busy { ProgressView("正在篩選日誌…"); Button("取消") { work?.cancel() } }
                if let error { Text(error).foregroundStyle(.red) }
                if let result {
                    ShareLink(item: result) { Label("分享診斷檔", systemImage: "square.and.arrow.up") }
                }
                Text("包含常見敏感欄位遮蔽，但無法保證辨識任意文字中的秘密，分享前請檢視。匯出快取保留 7 天；包含主檔與可用封存；封存上限 7 天／256 MiB，超限清理會附缺口提示。")
                    .font(.caption)
            }
        }
        .navigationTitle("匯出診斷日誌")
        .onDisappear { work?.cancel() }
    }

    /// 固定時間範圍與時區，再背景處理快照；取消後不發布結果。
    private func export() {
        let now = Date(), zone = TimeZone.current
        let lastForeground = AppSession.lastForegroundInterval
        let upper = mode == 2 ? end : (mode == 4
            ? (lastForeground?.end.addingTimeInterval(1) ?? now) : now)
        let lower: Date
        switch mode {
        case 0:
            lower = Calendar.current.startOfDay(for: now)
        case 1:
            lower = now.addingTimeInterval(-3600)
        case 3:
            // 日誌時間只有秒精度；往前 1 秒確保啟動標記本身也被選入。
            lower = AppSession.launchDate.addingTimeInterval(-1)
        case 4:
            // 日誌時間只有秒精度；前後各留 1 秒，讓 active／background 邊界紀錄也被選入。
            lower = (lastForeground?.start ?? AppSession.launchDate).addingTimeInterval(-1)
        default:
            lower = start
        }
        busy = true; result = nil; error = nil
        work = Task {
            defer { busy = false }
            do {
                let snapshot = try await AppLogPersister.shared.diagnosticSnapshot()
                let job = Task.detached(priority: .utility) {
                    // 快照可能含未遮蔽憑證，工作結束即清理，原始 log.txt 不受影響。
                    defer {
                        do { try FileManager.default.removeItem(at: snapshot) }
                        catch { NSLog("Diagnostic snapshot cleanup failed: %@", error.localizedDescription) }
                    }
                    return try LogDiagnosticExport.extract(snapshot: snapshot, start: lower, end: upper, zone: zone)
                }
                let url = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                try Task.checkCancellation()
                result = url
            } catch is CancellationError { error = "已取消。" }
            catch { self.error = error.localizedDescription }
        }
    }
}
