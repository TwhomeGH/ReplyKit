import Testing
import UIKit
@testable import liveAPP

struct HexColorTests {
    @Test func parsesSixDigitHexWithOrWithoutHash() {
        #expect(UIColor(hex: "#DBDBDB")?.hexRGB == "#DBDBDB")
        #expect(UIColor(hex: "12AB34")?.hexRGB == "#12AB34")
    }

    @Test func rejectsMalformedHex() {
        for value in ["", "#12345", "#1234567", "#GGGGGG", "DBDBDB00"] {
            #expect(UIColor(hex: value) == nil)
        }
    }

    @Test func formatsPickedColorBackToStableHex() {
        #expect(UIColor.red.hexRGB == "#FF0000")
    }
}
