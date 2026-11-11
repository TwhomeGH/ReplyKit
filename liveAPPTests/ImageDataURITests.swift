import Foundation
import Testing
import UIKit
@testable import liveAPP

struct ImageDataURITests {
    private func pngDataURI() throws -> String {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let data = try #require(image.pngData())
        return "data:image/png;base64,\(data.base64EncodedString())"
    }

    @Test func parsesAndDecodesEmbeddedPNG() throws {
        let uri = try pngDataURI()
        let reference = try #require(ImageDataURI.reference(from: uri))
        #expect(reference.mimeType == "image/png")
        #expect(ImageDataURI.decode(reference) != nil)
    }

    @Test func rejectsUnsupportedOrOversizedData() {
        #expect(ImageDataURI.reference(from: "data:image/svg+xml;base64,PHN2Zz4=") == nil)
        #expect(ImageDataURI.reference(from: "data:image/png;base64,not base64") == nil)
        let oversized = "data:image/png;base64," + String(repeating: "A", count: 400_000)
        #expect(ImageDataURI.reference(from: oversized) == nil)
    }

    @Test func extractsDataURIWithoutLeavingPayloadInMessage() throws {
        let uri = try pngDataURI()
        let result = PIPServiceMessages.extractAllImageURLs(from: "hello \(uri) world")
        #expect(result.imageURLs == [uri])
        #expect(result.cleaned.contains("hello"))
        #expect(result.cleaned.contains("world"))
        #expect(!result.cleaned.contains("base64"))
        #expect(result.imagePositions.count == 1)
    }

    @Test func extractsKnownImageURLWithoutFileExtension() {
        let url = "http://192.168.0.102:3332/media/5936554d"
        let result = PIPServiceMessages.extractAllImageURLs(
            from: "贊助訊息 \(url)", knownImageURLs: [url])
        #expect(result.imageURLs == [url])
        #expect(result.cleaned == "贊助訊息 \u{2003}")
        #expect(result.imagePositions == [5])
    }

    @Test func leavesUnknownURLWithoutFileExtensionAsText() {
        let url = "http://192.168.0.102:3332/media/5936554d"
        let result = PIPServiceMessages.extractAllImageURLs(from: "請看 \(url)")
        #expect(result.imageURLs.isEmpty)
        #expect(result.cleaned == "請看 \(url)")
    }

    @Test func imagePositionUsesUTF16WhenEmojiPrecedesURL() {
        let result = PIPServiceMessages.extractAllImageURLs(from: "🎉 http://example.com/a.png")
        #expect(result.imageURLs.count == 1)
        // 🎉 是 surrogate pair，佔 2 個 UTF-16 code units；空格再加 1。
        #expect(result.imagePositions == [3])
    }

    @Test func redactsDataURIInLogs() throws {
        let uri = try pngDataURI()
        let redacted = ImageDataURI.redacted("send \(uri) end")
        #expect(!redacted.contains(uri))
        #expect(redacted.contains("base64 chars"))
    }

    @Test func rejectsDataURIOnCacheMissWithoutNetworkFallback() async {
        let image = await withCheckedContinuation { continuation in
            Task {
                await PiPImageCache.shared.loadImage(
                    urlString: "data:image/png;base64,not base64"
                ) { image in
                    continuation.resume(returning: image)
                }
            }
        }
        #expect(image == nil)
    }
}
