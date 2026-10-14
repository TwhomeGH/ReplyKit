import Foundation
import Testing
@testable import liveAPP

/// 群組顯示與合併資格不依賴影片編碼器。
struct RecordingGroupTests {
    @Test func missingOrUnfinishedSegmentsCannotMerge() {
        let group = UUID()
        var first = LocalRecording(id: UUID(), created: Date())
        first.segmentGroup = group
        first.segmentNumber = 1
        first.transition(to: .ready)
        var third = LocalRecording(id: UUID(), created: Date())
        third.segmentGroup = group
        third.segmentNumber = 3
        third.transition(to: .ready)
        #expect(!RecordingGroup(id: group, items: [first, third]).canMerge)
        third.segmentNumber = 2
        #expect(RecordingGroup(id: group, items: [first, third]).canMerge)
        var pending = LocalRecording(id: UUID(), created: Date())
        pending.segmentGroup = group
        pending.segmentNumber = 2
        #expect(!RecordingGroup(id: group, items: [first, pending]).canMerge)
    }

    @Test func mergedOutputStaysInGroupWithoutDoubleCounting() {
        let group = UUID()
        var source = LocalRecording(id: UUID(), created: Date())
        source.segmentGroup = group
        source.segmentNumber = 1
        source.duration = 60
        source.bytes = 100
        var merged = LocalRecording(id: UUID(), created: Date())
        merged.mergedFromGroup = group
        merged.duration = 60
        merged.bytes = 100
        let groups = RecordingGroup.make([source, merged])
        #expect(groups.count == 1)
        #expect(groups.first?.items.count == 2)
        #expect(groups.first?.bytes == 100)
        #expect(groups.first?.duration == 60)
    }
}
