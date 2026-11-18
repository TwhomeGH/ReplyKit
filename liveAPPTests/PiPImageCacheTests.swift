import Testing
import UIKit
@testable import liveAPP

struct PiPImageCacheTests {
    @Test @MainActor func embeddedImageIsDownsampledAndReloadsAfterClear() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1024, height: 256))
        let data = renderer.pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1024, height: 256))
        }
        let uri = "data:image/png;base64," + data.base64EncodedString()
        let cache = PiPImageCache()
        for _ in 0..<2 {
            let image: UIImage? = await withCheckedContinuation { continuation in
                Task { await cache.loadImage(urlString: uri) { continuation.resume(returning: $0) } }
            }
            let cg = try #require(image?.cgImage)
            #expect(cg.width <= 512)
            #expect(cg.width == cg.height * 4)
            await cache.clear()
        }
    }

    @Test @MainActor func invalidURLCompletesWithoutNetwork() async {
        let cache = PiPImageCache()
        let image: UIImage? = await withCheckedContinuation { continuation in
            Task { await cache.loadImage(urlString: "file:///private/test.png") { continuation.resume(returning: $0) } }
        }
        #expect(image == nil)
    }
}
