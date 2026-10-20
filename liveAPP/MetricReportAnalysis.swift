import Foundation

/// 單份本機報告的解讀結果。只呈現已提供的值，不推算健康分數或補零。
struct MetricReportAnalysis: Sendable {
    struct Field: Identifiable, Sendable {
        let id: String
        let title: String
        let value: String
    }

    struct Section: Identifiable, Sendable {
        let id: String
        let title: String
        let explanation: String
        let fields: [Field]
    }

    let sections: [Section]
    let metadata: [Field]
    let missing: [String]
    /// 僅整台裝置的已用容量比例，不是 App 的占用比例；無法解析時不顯示圖表。
    let deviceStorageFraction: Double?

    /// 解析本機 schemaVersion 1 封裝，不修改原始 JSON。
    /// - Parameter content: `MetricReports.contents(of:)` 讀取的完整文字。
    /// - Returns: 分類、指標、缺漏提示與可驗證的容量比例。
    /// - Throws: JSON 或封裝格式不符時拋出錯誤，畫面仍可提供原文。
    static func parse(_ content: String) throws -> Self {
        guard let data = content.data(using: .utf8),
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["schemaVersion"] as? Int == 1,
              let report = envelope["report"] as? [String: Any] else {
            throw NSError(domain: "MetricReportAnalysis", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "無法辨識報告封裝，請查看原始 JSON。"])
        }
        var sections: [Section] = []
        for key in report.keys.sorted() where key.lowercased().contains("metrics") {
            guard let values = report[key] as? [String: Any] else { continue }
            var fields: [Field] = []
            for name in values.keys.sorted() {
                let value: String
                if let scalar = scalar(values[name]) {
                    value = scalar
                } else if let entries = values[name] as? [Any] {
                    value = "\(entries.count) 筆；詳細事件與堆疊請查看原始 JSON"
                } else {
                    value = "包含分布或巢狀資料，請查看原始 JSON"
                }
                fields.append(Field(id: name, title: labels[name] ?? name, value: value))
            }
            sections.append(Section(id: key, title: labels[key] ?? key,
                                    explanation: explanations[key] ?? "系統提供的原始統計；單位依報告保留，不代表即時狀態。",
                                    fields: fields))
        }
        var metadata: [Field] = []
        let meta = report["metaData"] as? [String: Any] ?? [:]
        for key in ["appVersion", "timeStampBegin", "timeStampEnd"] {
            if let value = scalar(report[key]) { metadata.append(Field(id: key, title: labels[key] ?? key, value: value)) }
        }
        for key in ["appBuildVersion", "deviceType", "osVersion", "bundleIdentifier"] {
            if let value = scalar(meta[key]) { metadata.append(Field(id: key, title: labels[key] ?? key, value: value)) }
        }
        let missing = [("memoryMetrics", "記憶體統計"), ("cpuMetrics", "CPU 統計"),
                       ("diagnosticMetrics", "異常診斷")].compactMap { key, label in
            report[key] == nil ? label : nil
        }
        let disk = report["diskSpaceUsageMetrics"] as? [String: Any] ?? [:]
        var fraction: Double?
        if let used = bytes(disk["totalDiskSpaceUsedSize"]),
           let total = bytes(disk["totalDiskSpaceCapacity"]), total > 0, used <= total {
            fraction = used / total
        }
        return Self(sections: sections, metadata: metadata, missing: missing, deviceStorageFraction: fraction)
    }

    /// 只抽取 JSON 字串或數值；複合資料回傳 nil，交由呼叫端顯示分布／事件摘要。
    private static func scalar(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// 將明確容量單位轉為十進位 B／KB／MB／GB／TB，其他量綱保留原文。
    /// - Parameters:
    ///   - value: 報告提供的原始純量文字。
    ///   - original: true 時完整保留原始單位與精度。
    /// - Returns: 適合畫面顯示的文字，不修改解析資料或匯出 JSON。
    static func displayValue(_ value: String, original: Bool = false) -> String {
        guard !original, let capacity = bytes(value) else { return value }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = capacity
        var index = 0
        while amount >= 1000 && index < units.count - 1 {
            amount /= 1000
            index += 1
        }
        return String(format: "%.2f %@", locale: Locale(identifier: "en_US_POSIX"), amount, units[index])
    }

    /// 只接受已知容量單位；不猜測無單位數字，避免產生錯誤比例。
    private static func bytes(_ value: Any?) -> Double? {
        guard let text = value as? String else { return nil }
        let parts = text.split(whereSeparator: { $0.isWhitespace })
        guard parts.count == 2, let number = Double(parts[0]), number.isFinite, number >= 0,
              let multiplier = ["B": 1.0, "kB": 1e3, "KB": 1e3, "MB": 1e6, "GB": 1e9,
                                "TB": 1e12, "KiB": 1024.0, "MiB": 1048576.0,
                                "GiB": 1073741824.0, "TiB": 1099511627776.0][String(parts[1])] else { return nil }
        let result = number * multiplier
        return result.isFinite ? result : nil
    }

    private static let explanations = [
        "diskSpaceUsageMetrics": "整台裝置容量與 App 檔案統計分開列出。這些是磁碟空間，不是 RAM；各子項不應自行相加推算 App 總占用。",
        "memoryMetrics": "期間內的記憶體統計，不能單憑峰值判定哪個物件洩漏，也不是目前即時用量。",
        "cpuMetrics": "期間累計 CPU 時間，不是目前 CPU 使用百分比。",
        "diskIOMetrics": "邏輯寫入量是期間累計寫入活動，不等於檔案目前大小。",
        "diagnosticMetrics": "按系統交付的事件分類計數。未收到事件不表示沒有異常；堆疊保留在原始 JSON。"
    ]

    private static let labels = [
        "diskSpaceUsageMetrics": "磁碟空間", "memoryMetrics": "記憶體", "cpuMetrics": "CPU",
        "diskIOMetrics": "磁碟讀寫", "diagnosticMetrics": "異常事件", "gpuMetrics": "GPU",
        "networkTransferMetrics": "網路傳輸", "applicationTimeMetrics": "App 執行時間",
        "applicationLaunchMetrics": "啟動效能", "applicationResponsivenessMetrics": "回應效能",
        "peakMemoryUsage": "記憶體峰值", "averageSuspendedMemory": "暫停期間記憶體分布",
        "cumulativeCPUTime": "累計 CPU 時間", "cumulativeLogicalWrites": "累計邏輯寫入量",
        "totalDiskSpaceCapacity": "整台裝置總容量", "totalDiskSpaceUsedSize": "整台裝置已用容量",
        "totalBinaryFileSize": "App 二進位檔案大小", "totalBinaryFileCount": "App 二進位檔案數",
        "totalDataFileSize": "App 資料檔案大小", "totalDataFileCount": "App 資料檔案數",
        "totalCacheFolderSize": "App 快取目錄大小", "totalCloneSize": "複製檔案統計（clone）",
        "crashDiagnostics": "崩潰事件", "hangDiagnostics": "卡頓事件",
        "cpuExceptionDiagnostics": "CPU 異常事件", "diskWriteExceptionDiagnostics": "磁碟寫入異常事件",
        "appVersion": "報告 App 版本", "appBuildVersion": "報告 Build 版本",
        "timeStampBegin": "期間起點（原文）", "timeStampEnd": "期間終點（原文）",
        "deviceType": "裝置型號", "osVersion": "系統版本", "bundleIdentifier": "App 識別碼"
    ]
}
