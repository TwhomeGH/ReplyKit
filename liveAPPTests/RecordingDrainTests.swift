import Foundation
import Testing
@testable import liveAPP

/// 錄製存放區的關閉行為 單元測試
struct RecordingDrainTests {

    /// 測試在關閉後會丟棄尚未取出的樣本。
    @Test func discardPendingSamplesOnClose() async {
        let mailbox = CaptureMailbox<Int>(budget: 8, age: 60)
        mailbox.offer(1, bytes: 4)
        mailbox.offer(2, bytes: 4)
        mailbox.finish(discardPending: true)
        var values: [Int] = []
        for await value in mailbox.stream() { values.append(value) }
        #expect(values.isEmpty)
    }

    /// 測試在關閉後仍然可以取出已接受的樣本，並拒絕新的樣本。
    @Test func gracefulCloseDrainsAcceptedSamples() async {
        let mailbox = CaptureMailbox<Int>(budget: 8, age: 60)
        mailbox.offer(1, bytes: 4)
        mailbox.offer(2, bytes: 4)
        mailbox.finish(discardPending: false)
        mailbox.offer(3, bytes: 1)
        var values: [Int] = []
        for await value in mailbox.stream() { values.append(value) }
        #expect(values == [1, 2])

    }

    /// 測試關閉後會丟棄尚未取出的樣本。
    @Test func ordinaryCloseStillDiscardsPendingSamples() async {
        let mailbox = CaptureMailbox<Int>(budget: 8, age: 60)
        mailbox.offer(1, bytes: 4)
        mailbox.finish()
        var values: [Int] = []
        for await value in mailbox.stream() { values.append(value) }
        #expect(values.isEmpty)
    }

    /// 測試 如果先消費再 finish，樣本會被保留。
    @Test func consumedSamplesAreRetainedAfterFinish() async {
        let mailbox = CaptureMailbox<Int>(budget: 8, age: 60)
        mailbox.offer(42, bytes: 4)
        var values: [Int] = []
        // 先消費 stream 中的值
        for await value in mailbox.stream() {
            values.append(value)
            break   // 讀到一個就跳出
        }
        mailbox.finish()
        #expect(values == [42])
    }

    /// 大型視訊擠入時保留音訊，仍維持總容量限制與剩餘樣本的順序。
    @Test func overloadPreservesHigherPriorityAudio() async {
        let mailbox = CaptureMailbox<Int>(budget: 8, age: 60)
        mailbox.offer(1, bytes: 2, priority: 1)
        mailbox.offer(2, bytes: 6)
        mailbox.offer(3, bytes: 6)
        mailbox.finish(discardPending: false)
        var values: [Int] = []
        for await value in mailbox.stream() { values.append(value) }
        #expect(values == [1, 3])
    }

}
