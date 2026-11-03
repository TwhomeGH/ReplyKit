import Foundation

/// 日誌尾端裁切的純資料政策；呼叫端先以 byte 上限限制讀取量。
enum LogRetention {
    /// 去除容量邊界切斷的首行，再保留最後指定行數；不改寫 UTF-8 內容。
    /// - Parameters:
    ///   - input: 有界尾端資料。
    ///   - startsMidFile: 非檔頭開始時，第一行視為不完整並排除。
    ///   - maximumLines: 保留行數，必須大於零。
    /// - Returns: 可原子寫回的尾端；沒有完整行時為空。
    static func retainedTail(_ input: Data, startsMidFile: Bool, maximumLines: Int) -> Data {
        guard maximumLines > 0 else { return Data() }
        var data = input
        if startsMidFile {
            guard let end = data.firstIndex(of: 10) else { return Data() }
            data.removeSubrange(...end)
        }
        var remaining = maximumLines
        // 結尾換行是上一行結束，不多算一個空行。
        let end = data.last == 10 ? data.index(before: data.endIndex) : data.endIndex
        for index in data[..<end].indices.reversed() where data[index] == 10 {
            remaining -= 1
            if remaining == 0 { return Data(data[data.index(after: index)...]) }
        }
        return data
    }
}
