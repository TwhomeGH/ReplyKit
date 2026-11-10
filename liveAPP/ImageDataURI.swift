import CryptoKit
import Foundation
import ImageIO
import UIKit

/// 單張內嵌圖片的驗證結果；不保留 base64 解碼後的 Data。
struct ImageDataURIReference: Sendable {
    let uri: String
    let mimeType: String
    let encodedCharacterCount: Int
    let cacheKey: String

    var estimatedBytes: Int {
        encodedCharacterCount * 3 / 4
    }
}

/// `data:image/...;base64,...` 的集中解析、大小限制、解碼與日誌遮蔽。
enum ImageDataURI {
    static let maxEncodedBytes = 256 * 1024
    static let maxTotalBytes = 768 * 1024
    static let maxPixels = 4_000_000
    static let maxThumbnailDimension = 2048

    private static let allowedMIMETypes: Set<String> = [
        "image/png", "image/jpeg", "image/webp", "image/gif"
    ]
    private static let allowedImageTypes: Set<String> = [
        "public.png", "public.jpeg", "org.webmproject.webp", "com.compuserve.gif"
    ]
    private static let redactionRegex = try? NSRegularExpression(
        pattern: #"data:image/[^\s,]+;base64,[A-Za-z0-9+/=]+"#,
        options: [.caseInsensitive])

    /// 只接受標準 base64 data URI；不支援 URL-encoded、SVG 或非圖片資料。
    static func reference(from value: String) -> ImageDataURIReference? {
        guard value.utf8.count <= maxEncodedBytes * 4 / 3 + 512,
              value.lowercased().hasPrefix("data:image/"),
              let comma = value.firstIndex(of: ",") else {
            return nil
        }
        let headerStart = value.index(value.startIndex, offsetBy: 5)
        let fields = value[headerStart..<comma]
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { String($0).lowercased() }
        guard fields.count == 2,
              allowedMIMETypes.contains(fields[0]),
              fields[1] == "base64" else {
            return nil
        }
        let payload = value[value.index(after: comma)...]
        let base64Characters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        guard !payload.isEmpty,
              payload.utf8.count <= maxEncodedBytes * 4 / 3 + 8,
              payload.utf8.allSatisfy({
                  base64Characters.contains(Character(UnicodeScalar($0)))
              }) else {
            return nil
        }
        let digest = SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return ImageDataURIReference(
            uri: value,
            mimeType: fields[0],
            encodedCharacterCount: payload.count,
            cacheKey: "data:" + digest)
    }

    /// 由 ImageIO 驗證實際格式並縮圖，避免 `UIImage(data:)` 一次解開大圖。
    static func decode(_ reference: ImageDataURIReference) -> UIImage? {
        guard let comma = reference.uri.firstIndex(of: ",") else { return nil }
        let payload = String(reference.uri[reference.uri.index(after: comma)...])
        guard let data = Data(base64Encoded: payload, options: []),
              data.count <= maxEncodedBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              allowedImageTypes.contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0,
              width * height <= maxPixels else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxThumbnailDimension
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    /// 日誌只保留圖片類型與 base64 長度，不寫入圖片內容。
    static func redacted(_ text: String) -> String {
        guard text.range(of: "data:image/", options: .caseInsensitive) != nil,
              let regex = redactionRegex else {
            return text
        }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let token = result[range]
            let header = token.split(separator: ",", maxSplits: 1).first ?? ""
            let payloadCount = token.split(separator: ",", maxSplits: 1).last?.count ?? 0
            result.replaceSubrange(range, with: "\(header),<\(payloadCount) base64 chars>")
        }
        return result
    }
}
