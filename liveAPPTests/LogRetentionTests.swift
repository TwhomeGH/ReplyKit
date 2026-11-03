import Foundation
import Testing
@testable import liveAPP

/// 裁切不可破壞中文字元、遺失最後完整行或把末端換行多算一行。
struct LogRetentionTests {
    @Test func keepsExactLinesAndUTF8() {
        let result = LogRetention.retainedTail(Data("甲\n乙\n丙\n".utf8), startsMidFile: false, maximumLines: 2)
        #expect(String(decoding: result, as: UTF8.self) == "乙\n丙\n")
    }
    @Test func dropsPartialFirstLineAndKeepsUnterminatedTail() {
        let result = LogRetention.retainedTail(Data([0x80, 10]) + Data("完整\n尾端".utf8), startsMidFile: true, maximumLines: 2)
        #expect(String(decoding: result, as: UTF8.self) == "完整\n尾端")
        #expect(LogRetention.retainedTail(Data("超長未完成行".utf8), startsMidFile: true, maximumLines: 2).isEmpty)
        #expect(LogRetention.retainedTail(Data(), startsMidFile: false, maximumLines: 2).isEmpty)
    }
}
