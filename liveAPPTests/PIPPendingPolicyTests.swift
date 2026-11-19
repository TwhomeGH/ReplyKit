import Foundation
import Testing
@testable import liveAPP

struct PIPPendingPolicyTests {
    @Test func insufficientRemainingSpaceRequiresEvictionEvenBeforeOverflow() {
        // 舊內容底部 180 尚未超過 270，但新片段高 220 無法放進 390 的插入上限。
        #expect(!PIPPendingPolicy.canInsert(nextBottom: 180 + 220, limit: 390, isEmpty: false))
        #expect(PIPPendingPolicy.canInsert(nextBottom: 180 + 220, limit: 390, isEmpty: true))
    }

    @Test func capacityEvictsWholeOldestGroup() {
        let a = UUID(), b = UUID(), c = UUID()
        #expect(PIPPendingPolicy.dropCount(parentIDs: [a, a, b, b, c], limit: 4) == 2)
        #expect(PIPPendingPolicy.dropCount(parentIDs: [a, a, b, b, c], limit: 2) == 4)
    }

    @Test func singleOversizedGroupDoesNotLeaveTail() {
        let a = UUID()
        #expect(PIPPendingPolicy.dropCount(parentIDs: Array(repeating: a, count: 201), limit: 200) == 201)
        #expect(PIPPendingPolicy.dropCount(parentIDs: [a], limit: 200) == 0)
        #expect(PIPPendingPolicy.dropCount(parentIDs: [], limit: 0) == 0)
    }
}
