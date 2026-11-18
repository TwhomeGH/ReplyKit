import Foundation
import ImageIO
import UIKit

/// 有界圖片載入：遠端／內嵌共用三個工作名額，快取僅保存已解碼縮圖。
/// 同網址合併回呼；過載立即回 nil，避免已退場訊息無限持有等待工作。
actor PiPImageCache {
    static let shared = PiPImageCache()
    static let workerLimit = 3
    static let waitingLimit = 48
    static let callbackLimit = 16
    static let byteLimit = 4 * 1024 * 1024
    static let thumbnailSize = 512

    private struct Request {
        let input: String
        var callbacks: [(UIImage?) -> Void]
    }
    /// UIImage 僅在背景建立、主執行緒讀取，不跨工作修改。
    private struct ResultImage: @unchecked Sendable {
        let image: UIImage?
        let downloadMs: Double
        let decodeMs: Double
    }
    private let cache = NSCache<NSString, UIImage>()
    private let session: URLSession
    private var requests: [String: Request] = [:]
    private var workers: [String: Task<Void, Never>] = [:]
    private var waiting: [String] = []
    private var failures: [String: TimeInterval] = [:]
    private var generation = UUID()
    private var lastReport = ProcessInfo.processInfo.systemUptime
    private var hits = 0, misses = 0, rejected = 0, completed = 0, failed = 0, stale = 0
    private var maxDownloadMs = 0.0, maxDecodeMs = 0.0

    init(session: URLSession? = nil) {
        cache.countLimit = 64
        cache.totalCostLimit = 20 * 1024 * 1024
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 20
            // 即時疊加不等待恢復網路占住名額；失敗冷卻後可由新請求重試。
            config.waitsForConnectivity = false
            config.httpMaximumConnectionsPerHost = 3
            config.httpAdditionalHeaders = ["Accept": "image/*", "User-Agent": Self.makeUserAgent()]
            config.urlCache = URLCache(memoryCapacity: 4 * 1024 * 1024,
                                      diskCapacity: 30 * 1024 * 1024, diskPath: "PIPImageCache")
            self.session = URLSession(configuration: config)
        }
    }

    /// 延用既有網站相容標頭，避免快取改造同時改變圖片伺服器回應。
    private static func makeUserAgent() -> String {
        let isIPad = DeviceInfo.deviceCode.hasPrefix("iPad")
        let device = isIPad ? "iPad" : "iPhone"
        let cpuToken = isIPad ? "CPU OS" : "CPU iPhone OS"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(os.majorVersion)_\(os.minorVersion)"
        let safariVersion = "\(os.majorVersion).\(os.minorVersion)"
        return "Mozilla/5.0 (\(device); \(cpuToken) \(osVersion) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVersion) Mobile/15E148 Safari/604.1"
    }

    /// 每個請求最多回呼一次；clear 時尚未完成者回 nil。下載不代表仍需顯示，呼叫端應核對事件 ID。
    func loadImage(urlString: String, completion: @escaping (UIImage?) -> Void) async {
        let key: String
        if urlString.lowercased().hasPrefix("data:") {
            guard let reference = ImageDataURI.reference(from: urlString) else {
                await MainActor.run { completion(nil) }; return
            }
            key = reference.cacheKey
        } else {
            guard urlString.utf8.count <= 8192, let url = URL(string: urlString),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                await MainActor.run { completion(nil) }; return
            }
            key = urlString
        }
        if let image = cache.object(forKey: key as NSString) {
            hits += 1
            await MainActor.run { completion(image) }
            return
        }
        if let expiry = failures[key], expiry > ProcessInfo.processInfo.systemUptime {
            rejected += 1
            await MainActor.run { completion(nil) }; return
        }
        if var request = requests[key] {
            guard request.callbacks.count < Self.callbackLimit else {
                rejected += 1
                await MainActor.run { completion(nil) }; return
            }
            request.callbacks.append(completion)
            requests[key] = request
            return
        }
        guard waiting.count < Self.waitingLimit else {
            rejected += 1
            await MainActor.run { completion(nil) }; return
        }
        misses += 1
        requests[key] = Request(input: urlString, callbacks: [completion])
        waiting.append(key)
        startNext()
    }

    /// 取消中的工作仍占用名額；同 key 的新世代必須等待舊工作返回。
    private func startNext() {
        while workers.count < Self.workerLimit, let index = waiting.firstIndex(where: { workers[$0] == nil }) {
            let key = waiting.remove(at: index)
            guard let request = requests[key] else { continue }
            let token = generation
            let session = session
            workers[key] = Task {
                let result = await Self.fetch(request.input, session: session)
                await finish(key, token: token, result: result)
            }
        }
    }

    /// 移除整組工作後才跨到主執行緒，避免新回呼掛入已完成工作而遺失。
    private func finish(_ key: String, token: UUID, result: ResultImage) async {
        guard token == generation else {
            stale += 1
            workers[key] = nil
            startNext()
            return
        }
        let callbacks = requests.removeValue(forKey: key)?.callbacks ?? []
        workers[key] = nil
        maxDownloadMs = max(maxDownloadMs, result.downloadMs)
        maxDecodeMs = max(maxDecodeMs, result.decodeMs)
        if let image = result.image, let cg = image.cgImage {
            completed += 1
            cache.setObject(image, forKey: key as NSString, cost: cg.bytesPerRow * cg.height)
        } else {
            failed += 1
            failures = failures.filter { $0.value > ProcessInfo.processInfo.systemUptime }
            if failures.count >= 64 { failures.removeAll() }
            failures[key] = ProcessInfo.processInfo.systemUptime + 15
        }
        startNext()
        await MainActor.run { for callback in callbacks { callback(result.image) } }
        reportIfNeeded()
    }

    /// 在串流接收途中限制位元組；不能只檢查 Content-Length，因伺服器可能未提供或不正確。
    private static func fetch(_ input: String, session: URLSession) async -> ResultImage {
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let data: Data
            if input.lowercased().hasPrefix("data:") {
                guard let reference = ImageDataURI.reference(from: input),
                      let comma = reference.uri.firstIndex(of: ","),
                      let decoded = Data(base64Encoded: String(reference.uri[reference.uri.index(after: comma)...])),
                      decoded.count <= ImageDataURI.maxEncodedBytes else { throw URLError(.cannotDecodeContentData) }
                data = decoded
            } else {
                guard let url = URL(string: input) else { throw URLError(.badURL) }
                let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      response.expectedContentLength <= Int64(byteLimit) else {
                    bytes.task.cancel()
                    throw URLError(.dataLengthExceedsMaximum)
                }
                var received = Data()
                do {
                    for try await byte in bytes {
                        if received.count >= byteLimit { throw URLError(.dataLengthExceedsMaximum) }
                        if received.count % 16384 == 0 { try Task.checkCancellation() }
                        received.append(byte)
                    }
                } catch { bytes.task.cancel(); throw error }
                data = received
            }
            try Task.checkCancellation()
            let downloaded = ProcessInfo.processInfo.systemUptime
            let decodeTask = Task.detached(priority: .utility) { decode(data) }
            let image = await withTaskCancellationHandler(operation: { await decodeTask.value },
                                                         onCancel: { decodeTask.cancel() })
            try Task.checkCancellation()
            return ResultImage(image: image.image, downloadMs: (downloaded - started) * 1000,
                               decodeMs: (ProcessInfo.processInfo.systemUptime - downloaded) * 1000)
        } catch {
            return ResultImage(image: nil, downloadMs: (ProcessInfo.processInfo.systemUptime - started) * 1000, decodeMs: 0)
        }
    }

    /// 拒絕極大像素圖片，解碼首幀為最大 512px 縮圖；不在主執行緒做首次解壓。
    private static func decode(_ data: Data) -> ResultImage {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? NSNumber,
              let h = props[kCGImagePropertyPixelHeight] as? NSNumber,
              w.doubleValue > 0, h.doubleValue > 0, w.doubleValue * h.doubleValue <= 16_000_000,
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnailSize] as CFDictionary), !Task.isCancelled else {
            return ResultImage(image: nil, downloadMs: 0, decodeMs: 0)
        }
        return ResultImage(image: UIImage(cgImage: cg), downloadMs: 0, decodeMs: 0)
    }

    /// 取消跨世代回寫並釋放等待回呼；不會清掉新世代的工作計數。
    func clear() async {
        generation = UUID()
        let callbacks = requests.values.flatMap(\.callbacks)
        workers.values.forEach { $0.cancel() }
        // 已取消的解碼仍保留名額，直到工作真正返回，避免反覆 clear 繞過並行上限。
        requests.removeAll()
        waiting.removeAll()
        failures.removeAll()
        cache.removeAllObjects()
        await MainActor.run { for callback in callbacks { callback(nil) } }
    }

    /// 正常最多每五分鐘一筆；不寫圖片網址或內容，HTTP cache 統計使用本身的 cache。
    func reportIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastReport >= 300 else { return }
        sendlog(message: "[PiPImageCache] active=\(workers.count)/\(Self.workerLimit) waiting=\(waiting.count)/\(Self.waitingLimit) hits=\(hits) misses=\(misses) completed=\(completed) failed=\(failed) rejected=\(rejected) stale=\(stale) maxDownloadMs=\(maxDownloadMs) maxDecodeMs=\(maxDecodeMs) httpMemoryBytes=\(session.configuration.urlCache?.currentMemoryUsage ?? 0) httpDiskBytes=\(session.configuration.urlCache?.currentDiskUsage ?? 0)")
        lastReport = now
        hits = 0; misses = 0; completed = 0; failed = 0; rejected = 0; stale = 0
        maxDownloadMs = 0; maxDecodeMs = 0
    }
}
