import Foundation
import Testing
@testable import liveAPP

struct SocketValueTests {
    @Test func nestedNullSurvivesJSONButCannotEnterPreferences() throws {
        let value = try JSONDecoder().decode(SocketServer.JSONValue.self,
            from: Data(#"{"items":[1,null,true],"empty":null}"#.utf8))
        #expect(value.propertyListValue == nil)
        #expect(JSONSerialization.isValidJSONObject(value.foundationValue))
        let data = try JSONSerialization.data(withJSONObject: value.foundationValue)
        let decoded = try JSONDecoder().decode(SocketServer.JSONValue.self, from: data)
        guard case .object(let object) = decoded, case .array(let array) = object["items"] else {
            Issue.record("巢狀 JSON 結構遺失"); return
        }
        #expect(array.count == 3)
        guard case .null = array[1], case .null = object["empty"] else {
            Issue.record("null 被刪除或轉成其他值"); return
        }
    }

    @Test func propertyListAcceptsValidNestedValues() throws {
        let value = try JSONDecoder().decode(SocketServer.JSONValue.self,
            from: Data(#"{"items":[1,2.5,true,"text"]}"#.utf8))
        let object = try #require(value.propertyListValue)
        #expect(PropertyListSerialization.propertyList(object, isValidFor: .binary))
        #expect(SocketServer.JSONValue.double(.infinity).propertyListValue == nil)
    }

    @Test func volumeFormattingDistinguishesMuteAndInvalidInput() {
        #expect(AudioLogFormatting.linearVolume(0).contains("muted"))
        #expect(AudioLogFormatting.linearVolume(-1).contains("muted"))
        #expect(AudioLogFormatting.linearVolume(1).contains("0.00 dB"))
        #expect(AudioLogFormatting.linearVolume(0.5).contains("-6.02 dB"))
        #expect(AudioLogFormatting.linearVolume(.nan).contains("invalid"))
        #expect(AudioLogFormatting.linearVolume(.infinity).contains("invalid"))
    }
}
