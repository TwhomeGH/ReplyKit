import Foundation

struct LogFilePage: Sendable {
    let lines: [String]
    let start: Int
    let total: Int
    let generation: Int
}

/// 僅由持久化佇列呼叫。索引保存位移，頁面最多讀取 200 行／1 MiB。
final class LogFileReader {
    private var offsets: [UInt64] = [0]
    private var indexedSize: UInt64 = 0
    private var prefix = Data()
    private var generation = 0
    private var modified: Date?
    private var fileIdentity: String?
    func invalidate() {
        generation += 1; offsets = [0]; indexedSize = 0
        prefix = Data(); modified = nil; fileIdentity = nil
    }

    func page(url: URL, start: Int?, expectedGeneration: Int?) throws -> LogFilePage {
        guard FileManager.default.fileExists(atPath: url.path) else {
            if indexedSize > 0 { invalidate() }
            return LogFilePage(lines: [], start: 0, total: 0, generation: generation)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let date = attributes[.modificationDate] as? Date
        let head = try handle.read(upToCount: Int(min(indexedSize, 256))) ?? Data()
        let identity = "\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? "")"
        let reset = (fileIdentity != nil && fileIdentity != identity) || size < indexedSize || (!prefix.isEmpty && head != prefix) || (size == indexedSize && date != modified)
        if reset { generation += 1; offsets = [0]; indexedSize = 0 }
        // 包含未換行的尾端，追加時從最後完整行重新掃描。
        let scanStart = offsets.last ?? 0
        try handle.seek(toOffset: scanStart)
        var position = scanStart
        while let data = try handle.read(upToCount: 65536), !data.isEmpty {
            for byte in data {
                position += 1
                if byte == 10 { offsets.append(position) }
            }
        }
        indexedSize = size; modified = date; fileIdentity = identity
        try handle.seek(toOffset: 0)
        prefix = try handle.read(upToCount: Int(min(size, 256))) ?? Data()
        let total = max(0, offsets.count - 1) + ((offsets.last ?? 0) < size ? 1 : 0)
        let requested = expectedGeneration != nil && expectedGeneration != generation ? nil : start
        let first = min(max(0, requested ?? max(0, total - 200)), max(0, total - 1))
        guard total > 0 else { return LogFilePage(lines: [], start: 0, total: 0, generation: generation) }
        let end = min(total, first + 200)
        let endOffset = end < offsets.count ? offsets[end] : size
        try handle.seek(toOffset: offsets[first])
        let count = min(UInt64(1024 * 1024), endOffset - offsets[first])
        let data = try handle.read(upToCount: Int(count)) ?? Data()
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        if count < endOffset - offsets[first] { lines.append("[顯示內容已達 1 MiB 上限，完整原文請查看 log.txt]") }
        return LogFilePage(lines: lines, start: first, total: total, generation: generation)
    }
}
