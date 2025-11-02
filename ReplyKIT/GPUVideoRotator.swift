import Metal
import VideoToolbox
import CoreMedia
import simd

import Foundation


import CoreVideo


// MARK: - CVPixelBuffer InUse Extension
private extension CVPixelBuffer {
    private static var _inUseKey: UInt8 = 0

    var inUse: Bool {
        get { objc_getAssociatedObject(self, &CVPixelBuffer._inUseKey) as? Bool ?? false }
        set { objc_setAssociatedObject(self, &CVPixelBuffer._inUseKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

// MARK: - GPU Video Rotator

final class ReusableBuffer {
    let pixelBuffer: CVPixelBuffer
    var inUse: Bool = false
    var yTex: MTLTexture?
    var uTex: MTLTexture?
    var vTex: MTLTexture?

    init(pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
    }
}



final class RPVideoRotatorNV12Queue: @unchecked Sendable {

    enum RotationAngle: UInt32, CaseIterable {
        case angle0 = 0, angle90 = 90, angle180 = 180, angle270 = 270
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var computePipeline: MTLComputePipelineState!
    var textureCache: CVMetalTextureCache?

    var dstWW: Int = 0
    var dstHH: Int = 0
    var useBic: Bool = true
    var debug: Bool = false

    struct Params {
        var srcWidth: UInt32
        var srcHeight: UInt32
        var dstWidth: UInt32
        var dstHeight: UInt32
        var angle: UInt32
        var useBicubic: UInt32

        var tileWidth: UInt32
        var tileHeight: UInt32

    }

    // MARK: - buffer pool with max size
    private struct PooledBuffer {
        var pixelBuffer: CVPixelBuffer
        var lastUsed: Date
    }
    private var bufferPool: [PooledBuffer] = []
    private let poolLock = NSLock()
    private let maxPoolSize: Int

    private var inflightSemaphore: DispatchSemaphore

    
    // async 版本的 wait
    private func waitForAvailableSlot() async {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                self.inflightSemaphore.wait()
                cont.resume()
            }
        }
    }

    // signal 保持同步即可
    private func releaseSlot() {
        inflightSemaphore.signal()
    }


    init?(dstW: Int = 0, dstH: Int = 0, useBic: Bool = true, debug: Bool = false, maxPoolSize: Int = 20) {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else { return nil }

        self.device = dev
        self.queue = q
        self.dstWW = dstW
        self.dstHH = dstH
        self.useBic = useBic
        self.debug = debug
        self.maxPoolSize = maxPoolSize

        // 自動計算合理的 inflight 數量
        let recommended = ProcessInfo.processInfo.activeProcessorCount
        let inflightCount = max(2, min(8, recommended))  // 最少 2 幀，最多 8 幀
        inflightSemaphore = DispatchSemaphore(value: inflightCount)

        logTo("Auto Process Count:\(inflightCount)")

        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        if !buildComputePipeline() { return nil }
    }

    func cleanup() {

        poolLock.lock()
        bufferPool.removeAll()  // 釋放所有 pixelBuffer
        poolLock.unlock()

        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
        textureCache = nil

        logTo("[GPU Rotator] cleanup called")
    }

    func logTo(_ message:String) {
        if debug {
            sendlog(message: message)
        }
    }


    func rotateAsync(sampleBuffer: CMSampleBuffer, angle: RotationAngle) async -> CMSampleBuffer? {

        await waitForAvailableSlot()

        guard let inBuffer = sampleBuffer.imageBuffer else { return nil }
        let srcW = CVPixelBufferGetWidth(inBuffer)
        let srcH = CVPixelBufferGetHeight(inBuffer)
        var dstW = (angle == .angle90 || angle == .angle270) ? srcH : srcW
        var dstH = (angle == .angle90 || angle == .angle270) ? srcW : srcH
        if dstWW > 0 && dstHH > 0 { dstW = dstWW; dstH = dstHH }

        // 嘗試重用 buffer
        guard let outPB = getReusableBuffer(width: dstW, height: dstH),
              let yTexOut = makeTexture(from: outPB, planeIndex: 0),
              let uvTexOut = makeTexture(from: outPB, planeIndex: 1),
              let yTexIn = makeTexture(from: inBuffer, planeIndex: 0),
              let uvTexIn = makeTexture(from: inBuffer, planeIndex: 1),
              let cmd = queue.makeCommandBuffer() else { return nil }

        logTo("GPU: \(srcW) x \(srcH) -> \(dstW) x \(dstH)")

        renderPlaneYUV(cmd: cmd, srcY: yTexIn, srcUV: uvTexIn, dstY: yTexOut, dstUV: uvTexOut, angle: angle)



        return await withCheckedContinuation { cont in
            cmd.addCompletedHandler { _ in


                self.releaseSlot() // GPU 完成 → 允許下一幀進入
                self.logTo("GPU處理完成 Frame")

                cont.resume(returning: self.wrapPixelBuffer(outPB, originalSampleBuffer: sampleBuffer))
            }
            cmd.commit()
        }
    }

    // MARK: - buffer pool with reuse & auto trim
    private func getReusableBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        poolLock.lock()
        defer { poolLock.unlock() }

        // 嘗試找到合適 buffer
        if let idx = bufferPool.firstIndex(where: { CVPixelBufferGetWidth($0.pixelBuffer) == width && CVPixelBufferGetHeight($0.pixelBuffer) == height }) {
            bufferPool[idx].lastUsed = Date()
            return bufferPool[idx].pixelBuffer
        }

        // 建立新 buffer
        var newPB: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs as CFDictionary, &newPB)

        if let pb = newPB {
            bufferPool.append(PooledBuffer(pixelBuffer: pb, lastUsed: Date()))
        }

        // 自動清理最舊 buffer
        if bufferPool.count > maxPoolSize {
            bufferPool.sort { $0.lastUsed < $1.lastUsed }
            bufferPool.removeFirst(bufferPool.count - maxPoolSize)
        }

        return newPB
    }

    // MARK: - Texture Utilities
    private func makeTexture(from pixelBuffer: CVPixelBuffer, planeIndex: Int) -> MTLTexture? {
        guard let cache = textureCache else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
        let pixelFormat: MTLPixelFormat = (planeIndex == 0) ? .r8Unorm : .rg8Unorm

        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, pixelFormat, width, height, planeIndex, &cvTex)
        guard status == kCVReturnSuccess, let tex = cvTex else { return nil }
        return CVMetalTextureGetTexture(tex)
    }

    private func renderPlaneYUV(cmd: MTLCommandBuffer, srcY: MTLTexture, srcUV: MTLTexture, dstY: MTLTexture, dstUV: MTLTexture, angle: RotationAngle) {
        guard let compute = computePipeline, let encoder = cmd.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(compute)
        encoder.setTexture(srcY, index: 0)
        encoder.setTexture(srcUV, index: 1)
        encoder.setTexture(dstY, index: 2)
        encoder.setTexture(dstUV, index: 3)


        let w = compute.threadExecutionWidth
        let h = max(1, compute.maxTotalThreadsPerThreadgroup / w)

        logTo("GPU Thread:\(w) \(h)")
        
        var params = Params(srcWidth: UInt32(srcY.width),
                            srcHeight: UInt32(srcY.height),
                            dstWidth: UInt32(dstY.width),
                            dstHeight: UInt32(dstY.height),
                            angle: UInt32(angle.rawValue),
                            useBicubic: useBic ? 1 : 0,
                            tileWidth: UInt32(w),
                            tileHeight: UInt32(h)
        )
        
        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)


        encoder.dispatchThreads(MTLSize(width: dstY.width, height: dstY.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))


        encoder.endEncoding()
    }

    private func buildComputePipeline() -> Bool {
        do {
            let lib = device.makeDefaultLibrary()
            guard let kernel = lib?.makeFunction(name: "rotateNV12_tileBicubicUV") else { return false }
            computePipeline = try device.makeComputePipelineState(function: kernel)
            return true
        } catch {
            return false
        }
    }

    private func wrapPixelBuffer(_ pixelBuffer: CVPixelBuffer, originalSampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        var timingInfo = CMSampleTimingInfo.invalid
        CMSampleBufferGetSampleTimingInfo(originalSampleBuffer, at: 0, timingInfoOut: &timingInfo)

        var formatDesc: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDesc) == noErr,
              let fmt = formatDesc else { return nil }

        var newBuffer: CMSampleBuffer?
        let ret = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt, sampleTiming: &timingInfo, sampleBufferOut: &newBuffer)
        guard ret == noErr else { return nil }
        return newBuffer
    }
}





// 安全陣列取值
extension Collection {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}


// 擴展：快速建立 CVMetalTextureCache
extension CVMetalTextureCache {
    static func create(device: MTLDevice) throws -> CVMetalTextureCache {
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let texCache = cache else { throw NSError() }
        return texCache
    }
}





