import Foundation
import Testing
@testable import liveAPP

struct StreamMessageTests {
    private func decode(_ extra: String) throws -> SocketServer.ChatMessage {
        let json = "{\"user\":\"A\",\"message\":\"hello\"" + extra + "}"
        return try JSONDecoder().decode(SocketServer.ChatMessage.self, from: Data(json.utf8))
    }
    @Test func missingAndNullAllowTTS() throws {
        #expect(try decode("").useTTS)
        #expect(try decode(",\"useTTS\":null").useTTS)
    }
    @Test func explicitBooleanControlsTTS() throws {
        #expect(try decode(",\"useTTS\":true").useTTS)
        #expect(try !decode(",\"useTTS\":false").useTTS)
    }
    @Test func skippingTTSKeepsChatFields() throws {
        let item = try decode(",\"useTTS\":false,\"isMain\":false,\"userNum\":\"1234\",\"userList\":[\"A\",\"B\"],\"img\":\"avatar\",\"giftImg\":\"gift\"")
        #expect(item.user == "A" && item.message == "hello")
        #expect(item.isMain == false && item.userNum == 1234)
        #expect(item.userList == ["A", "B"])
        #expect(item.img == "avatar" && item.giftImg == "gift")
        #expect(!item.useTTS)
    }
    @Test func nonBooleanValuesAreRejected() {
        for value in ["\"false\"", "0", "1", "[]", "{}"] {
            do {
                _ = try decode(",\"useTTS\":" + value)
                Issue.record("非布林 useTTS 應解碼失敗")
            } catch { }
        }
    }
}
