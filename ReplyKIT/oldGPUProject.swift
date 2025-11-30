////
////  oldGPUProject.swift
////  liveAPP
////
////  Created by user on 2025/11/26.
////
//
//
//import Metal
//import VideoToolbox
//import CoreVideo
//import CoreMedia
//import simd
//
//import Foundation
//import AVFoundation
//import Accelerate
//
//import HaishinKit
//
//
//// TODO: 之前的旋轉 備用 棄用
//
//
//
//// MARK: - 高動態自適應 GPU NV12 Rotator 最終版
//final class RPVideoRotatorNV12AdaptiveFinal: @unchecked Sendable {
//
//    enum RotationAngle: UInt32, CaseIterable {
//        case angle0 = 0, angle90 = 90, angle180 = 180, angle270 = 270
//    }
//
//    private let device: MTLDevice
//    private let queue: MTLCommandQueue
//    private var computePipeline: MTLComputePipelineState!
//    var textureCache: CVMetalTextureCache?
//
//    var mediaMixer: MediaMixer
//
//    var dstWW: Int = 0
//    var dstHH: Int = 0
//    var debug: Bool = false
//    var useBic: Bool = false
//
//
//    struct Params {
//        var srcWidth: UInt32
//        var srcHeight: UInt32
//        var dstWidth: UInt32
//        var dstHeight: UInt32
//        var angle: UInt32
//        var useBicubic: UInt32
//        var tileWidth: UInt32
//        var tileHeight: UInt32
//    }
//
//    // MARK: - Buffer Pool
//    private struct PooledBuffer {
//        var pixelBuffer: CVPixelBuffer
//        var lastUsed: Date
//    }
//
//    private var frameQueue: [(CMSampleBuffer, RotationAngle, CheckedContinuation<CMSampleBuffer?, Never>)] = []
//    private let queueLock = NSLock()
//
//    private var bufferPool: [PooledBuffer] = []
//    private let poolLock = NSLock()
//    private let maxPoolSize: Int
//    private var inflightSemaphore: DispatchSemaphore
//
//    // MARK: - 動態屬性
//    private var lastFrameTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
//    private var smoothScale: Double = 1.0
//    private let maxTileScale: Double = 3.0
//    private let minTileScale: Double = 1.0
//
//    // MARK: - Init
//    init?(dstW: Int = 0,
//          dstH: Int = 0,
//          debug: Bool = false,
//          useBic:Bool = false,
//          maxPoolSize: Int = 5,
//          mediaMixer: MediaMixer) {
//
//        guard let dev = MTLCreateSystemDefaultDevice(),
//              let q = dev.makeCommandQueue() else { return nil }
//        self.device = dev
//        self.queue = q
//        self.dstWW = dstW
//        self.dstHH = dstH
//        self.debug = debug
//        self.useBic = useBic
//        self.maxPoolSize = maxPoolSize
//        self.mediaMixer = mediaMixer
//
//        let recommended = ProcessInfo.processInfo.activeProcessorCount
//        inflightSemaphore = DispatchSemaphore(value: max(2, min(8, recommended)))
//
//        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
//        if !buildComputePipeline() { return nil }
//    }
//
//    // MARK: - Cleanup
//    func cleanup() {
//        poolLock.lock()
//        bufferPool.removeAll()
//        poolLock.unlock()
//        if let cache = textureCache {
//            CVMetalTextureCacheFlush(cache, 0)
//        }
//        textureCache = nil
//        logTo("cleanup called")
//    }
//
//    private func logTo(_ message: String) {
//        if debug { print("[GPU Rotator] \(message)") }
//    }
//
//    private func tryAcquireSlot() async -> Bool {
//        await withCheckedContinuation { cont in
//            DispatchQueue.global().async {
//                if self.inflightSemaphore.wait(timeout: .now()) == .success {
//                    cont.resume(returning: true)
//                } else {
//                    cont.resume(returning: false)
//                }
//            }
//        }
//    }
//
//
//    // MARK: - Main rotate API
//    func rotateAsync(sampleBuffer: CMSampleBuffer, angle: RotationAngle) async -> CMSampleBuffer? {
//
//
//
//        // 使用：
//        guard await tryAcquireSlot() else { return nil } // pipeline 忙，丟掉幀
//
//        guard let inBuffer = sampleBuffer.imageBuffer else {
//            releaseSlot()
//            return nil
//        }
//
//        let srcW = CVPixelBufferGetWidth(inBuffer)
//        let srcH = CVPixelBufferGetHeight(inBuffer)
//        var dstW = (angle == .angle90 || angle == .angle270) ? srcH : srcW
//        var dstH = (angle == .angle90 || angle == .angle270) ? srcW : srcH
//        if dstWW > 0 && dstHH > 0 { dstW = dstWW; dstH = dstHH }
//
//        guard let outPB = getReusableBuffer(width: dstW, height: dstH),
//              let yTexOut = makeTexture(from: outPB, planeIndex: 0),
//              let uvTexOut = makeTexture(from: outPB, planeIndex: 1),
//              let yTexIn = makeTexture(from: inBuffer, planeIndex: 0),
//              let uvTexIn = makeTexture(from: inBuffer, planeIndex: 1),
//              let cmd = queue.makeCommandBuffer() else {
//            releaseSlot()
//            return nil
//        }
//
//        // 計算幀間隔 -> 平滑動態 tile
//        let now = CFAbsoluteTimeGetCurrent()
//        let delta = now - lastFrameTime
//        lastFrameTime = now
//
//        let targetDelta = 1.0 / 60.0
//        let desiredScale = max(minTileScale, min(maxTileScale, targetDelta / delta))
//        smoothScale = smoothScale * 0.9 + desiredScale * 0.1 // 平滑過渡
//
//        // 高動態自動降級 bicubic
//        let useBicubic = smoothScale <= 1.5
//
//        renderPlaneYUV(cmd: cmd, srcY: yTexIn, srcUV: uvTexIn, dstY: yTexOut, dstUV: uvTexOut,
//                       angle: angle, dynamicScale: smoothScale, useBicubic: useBicubic)
//
//        return await withCheckedContinuation { cont in
//            cmd.addCompletedHandler { _ in
//
//                self.releaseSlot()
//                self.logTo("GPU Frame Done")
//                cont.resume(returning: self.wrapPixelBuffer(outPB, originalSampleBuffer: sampleBuffer))
//            }
//            cmd.commit()
//        }
//
//
//
//    }
//
//
//
//
//
//
//
//
//
//
//    // MARK: - Buffer Pool
//    private func getReusableBuffer(width: Int, height: Int) -> CVPixelBuffer? {
//        poolLock.lock()
//        defer { poolLock.unlock() }
//
//        if let idx = bufferPool.firstIndex(where: { CVPixelBufferGetWidth($0.pixelBuffer) == width && CVPixelBufferGetHeight($0.pixelBuffer) == height }) {
//            bufferPool[idx].lastUsed = Date()
//            return bufferPool[idx].pixelBuffer
//        }
//
//        var newPB: CVPixelBuffer?
//        let attrs: [String: Any] = [
//            kCVPixelBufferMetalCompatibilityKey as String: true,
//            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
//            kCVPixelBufferWidthKey as String: width,
//            kCVPixelBufferHeightKey as String: height
//        ]
//        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs as CFDictionary, &newPB)
//
//        if let pb = newPB {
//            bufferPool.append(PooledBuffer(pixelBuffer: pb, lastUsed: Date()))
//        }
//
//        if bufferPool.count > maxPoolSize {
//            bufferPool.sort { $0.lastUsed < $1.lastUsed }
//            bufferPool.removeFirst(bufferPool.count - maxPoolSize)
//        }
//
//        return newPB
//    }
//
//    // MARK: - Texture
//    private func makeTexture(from pixelBuffer: CVPixelBuffer, planeIndex: Int) -> MTLTexture? {
//        guard let cache = textureCache else { return nil }
//        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
//        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
//        let pixelFormat: MTLPixelFormat = (planeIndex == 0) ? .r8Unorm : .rg8Unorm
//
//        var cvTex: CVMetalTexture?
//        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil,
//                                                               pixelFormat, width, height, planeIndex, &cvTex)
//        guard status == kCVReturnSuccess, let tex = cvTex else { return nil }
//        return CVMetalTextureGetTexture(tex)
//    }
//
//    private func renderPlaneYUV(cmd: MTLCommandBuffer,
//                                srcY: MTLTexture, srcUV: MTLTexture,
//                                dstY: MTLTexture, dstUV: MTLTexture,
//                                angle: RotationAngle,
//                                dynamicScale: Double,
//                                useBicubic: Bool) {
//
//        guard let compute = computePipeline,
//              let encoder = cmd.makeComputeCommandEncoder() else { return }
//
//        encoder.setComputePipelineState(compute)
//        encoder.setTexture(srcY, index: 0)
//        encoder.setTexture(srcUV, index: 1)
//        encoder.setTexture(dstY, index: 2)
//        encoder.setTexture(dstUV, index: 3)
//
//        // 計算 threadgroup
//        let baseW = min(compute.threadExecutionWidth, 32)
//        let baseH = max(1, compute.maxTotalThreadsPerThreadgroup / baseW)
//
//        var tgWidth = min(Int(Double(baseW) * dynamicScale), compute.maxTotalThreadsPerThreadgroup)
//        var tgHeight = min(Int(Double(baseH) * dynamicScale), compute.maxTotalThreadsPerThreadgroup / tgWidth)
//
//        // 確保不超過 GPU 最大限制
//        if tgWidth * tgHeight > compute.maxTotalThreadsPerThreadgroup {
//            let scale = sqrt(Double(compute.maxTotalThreadsPerThreadgroup) / Double(tgWidth*tgHeight))
//            tgWidth = max(1, Int(Double(tgWidth) * scale))
//            tgHeight = max(1, Int(Double(tgHeight) * scale))
//        }
//
//        var params = Params(
//            srcWidth: UInt32(srcY.width),
//            srcHeight: UInt32(srcY.height),
//            dstWidth: UInt32(dstY.width),
//            dstHeight: UInt32(dstY.height),
//            angle: UInt32(angle.rawValue),
//            useBicubic: useBicubic ? 1 : 0,
//            tileWidth: UInt32(tgWidth),
//            tileHeight: UInt32(tgHeight)
//        )
//
//        logTo("tgW:\(tgWidth) tgH:\(tgHeight) bicubic:\(useBicubic) scale:\(dynamicScale)")
//
//        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
//        encoder.dispatchThreads(MTLSize(width: dstY.width, height: dstY.height, depth: 1),
//                                threadsPerThreadgroup: MTLSize(width: tgWidth, height: tgHeight, depth: 1))
//        encoder.endEncoding()
//    }
//
//    private func buildComputePipeline() -> Bool {
//        do {
//            let lib = device.makeDefaultLibrary()
//            guard let kernel = lib?.makeFunction(name: "rotateNV12_tileBicubicUV") else { return false }
//            computePipeline = try device.makeComputePipelineState(function: kernel)
//            return true
//        } catch {
//            return false
//        }
//    }
//
//    private func wrapPixelBuffer(_ pixelBuffer: CVPixelBuffer, originalSampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
//        var timingInfo = CMSampleTimingInfo.invalid
//        CMSampleBufferGetSampleTimingInfo(originalSampleBuffer, at: 0, timingInfoOut: &timingInfo)
//
//        var formatDesc: CMFormatDescription?
//        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
//                                                           imageBuffer: pixelBuffer,
//                                                           formatDescriptionOut: &formatDesc) == noErr,
//              let fmt = formatDesc else { return nil }
//
//        var newBuffer: CMSampleBuffer?
//        let ret = CMSampleBufferCreateForImageBuffer(
//            allocator: kCFAllocatorDefault,
//            imageBuffer: pixelBuffer,
//            dataReady: true,
//            makeDataReadyCallback: nil,
//            refcon: nil,
//            formatDescription: fmt,
//            sampleTiming: &timingInfo,
//            sampleBufferOut: &newBuffer
//        )
//        guard ret == noErr else { return nil }
//        return newBuffer
//    }
//
//    // MARK: - Semaphore
//    private func releaseSlot() {
//        inflightSemaphore.signal()
//    }
//}
//
//
//
//
//// MARK: - 高動態自適應 GPU NV12 Rotator
//final class RPVideoRotatorNV12Adaptive: @unchecked Sendable {
//
//    enum RotationAngle: UInt32, CaseIterable {
//        case angle0 = 0, angle90 = 90, angle180 = 180, angle270 = 270
//    }
//
//
//    private let device: MTLDevice
//    private let queue: MTLCommandQueue
//    private var computePipeline: MTLComputePipelineState!
//    var textureCache: CVMetalTextureCache?
//
//    var mediaMixer: MediaMixer
//
//    var dstWW: Int = 0
//    var dstHH: Int = 0
//    var useBic: Bool = false
//    var debug: Bool = false
//
//    struct Params {
//        var srcWidth: UInt32
//        var srcHeight: UInt32
//        var dstWidth: UInt32
//        var dstHeight: UInt32
//        var angle: UInt32
//        var useBicubic: UInt32
//        var tileWidth: UInt32
//        var tileHeight: UInt32
//    }
//
//    // MARK: - Buffer Pool
//    private struct PooledBuffer {
//        var pixelBuffer: CVPixelBuffer
//        var lastUsed: Date
//    }
//    private var bufferPool: [PooledBuffer] = []
//    private let poolLock = NSLock()
//    private let maxPoolSize: Int
//    private var inflightSemaphore: DispatchSemaphore
//
//    // MARK: - 高動態自適應屬性
//    private var lastFrameTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
//    private var dynamicInflightMax: Int
//    private let inflightStep: Int = 1
//    private let maxInflightLimit: Int = 12
//    private let minInflightLimit: Int = 2
//
//    // MARK: - Init
//    init?(
//        dstW: Int = 0,
//        dstH: Int = 0,
//        useBic: Bool = true,
//        debug: Bool = false,
//        maxPoolSize: Int = 5,
//        mediaMixer: MediaMixer
//    ) {
//        guard let dev = MTLCreateSystemDefaultDevice(),
//              let q = dev.makeCommandQueue() else { return nil }
//        self.device = dev
//        self.queue = q
//        self.dstWW = dstW
//        self.dstHH = dstH
//        self.useBic = useBic
//        self.debug = debug
//        self.maxPoolSize = maxPoolSize
//        self.mediaMixer = mediaMixer
//
//        // 自動計算 inflight 初始值
//        let recommended = ProcessInfo.processInfo.activeProcessorCount
//        let initialInflight = max(2, min(8, recommended))
//        dynamicInflightMax = initialInflight
//        inflightSemaphore = DispatchSemaphore(value: initialInflight)
//
//        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
//        if !buildComputePipeline() { return nil }
//    }
//
//    // MARK: - Cleanup
//    func cleanup() {
//        poolLock.lock()
//        bufferPool.removeAll()
//        poolLock.unlock()
//        if let cache = textureCache {
//            CVMetalTextureCacheFlush(cache, 0)
//        }
//        textureCache = nil
//        logTo("cleanup called")
//    }
//
//    // MARK: - Logging
//    private func logTo(_ message: String) {
//        if debug { sendlog(message:"[GPU Rotator] \(message)") }
//    }
//
//    // MARK: - Main rotate API
//    func rotateAsync(sampleBuffer: CMSampleBuffer, angle: RotationAngle) async -> CMSampleBuffer? {
//        await waitForAvailableSlot()
//
//        guard let inBuffer = sampleBuffer.imageBuffer else {
//            releaseSlot()
//            return nil
//        }
//
//        let srcW = CVPixelBufferGetWidth(inBuffer)
//        let srcH = CVPixelBufferGetHeight(inBuffer)
//        var dstW = (angle == .angle90 || angle == .angle270) ? srcH : srcW
//        var dstH = (angle == .angle90 || angle == .angle270) ? srcW : srcH
//        if dstWW > 0 && dstHH > 0 { dstW = dstWW; dstH = dstHH }
//
//        guard let outPB = getReusableBuffer(width: dstW, height: dstH),
//              let yTexOut = makeTexture(from: outPB, planeIndex: 0),
//              let uvTexOut = makeTexture(from: outPB, planeIndex: 1),
//              let yTexIn = makeTexture(from: inBuffer, planeIndex: 0),
//              let uvTexIn = makeTexture(from: inBuffer, planeIndex: 1),
//              let cmd = queue.makeCommandBuffer() else {
//            releaseSlot()
//            return nil
//        }
//
//        logTo("GPU: \(srcW)x\(srcH) -> \(dstW)x\(dstH)")
//
//        // 計算幀間隔 -> 動態自適應 tile
//        let now = CFAbsoluteTimeGetCurrent()
//        let delta = now - lastFrameTime
//        lastFrameTime = now
//
//        let targetDelta = 1.0 / 60.0  // 對應 60fps
//        let dynamicScale = max(1, min(3, Int(targetDelta / delta)))
//
//
//
//        renderPlaneYUV(cmd: cmd, srcY: yTexIn, srcUV: uvTexIn, dstY: yTexOut, dstUV: uvTexOut, angle: angle, dynamicScale: dynamicScale)
//
//        return await withCheckedContinuation { cont in
//            cmd.addCompletedHandler { _ in
//                
//                self.releaseSlot()
//                self.logTo("GPU Frame Done")
//                cont.resume(returning: self.wrapPixelBuffer(outPB, originalSampleBuffer: sampleBuffer))
//            }
//            cmd.commit()
//        }
//    }
//
//    // MARK: - Buffer Pool
//    private func getReusableBuffer(width: Int, height: Int) -> CVPixelBuffer? {
//        poolLock.lock()
//        defer { poolLock.unlock() }
//
//        if let idx = bufferPool.firstIndex(where: { CVPixelBufferGetWidth($0.pixelBuffer) == width && CVPixelBufferGetHeight($0.pixelBuffer) == height }) {
//            bufferPool[idx].lastUsed = Date()
//            return bufferPool[idx].pixelBuffer
//        }
//
//        var newPB: CVPixelBuffer?
//        let attrs: [String: Any] = [
//            kCVPixelBufferMetalCompatibilityKey as String: true,
//            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
//            kCVPixelBufferWidthKey as String: width,
//            kCVPixelBufferHeightKey as String: height
//        ]
//        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs as CFDictionary, &newPB)
//
//        if let pb = newPB {
//            bufferPool.append(PooledBuffer(pixelBuffer: pb, lastUsed: Date()))
//        }
//
//        if bufferPool.count > maxPoolSize {
//            bufferPool.sort { $0.lastUsed < $1.lastUsed }
//            bufferPool.removeFirst(bufferPool.count - maxPoolSize)
//        }
//
//        return newPB
//    }
//
//    // MARK: - Texture
//    private func makeTexture(from pixelBuffer: CVPixelBuffer, planeIndex: Int) -> MTLTexture? {
//        guard let cache = textureCache else { return nil }
//        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
//        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
//        let pixelFormat: MTLPixelFormat = (planeIndex == 0) ? .r8Unorm : .rg8Unorm
//
//        var cvTex: CVMetalTexture?
//        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, pixelFormat, width, height, planeIndex, &cvTex)
//        guard status == kCVReturnSuccess, cvTex != nil else { return nil }
//        return CVMetalTextureGetTexture(cvTex!)
//    }
//
//    private func renderPlaneYUV(cmd: MTLCommandBuffer,
//                                srcY: MTLTexture, srcUV: MTLTexture,
//                                dstY: MTLTexture, dstUV: MTLTexture,
//                                angle: RotationAngle,
//                                dynamicScale: Int = 1) {
//        guard let compute = computePipeline, let encoder = cmd.makeComputeCommandEncoder() else { return }
//
//        encoder.setComputePipelineState(compute)
//        encoder.setTexture(srcY, index: 0)
//        encoder.setTexture(srcUV, index: 1)
//        encoder.setTexture(dstY, index: 2)
//        encoder.setTexture(dstUV, index: 3)
//
//        let baseW = min(compute.threadExecutionWidth,32)
//        let baseH = max(1, compute.maxTotalThreadsPerThreadgroup / baseW)
//
//        let maxThreads = compute.maxTotalThreadsPerThreadgroup
//        let tgWidth = min(baseW * dynamicScale, maxThreads)
//        let tgHeight = min(baseH * dynamicScale, maxThreads / tgWidth)
//
//
//        var params = Params(
//            srcWidth: UInt32(srcY.width),
//            srcHeight: UInt32(srcY.height),
//            dstWidth: UInt32(dstY.width),
//            dstHeight: UInt32(dstY.height),
//            angle: UInt32(angle.rawValue),
//            useBicubic: useBic ? 1 : 0,
//            tileWidth: UInt32(tgWidth),
//            tileHeight: UInt32(tgHeight)
//        )
//
//
//        logTo("tgW:\(tgWidth) tgH:\(tgHeight)")
//
//        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
//        encoder.dispatchThreads(MTLSize(width: dstY.width, height: dstY.height, depth: 1),
//                                threadsPerThreadgroup: MTLSize(
//                                    width: tgWidth,
//                                    height: tgHeight,
//                                    depth: 1))
//        encoder.endEncoding()
//    }
//
//    private func buildComputePipeline() -> Bool {
//        do {
//            let lib = device.makeDefaultLibrary()
//            guard let kernel = lib?.makeFunction(name: "rotateNV12_tileBicubicUV") else { return false }
//            computePipeline = try device.makeComputePipelineState(function: kernel)
//            return true
//        } catch {
//            return false
//        }
//    }
//
//    // MARK: - PixelBuffer wrap
//    private func wrapPixelBuffer(_ pixelBuffer: CVPixelBuffer, originalSampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
//        var timingInfo = CMSampleTimingInfo.invalid
//        CMSampleBufferGetSampleTimingInfo(originalSampleBuffer, at: 0, timingInfoOut: &timingInfo)
//
//        var formatDesc: CMFormatDescription?
//        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDesc) == noErr,
//              let fmt = formatDesc else { return nil }
//
//        var newBuffer: CMSampleBuffer?
//        let ret = CMSampleBufferCreateForImageBuffer(
//            allocator: kCFAllocatorDefault,
//            imageBuffer: pixelBuffer,
//            dataReady: true,
//            makeDataReadyCallback: nil,
//            refcon: nil,
//            formatDescription: fmt,
//            sampleTiming: &timingInfo,
//            sampleBufferOut: &newBuffer
//        )
//        guard ret == noErr else { return nil }
//        return newBuffer
//    }
//
//    // MARK: - Semaphore (自適應)
//    private func waitForAvailableSlot() async {
//        await withCheckedContinuation { cont in
//            DispatchQueue.global().async {
//                while true {
//                    if self.inflightSemaphore.wait(timeout: .now()) == .success { break }
//                }
//                cont.resume()
//            }
//        }
//    }
//
//    private func releaseSlot() {
//        inflightSemaphore.signal()
//    }
//}
//
//
//// MARK: - GPU NV12 Rotator with safe buffer pool
//final class RPVideoRotatorNV12Safe: @unchecked Sendable {
//
//    enum RotationAngle: UInt32, CaseIterable {
//        case angle0 = 0, angle90 = 90, angle180 = 180, angle270 = 270
//    }
//
//    private let device: MTLDevice
//    private let queue: MTLCommandQueue
//    private var computePipeline: MTLComputePipelineState!
//    var textureCache: CVMetalTextureCache?
//
//    private var currentEncoderWidth: Int = 0
//    private var currentEncoderHeight: Int = 0
//
//
//    var mediaMixer:MediaMixer
//
//    var dstWW: Int = 0
//    var dstHH: Int = 0
//    var useBic: Bool = true
//    var debug: Bool = false
//
//    struct Params {
//        var srcWidth: UInt32
//        var srcHeight: UInt32
//        var dstWidth: UInt32
//        var dstHeight: UInt32
//        var angle: UInt32
//        var useBicubic: UInt32
//        var tileWidth: UInt32
//        var tileHeight: UInt32
//    }
//
//    // MARK: - Buffer Pool
//    private struct PooledBuffer {
//        var pixelBuffer: CVPixelBuffer
//        var lastUsed: Date
//    }
//    private var bufferPool: [PooledBuffer] = []
//    private let poolLock = NSLock()
//    private let maxPoolSize: Int
//    private var inflightSemaphore: DispatchSemaphore
//
//    // 自適應策略
//    private var lastFrameTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
//    private var dynamicInflightMax: Int?
//    private let inflightStep: Int = 1
//    private let maxInflightLimit: Int = 12   // 高動態上限
//    private let minInflightLimit: Int = 2    // 保底
//
//    // MARK: - Init
//    init?(
//        dstW: Int = 0,
//        dstH: Int = 0,
//        useBic: Bool = true,
//        debug: Bool = false,
//        maxPoolSize: Int = 5,
//        mediaMixer:MediaMixer
//    ) {
//        guard let dev = MTLCreateSystemDefaultDevice(),
//              let q = dev.makeCommandQueue() else { return nil }
//        self.device = dev
//        self.queue = q
//        self.dstWW = dstW
//        self.dstHH = dstH
//        self.useBic = useBic
//        self.debug = debug
//        self.maxPoolSize = maxPoolSize
//        self.mediaMixer = mediaMixer
//
//        // 自動計算合理 inflight 數量
//        let recommended = ProcessInfo.processInfo.activeProcessorCount
//        let inflightCount = max(2, min(8, recommended))
//        inflightSemaphore = DispatchSemaphore(value: inflightCount)
//
//        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
//        if !buildComputePipeline() { return nil }
//    }
//
//    // MARK: - Cleanup
//    func cleanup() {
//        poolLock.lock()
//        bufferPool.removeAll()
//        poolLock.unlock()
//        if let cache = textureCache {
//            CVMetalTextureCacheFlush(cache, 0)
//        }
//        textureCache = nil
//
//        logTo("cleanup called")
//    }
//
//    // MARK: - Logging
//    private func logTo(_ message: String) {
//        if debug { print("[GPU Rotator] \(message)") }
//    }
//
//    // MARK: - Main rotate API
//    func rotateAsync(sampleBuffer: CMSampleBuffer, angle: RotationAngle) async -> CMSampleBuffer? {
//        await waitForAvailableSlot()
//
//        guard let inBuffer = sampleBuffer.imageBuffer else {
//            releaseSlot()
//            return nil
//        }
//
//        let srcW = CVPixelBufferGetWidth(inBuffer)
//        let srcH = CVPixelBufferGetHeight(inBuffer)
//        var dstW = (angle == .angle90 || angle == .angle270) ? srcH : srcW
//        var dstH = (angle == .angle90 || angle == .angle270) ? srcW : srcH
//        if dstWW > 0 && dstHH > 0 { dstW = dstWW; dstH = dstHH }
//
//
//
//        guard let outPB = getReusableBuffer(width: dstW, height: dstH),
//              let yTexOut = makeTexture(from: outPB, planeIndex: 0),
//              let uvTexOut = makeTexture(from: outPB, planeIndex: 1),
//              let yTexIn = makeTexture(from: inBuffer, planeIndex: 0),
//              let uvTexIn = makeTexture(from: inBuffer, planeIndex: 1),
//              let cmd = queue.makeCommandBuffer() else {
//            releaseSlot()
//            return nil
//        }
//
//        logTo("GPU: \(srcW)x\(srcH) -> \(dstW)x\(dstH)")
//
//        renderPlaneYUV(cmd: cmd, srcY: yTexIn, srcUV: uvTexIn, dstY: yTexOut, dstUV: uvTexOut, angle: angle)
//
//        return await withCheckedContinuation { cont in
//            cmd.addCompletedHandler { _ in
//                self.releaseSlot()
//
//                //old
//                cont.resume(returning: self.wrapPixelBuffer(outPB, originalSampleBuffer: sampleBuffer))
//
//
//
//            }
//            cmd.commit()
//        }
//
//
//    }
//
//    // MARK: - Buffer Pool
//    private func getReusableBuffer(width: Int, height: Int) -> CVPixelBuffer? {
//        poolLock.lock()
//        defer { poolLock.unlock() }
//
//        if let idx = bufferPool.firstIndex(where: { CVPixelBufferGetWidth($0.pixelBuffer) == width && CVPixelBufferGetHeight($0.pixelBuffer) == height }) {
//            bufferPool[idx].lastUsed = Date()
//            return bufferPool[idx].pixelBuffer
//        }
//
//        var newPB: CVPixelBuffer?
//        let attrs: [String: Any] = [
//            kCVPixelBufferMetalCompatibilityKey as String: true,
//            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
//            kCVPixelBufferWidthKey as String: width,
//            kCVPixelBufferHeightKey as String: height
//        ]
//        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs as CFDictionary, &newPB)
//
//        if let pb = newPB {
//            bufferPool.append(PooledBuffer(pixelBuffer: pb, lastUsed: Date()))
//        }
//
//        if bufferPool.count > maxPoolSize {
//            bufferPool.sort { $0.lastUsed < $1.lastUsed }
//            bufferPool.removeFirst(bufferPool.count - maxPoolSize)
//        }
//
//        return newPB
//    }
//
//    // MARK: - Texture
//    private func makeTexture(from pixelBuffer: CVPixelBuffer, planeIndex: Int) -> MTLTexture? {
//        guard let cache = textureCache else { return nil }
//        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
//        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
//        let pixelFormat: MTLPixelFormat = (planeIndex == 0) ? .r8Unorm : .rg8Unorm
//
//        var cvTex: CVMetalTexture?
//        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, pixelFormat, width, height, planeIndex, &cvTex)
//        guard status == kCVReturnSuccess, let tex = cvTex else { return nil }
//        return CVMetalTextureGetTexture(tex)
//    }
//
//    private func renderPlaneYUV(cmd: MTLCommandBuffer, srcY: MTLTexture, srcUV: MTLTexture, dstY: MTLTexture, dstUV: MTLTexture, angle: RotationAngle) {
//        guard let compute = computePipeline, let encoder = cmd.makeComputeCommandEncoder() else { return }
//
//        encoder.setComputePipelineState(compute)
//        encoder.setTexture(srcY, index: 0)
//        encoder.setTexture(srcUV, index: 1)
//        encoder.setTexture(dstY, index: 2)
//        encoder.setTexture(dstUV, index: 3)
//
//        let w = compute.threadExecutionWidth
//        let h = max(1, compute.maxTotalThreadsPerThreadgroup / w)
//
//        var params = Params(
//            srcWidth: UInt32(srcY.width),
//            srcHeight: UInt32(srcY.height),
//            dstWidth: UInt32(dstY.width),
//            dstHeight: UInt32(dstY.height),
//            angle: UInt32(angle.rawValue),
//            useBicubic: useBic ? 1 : 0,
//            tileWidth: UInt32(w),
//            tileHeight: UInt32(h)
//        )
//        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
//        encoder.dispatchThreads(MTLSize(width: dstY.width, height: dstY.height, depth: 1),
//                                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
//        encoder.endEncoding()
//    }
//
//    private func buildComputePipeline() -> Bool {
//        do {
//            let lib = device.makeDefaultLibrary()
//            guard let kernel = lib?.makeFunction(name: "rotateNV12_tileBicubicUV") else { return false }
//            computePipeline = try device.makeComputePipelineState(function: kernel)
//            return true
//        } catch {
//            return false
//        }
//    }
//
//
//    // MARK: - PixelBuffer wrap 棄用方法 改用壓縮後的不送原始
//    private func wrapPixelBuffer(_ pixelBuffer: CVPixelBuffer, originalSampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
//        var timingInfo = CMSampleTimingInfo.invalid
//        CMSampleBufferGetSampleTimingInfo(originalSampleBuffer, at: 0, timingInfoOut: &timingInfo)
//
//        var formatDesc: CMFormatDescription?
//        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDesc) == noErr,
//              let fmt = formatDesc else { return nil }
//
//        var newBuffer: CMSampleBuffer?
//        let ret = CMSampleBufferCreateForImageBuffer(
//            allocator: kCFAllocatorDefault,
//            imageBuffer: pixelBuffer,
//            dataReady: true,
//            makeDataReadyCallback: nil,
//            refcon: nil,
//            formatDescription: fmt,
//            sampleTiming: &timingInfo,
//            sampleBufferOut: &newBuffer
//        )
//        guard ret == noErr else { return nil }
//        return newBuffer
//    }
//
//    // MARK: - Semaphore
//    private func waitForAvailableSlot() async {
//        await withCheckedContinuation { cont in
//            DispatchQueue.global().async {
//                self.inflightSemaphore.wait()
//                cont.resume()
//            }
//        }
//    }
//
//    private func releaseSlot() {
//        inflightSemaphore.signal()
//    }
//}
//
//
////MARK: GPU old
//final class RPVideoRotatorNV12Queue: @unchecked Sendable {
//
//    enum RotationAngle: UInt32, CaseIterable {
//        case angle0 = 0, angle90 = 90, angle180 = 180, angle270 = 270
//    }
//
//    private let device: MTLDevice
//    private let queue: MTLCommandQueue
//    private var computePipeline: MTLComputePipelineState!
//    var textureCache: CVMetalTextureCache?
//
//    var dstWW: Int = 0
//    var dstHH: Int = 0
//    var useBic: Bool = true
//    var debug: Bool = false
//
//    struct Params {
//        var srcWidth: UInt32
//        var srcHeight: UInt32
//        var dstWidth: UInt32
//        var dstHeight: UInt32
//        var angle: UInt32
//        var useBicubic: UInt32
//
//        var tileWidth: UInt32
//        var tileHeight: UInt32
//
//    }
//
//    // MARK: - buffer pool with max size
//    private struct PooledBuffer {
//        var pixelBuffer: CVPixelBuffer
//        var lastUsed: Date
//    }
//    private var bufferPool: [PooledBuffer] = []
//    private let poolLock = NSLock()
//    private let maxPoolSize: Int
//
//    private var inflightSemaphore: DispatchSemaphore
//
//
//    // async 版本的 wait
//    private func waitForAvailableSlot() async {
//        await withCheckedContinuation { cont in
//            DispatchQueue.global().async {
//                self.inflightSemaphore.wait()
//                cont.resume()
//            }
//        }
//    }
//
//    // signal 保持同步即可
//    private func releaseSlot() {
//        inflightSemaphore.signal()
//    }
//
//
//    init?(dstW: Int = 0, dstH: Int = 0, useBic: Bool = true, debug: Bool = false, maxPoolSize: Int = 5) {
//        guard let dev = MTLCreateSystemDefaultDevice(),
//              let q = dev.makeCommandQueue() else { return nil }
//
//        self.device = dev
//        self.queue = q
//        self.dstWW = dstW
//        self.dstHH = dstH
//        self.useBic = useBic
//        self.debug = debug
//        self.maxPoolSize = maxPoolSize
//
//        // 自動計算合理的 inflight 數量
//        let recommended = ProcessInfo.processInfo.activeProcessorCount
//        let inflightCount = max(2, min(8, recommended))  // 最少 2 幀，最多 8 幀
//        inflightSemaphore = DispatchSemaphore(value: inflightCount)
//
//        logTo("Auto Process Count:\(inflightCount)")
//
//        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
//        if !buildComputePipeline() { return nil }
//    }
//
//    func cleanup() {
//
//        poolLock.lock()
//        bufferPool.removeAll()  // 釋放所有 pixelBuffer
//        poolLock.unlock()
//
//        if let cache = textureCache {
//            CVMetalTextureCacheFlush(cache, 0)
//        }
//        textureCache = nil
//
//        logTo("[GPU Rotator] cleanup called")
//    }
//
//    func logTo(_ message:String) {
//        if debug {
//            sendlog(message: message)
//        }
//    }
//
//
//    func rotateAsync(sampleBuffer: CMSampleBuffer, angle: RotationAngle) async -> CMSampleBuffer? {
//
//        await waitForAvailableSlot()
//
//
//
//        guard let inBuffer = sampleBuffer.imageBuffer else { return nil }
//        let srcW = CVPixelBufferGetWidth(inBuffer)
//        let srcH = CVPixelBufferGetHeight(inBuffer)
//        var dstW = (angle == .angle90 || angle == .angle270) ? srcH : srcW
//        var dstH = (angle == .angle90 || angle == .angle270) ? srcW : srcH
//        if dstWW > 0 && dstHH > 0 { dstW = dstWW; dstH = dstHH }
//
//        // 嘗試重用 buffer
//        guard let outPB = getReusableBuffer(width: dstW, height: dstH),
//              let yTexOut = makeTexture(from: outPB, planeIndex: 0),
//              let uvTexOut = makeTexture(from: outPB, planeIndex: 1),
//              let yTexIn = makeTexture(from: inBuffer, planeIndex: 0),
//              let uvTexIn = makeTexture(from: inBuffer, planeIndex: 1),
//              let cmd = queue.makeCommandBuffer() else { return nil }
//
//        logTo("GPU: \(srcW) x \(srcH) -> \(dstW) x \(dstH)")
//
//        renderPlaneYUV(cmd: cmd, srcY: yTexIn, srcUV: uvTexIn, dstY: yTexOut, dstUV: uvTexOut, angle: angle)
//
//
//
//        return await withCheckedContinuation { cont in
//            cmd.addCompletedHandler { _ in
//
//
//                self.releaseSlot() // GPU 完成 → 允許下一幀進入
//                self.logTo("GPU處理完成 Frame")
//
//                cont.resume(returning: self.wrapPixelBuffer(outPB, originalSampleBuffer: sampleBuffer))
//            }
//            cmd.commit()
//        }
//    }
//
//    // MARK: - buffer pool with reuse & auto trim
//    private func getReusableBuffer(width: Int, height: Int) -> CVPixelBuffer? {
//        poolLock.lock()
//        defer { poolLock.unlock() }
//
//        // 嘗試找到合適 buffer
//        if let idx = bufferPool.firstIndex(where: { CVPixelBufferGetWidth($0.pixelBuffer) == width && CVPixelBufferGetHeight($0.pixelBuffer) == height }) {
//            bufferPool[idx].lastUsed = Date()
//            return bufferPool[idx].pixelBuffer
//        }
//
//        // 建立新 buffer
//        var newPB: CVPixelBuffer?
//        let attrs: [String: Any] = [
//            kCVPixelBufferMetalCompatibilityKey as String: true,
//            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
//            kCVPixelBufferWidthKey as String: width,
//            kCVPixelBufferHeightKey as String: height
//        ]
//        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs as CFDictionary, &newPB)
//
//        if let pb = newPB {
//            bufferPool.append(PooledBuffer(pixelBuffer: pb, lastUsed: Date()))
//        }
//
//        // 自動清理最舊 buffer
//        if bufferPool.count > maxPoolSize {
//            bufferPool.sort { $0.lastUsed < $1.lastUsed }
//            bufferPool.removeFirst(bufferPool.count - maxPoolSize)
//        }
//
//        return newPB
//    }
//
//    // MARK: - Texture Utilities
//    private func makeTexture(from pixelBuffer: CVPixelBuffer, planeIndex: Int) -> MTLTexture? {
//        guard let cache = textureCache else { return nil }
//        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
//        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
//        let pixelFormat: MTLPixelFormat = (planeIndex == 0) ? .r8Unorm : .rg8Unorm
//
//        var cvTex: CVMetalTexture?
//        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, pixelFormat, width, height, planeIndex, &cvTex)
//        guard status == kCVReturnSuccess, let tex = cvTex else { return nil }
//        return CVMetalTextureGetTexture(tex)
//    }
//
//    private func renderPlaneYUV(cmd: MTLCommandBuffer, srcY: MTLTexture, srcUV: MTLTexture, dstY: MTLTexture, dstUV: MTLTexture, angle: RotationAngle) {
//        guard let compute = computePipeline, let encoder = cmd.makeComputeCommandEncoder() else { return }
//
//        encoder.setComputePipelineState(compute)
//        encoder.setTexture(srcY, index: 0)
//        encoder.setTexture(srcUV, index: 1)
//        encoder.setTexture(dstY, index: 2)
//        encoder.setTexture(dstUV, index: 3)
//
//
//        let w = compute.threadExecutionWidth
//        let h = max(1, compute.maxTotalThreadsPerThreadgroup / w)
//
//        logTo("GPU Thread:\(w) \(h)")
//
//        var params = Params(srcWidth: UInt32(srcY.width),
//                            srcHeight: UInt32(srcY.height),
//                            dstWidth: UInt32(dstY.width),
//                            dstHeight: UInt32(dstY.height),
//                            angle: UInt32(angle.rawValue),
//                            useBicubic: useBic ? 1 : 0,
//                            tileWidth: UInt32(w),
//                            tileHeight: UInt32(h)
//        )
//
//        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
//
//
//        encoder.dispatchThreads(MTLSize(width: dstY.width, height: dstY.height, depth: 1),
//                                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
//
//
//        encoder.endEncoding()
//    }
//
//    private func buildComputePipeline() -> Bool {
//        do {
//            let lib = device.makeDefaultLibrary()
//            guard let kernel = lib?.makeFunction(name: "rotateNV12_tileBicubicUV") else { return false }
//            computePipeline = try device.makeComputePipelineState(function: kernel)
//            return true
//        } catch {
//            return false
//        }
//    }
//
//    // MARK: 棄用方法 改用壓縮後的不送原始
//    private func wrapPixelBuffer(_ pixelBuffer: CVPixelBuffer, originalSampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
//        var timingInfo = CMSampleTimingInfo.invalid
//        CMSampleBufferGetSampleTimingInfo(originalSampleBuffer, at: 0, timingInfoOut: &timingInfo)
//
//        var formatDesc: CMFormatDescription?
//        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDesc) == noErr,
//              let fmt = formatDesc else { return nil }
//
//        var newBuffer: CMSampleBuffer?
//        let ret = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt, sampleTiming: &timingInfo, sampleBufferOut: &newBuffer)
//        guard ret == noErr else { return nil }
//        return newBuffer
//    }
//}
//
//
//
//
//
//// MARK: - RPVideoRotatorNV12BatchQueue
//final class RPVideoRotatorNV12BatchQueue: @unchecked Sendable {
//
//    enum RotationAngle: UInt32, CaseIterable {
//        case angle0 = 0, angle90 = 90, angle180 = 180, angle270 = 270
//    }
//
//    // MARK: - GPU / Metal
//    private let device: MTLDevice
//    private let queue: MTLCommandQueue
//    private var computePipeline: MTLComputePipelineState!
//    var textureCache: CVMetalTextureCache?
//
//    // MARK: - Settings
//    var mediaMixer: MediaMixer
//    var dstWW: Int = 0
//    var dstHH: Int = 0
//    var useBic: Bool = true
//    var debug: Bool = false
//
//    struct Params {
//        var srcWidth: UInt32
//        var srcHeight: UInt32
//        var dstWidth: UInt32
//        var dstHeight: UInt32
//        var angle: UInt32
//        var useBicubic: UInt32
//        var tileWidth: UInt32
//        var tileHeight: UInt32
//    }
//
//    // MARK: - PixelBuffer Pool
//    private struct PooledBuffer {
//        var pixelBuffer: CVPixelBuffer
//        var lastUsed: Date
//    }
//    private var bufferPool: [PooledBuffer] = []
//    private let poolLock = NSLock()
//    private let maxPoolSize: Int
//
//    // MARK: - GPU Semaphore & Concurrency
//    private var gpuSemaphore: DispatchSemaphore
//    private var maxConcurrentFrames: Int
//    private var lastFrameTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
//
//    // MARK: - Frame Queue
//    private var frameQueue: [(CMSampleBuffer, RotationAngle, CheckedContinuation<CMSampleBuffer?, Never>)] = []
//    private let frameQueueLock = NSLock()
//
//    // MARK: - Logging
//    private func logTo(_ message: String) {
//        if debug { sendlog(message:"[GPU Rotator] \(message)") }
//    }
//    // MARK: - Cleanup
//    func cleanup() {
//        poolLock.lock()
//        bufferPool.removeAll()
//        poolLock.unlock()
//        if let cache = textureCache {
//            CVMetalTextureCacheFlush(cache, 0)
//        }
//        textureCache = nil
//        logTo("cleanup called")
//    }
//
//    // MARK: - Init
//    init?(dstW: Int = 0, dstH: Int = 0, useBic: Bool = true, debug: Bool = false,
//          maxPoolSize: Int = 5, mediaMixer: MediaMixer) {
//
//        guard let dev = MTLCreateSystemDefaultDevice(),
//              let q = dev.makeCommandQueue() else { return nil }
//        self.device = dev
//        self.queue = q
//        self.dstWW = dstW
//        self.dstHH = dstH
//        self.useBic = useBic
//        self.debug = debug
//        self.maxPoolSize = maxPoolSize
//        self.mediaMixer = mediaMixer
//
//        // GPU 并发
//        let recommended = ProcessInfo.processInfo.activeProcessorCount
//        self.maxConcurrentFrames = max(1, min(8, recommended))
//        self.gpuSemaphore = DispatchSemaphore(value: self.maxConcurrentFrames)
//
//        // Metal texture cache
//        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
//        guard buildComputePipeline() else { return nil }
//
//        // Start queue processing
//        startQueueProcessing()
//    }
//
//    // MARK: - Enqueue frame
//    func rotateAsync(sampleBuffer: CMSampleBuffer, angle: RotationAngle) async -> CMSampleBuffer? {
//        await withCheckedContinuation { cont in
//            frameQueueLock.lock()
//            frameQueue.append((sampleBuffer, angle, cont))
//            frameQueueLock.unlock()
//            // queue processing is always running
//        }
//    }
//
//    // MARK: - Queue Processor
//    private func startQueueProcessing() {
//        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
//            guard let self = self else { return }
//
//            while true {
//                self.frameQueueLock.lock()
//                guard !self.frameQueue.isEmpty else {
//                    self.frameQueueLock.unlock()
//                    usleep(500) // 0.5ms 空转等待
//                    continue
//                }
//                let (sampleBuffer, angle, cont) = self.frameQueue.removeFirst()
//                self.frameQueueLock.unlock()
//
//                // 等待 GPU slot
//                self.gpuSemaphore.wait()
//
//                let startTime = CFAbsoluteTimeGetCurrent()
//
//                guard let inBuffer = sampleBuffer.imageBuffer else {
//                    cont.resume(returning: nil)
//                    self.gpuSemaphore.signal()
//                    continue
//                }
//
//                let srcW = CVPixelBufferGetWidth(inBuffer)
//                let srcH = CVPixelBufferGetHeight(inBuffer)
//                var dstW = (angle == .angle90 || angle == .angle270) ? srcH : srcW
//                var dstH = (angle == .angle90 || angle == .angle270) ? srcW : srcH
//                if self.dstWW > 0 && self.dstHH > 0 { dstW = self.dstWW; dstH = self.dstHH }
//
//
//                logTo("\(srcW)x\(srcH) -> \(dstW)x\(dstH)")
//
//                guard let outPB = self.getReusableBuffer(width: dstW, height: dstH),
//                      let yTexOut = self.makeTexture(from: outPB, planeIndex: 0),
//                      let uvTexOut = self.makeTexture(from: outPB, planeIndex: 1),
//                      let yTexIn = self.makeTexture(from: inBuffer, planeIndex: 0),
//                      let uvTexIn = self.makeTexture(from: inBuffer, planeIndex: 1),
//                      let cmd = self.queue.makeCommandBuffer() else {
//                    cont.resume(returning: nil)
//                    self.gpuSemaphore.signal()
//                    continue
//                }
//
//                // 动态 tile
//                let now = CFAbsoluteTimeGetCurrent()
//                let delta = now - self.lastFrameTime
//                self.lastFrameTime = now
//                let targetDelta = 1.0 / 60.0
//                let dynamicScale = max(1, min(3, Int(targetDelta / delta)))
//
//                self.renderPlaneYUV(cmd: cmd,
//                                    srcY: yTexIn, srcUV: uvTexIn,
//                                    dstY: yTexOut, dstUV: uvTexOut,
//                                    angle: angle,
//                                    dynamicScale: dynamicScale)
//
//                cmd.addCompletedHandler { _ in
//                    cont.resume(returning: self.wrapPixelBuffer(outPB, originalSampleBuffer: sampleBuffer))
//                    self.updateGPUConcurrency(lastFrameDuration: CFAbsoluteTimeGetCurrent() - startTime)
//                    self.gpuSemaphore.signal()
//                    self.logTo("Frame Finish")
//
//                }
//                cmd.commit()
//            }
//        }
//    }
//
//    // MARK: - Dynamic GPU concurrency
//    private func updateGPUConcurrency(lastFrameDuration: CFAbsoluteTime) {
//        let targetFPS: CFAbsoluteTime = 1.0 / 60.0
//        let scale = max(1, min(8, Int(targetFPS / lastFrameDuration * Double(maxConcurrentFrames))))
//
//        let delta = scale - maxConcurrentFrames
//        if delta > 0 {
//            for _ in 0..<delta { gpuSemaphore.signal() }
//        } else if delta < 0 {
//            for _ in 0..<(-delta) { _ = gpuSemaphore.wait(timeout: .now()) }
//        }
//        maxConcurrentFrames = scale
//    }
//
//    // MARK: - Render YUV
//    private func renderPlaneYUV(cmd: MTLCommandBuffer,
//                                srcY: MTLTexture, srcUV: MTLTexture,
//                                dstY: MTLTexture, dstUV: MTLTexture,
//                                angle: RotationAngle,
//                                dynamicScale: Int = 1) {
//
//        guard let compute = computePipeline, let encoder = cmd.makeComputeCommandEncoder() else { return }
//
//        encoder.setComputePipelineState(compute)
//        encoder.setTexture(srcY, index: 0)
//        encoder.setTexture(srcUV, index: 1)
//        encoder.setTexture(dstY, index: 2)
//        encoder.setTexture(dstUV, index: 3)
//
//        let baseW = min(compute.threadExecutionWidth, 32)
//        let baseH = max(1, compute.maxTotalThreadsPerThreadgroup / baseW)
//        let maxThreads = compute.maxTotalThreadsPerThreadgroup
//        let tgWidth = min(baseW * dynamicScale, maxThreads)
//        let tgHeight = min(baseH * dynamicScale, maxThreads / tgWidth)
//
//        var params = Params(
//            srcWidth: UInt32(srcY.width),
//            srcHeight: UInt32(srcY.height),
//            dstWidth: UInt32(dstY.width),
//            dstHeight: UInt32(dstY.height),
//            angle: UInt32(angle.rawValue),
//            useBicubic: useBic ? 1 : 0,
//            tileWidth: UInt32(tgWidth),
//            tileHeight: UInt32(tgHeight)
//        )
//
//        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
//        encoder.dispatchThreads(MTLSize(width: dstY.width, height: dstY.height, depth: 1),
//                                threadsPerThreadgroup: MTLSize(width: tgWidth, height: tgHeight, depth: 1))
//        encoder.endEncoding()
//    }
//
//
//
//    // MARK: - PixelBuffer Pool
//    private func getReusableBuffer(width: Int, height: Int) -> CVPixelBuffer? {
//        poolLock.lock()
//        defer { poolLock.unlock() }
//
//        if let idx = bufferPool.firstIndex(where: { CVPixelBufferGetWidth($0.pixelBuffer) == width &&
//                                                    CVPixelBufferGetHeight($0.pixelBuffer) == height }) {
//            bufferPool[idx].lastUsed = Date()
//            return bufferPool[idx].pixelBuffer
//        }
//
//        var newPB: CVPixelBuffer?
//        let attrs: [String: Any] = [
//            kCVPixelBufferMetalCompatibilityKey as String: true,
//            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
//            kCVPixelBufferWidthKey as String: width,
//            kCVPixelBufferHeightKey as String: height
//        ]
//        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs as CFDictionary, &newPB)
//
//        if let pb = newPB { bufferPool.append(PooledBuffer(pixelBuffer: pb, lastUsed: Date())) }
//
//        if bufferPool.count > maxPoolSize {
//            bufferPool.sort { $0.lastUsed < $1.lastUsed }
//            bufferPool.removeFirst(bufferPool.count - maxPoolSize)
//        }
//
//        return newPB
//    }
//
//    private func makeTexture(from pixelBuffer: CVPixelBuffer, planeIndex: Int) -> MTLTexture? {
//        guard let cache = textureCache else { return nil }
//        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
//        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
//        let pixelFormat: MTLPixelFormat = (planeIndex == 0) ? .r8Unorm : .rg8Unorm
//
//        var cvTex: CVMetalTexture?
//        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil,
//                                                               pixelFormat, width, height, planeIndex, &cvTex)
//        guard status == kCVReturnSuccess else { return nil }
//        return CVMetalTextureGetTexture(cvTex!)
//    }
//
//    private func buildComputePipeline() -> Bool {
//        do {
//            let lib = device.makeDefaultLibrary()
//            guard let kernel = lib?.makeFunction(name: "rotateNV12_tileBicubicUV") else { return false }
//            computePipeline = try device.makeComputePipelineState(function: kernel)
//            return true
//        } catch {
//            return false
//        }
//    }
//
//    // MARK: - Wrap PixelBuffer
//    private func wrapPixelBuffer(_ pixelBuffer: CVPixelBuffer, originalSampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
//        var timingInfo = CMSampleTimingInfo.invalid
//        CMSampleBufferGetSampleTimingInfo(originalSampleBuffer, at: 0, timingInfoOut: &timingInfo)
//
//        var formatDesc: CMFormatDescription?
//        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
//                                                           imageBuffer: pixelBuffer,
//                                                           formatDescriptionOut: &formatDesc) == noErr,
//              let fmt = formatDesc else { return nil }
//
//        var newBuffer: CMSampleBuffer?
//        guard CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
//                                                 imageBuffer: pixelBuffer,
//                                                 dataReady: true,
//                                                 makeDataReadyCallback: nil,
//                                                 refcon: nil,
//                                                 formatDescription: fmt,
//                                                 sampleTiming: &timingInfo,
//                                                 sampleBufferOut: &newBuffer) == noErr else { return nil }
//        return newBuffer
//    }
//
//}
//
//
//// MARK: Batch
//final class RPVideoRotatorNV12BatchOptimizedold: @unchecked Sendable {
//
//    enum RotationAngle: UInt32, CaseIterable {
//        case angle0 = 0, angle90 = 90, angle180 = 180, angle270 = 270
//    }
//
//    private let device: MTLDevice
//    private let queue: MTLCommandQueue
//    private var computePipeline: MTLComputePipelineState!
//    var textureCache: CVMetalTextureCache?
//
//    var mediaMixer: MediaMixer
//    var dstWW: Int = 0
//    var dstHH: Int = 0
//    var useBic: Bool = true
//    var debug: Bool = false
//
//    struct Params {
//        var srcWidth: UInt32
//        var srcHeight: UInt32
//        var dstWidth: UInt32
//        var dstHeight: UInt32
//        var angle: UInt32
//        var useBicubic: UInt32
//        var tileWidth: UInt32
//        var tileHeight: UInt32
//    }
//
//    // MARK: - Buffer Pool
//    private struct PooledBuffer {
//        var pixelBuffer: CVPixelBuffer
//        var lastUsed: Date
//    }
//    private var bufferPool: [PooledBuffer] = []
//    private let poolLock = NSLock()
//    private let maxPoolSize: Int
//    private var inflightSemaphore: DispatchSemaphore
//
//    var GPUCount = 1
//
//    // MARK: - Frame Stream
//    typealias FrameItem = (CMSampleBuffer, RotationAngle, CheckedContinuation<CMSampleBuffer?, Never>)
//
//    private final class FrameStreamHolder {
//        private var continuation: AsyncStream<FrameItem>.Continuation?
//
//        lazy var stream: AsyncStream<FrameItem> = AsyncStream { [weak self] cont in
//            self?.continuation = cont
//        }
//
//        func yield(_ value: FrameItem) {
//            continuation?.yield(value)
//        }
//    }
//
//    private let frameStreamHolder = FrameStreamHolder()
//
//    // MARK: - Adaptive tile
//    private var lastFrameTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
//
//    // MARK: - Init
//    init?(dstW: Int = 0, dstH: Int = 0, useBic: Bool = true, debug: Bool = false,
//          maxPoolSize: Int = 5, mediaMixer: MediaMixer) {
//
//        guard let dev = MTLCreateSystemDefaultDevice(),
//              let q = dev.makeCommandQueue() else { return nil }
//        self.device = dev
//        self.queue = q
//        self.dstWW = dstW
//        self.dstHH = dstH
//        self.useBic = useBic
//        self.debug = debug
//        self.maxPoolSize = maxPoolSize
//        self.mediaMixer = mediaMixer
//
//        let recommended = ProcessInfo.processInfo.activeProcessorCount
//        inflightSemaphore = DispatchSemaphore(value: max(2, min(8, recommended)))
//
//        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
//        if !buildComputePipeline() { return nil }
//
//        startBatchPipeline()
//    }
//
//    // MARK: - Cleanup
//    func cleanup() {
//        poolLock.lock()
//        bufferPool.removeAll()
//        poolLock.unlock()
//        if let cache = textureCache {
//            CVMetalTextureCacheFlush(cache, 0)
//        }
//        textureCache = nil
//        logTo("cleanup called")
//    }
//
//    // MARK: - Logging
//    private func logTo(_ message: String) {
//        if debug { sendlog(message:"[GPU Rotator] \(message)") }
//    }
//
//    // MARK: - Async rotate
//    func rotateAsync(sampleBuffer: CMSampleBuffer, angle: RotationAngle) async -> CMSampleBuffer? {
//        await withCheckedContinuation { cont in
//            frameStreamHolder.yield((sampleBuffer, angle, cont))
//        }
//    }
//
//    // MARK: - Batch Pipeline
//    private func startBatchPipeline() {
//        Task.detached { [weak self] in
//            guard let self = self else { return }
//            for await batchItem in self.frameStreamHolder.stream {
//                await self.waitForAvailableSlot()
//                Task {
//                    defer { self.releaseSlot() }
//                    let (sampleBuffer, angle, cont) = batchItem
//
//                    guard let inBuffer = sampleBuffer.imageBuffer else {
//                        cont.resume(returning: nil)
//                        return
//                    }
//
//                    let srcW = CVPixelBufferGetWidth(inBuffer)
//                    let srcH = CVPixelBufferGetHeight(inBuffer)
//                    var dstW = (angle == .angle90 || angle == .angle270) ? srcH : srcW
//                    var dstH = (angle == .angle90 || angle == .angle270) ? srcW : srcH
//                    if self.dstWW > 0 && self.dstHH > 0 { dstW = self.dstWW; dstH = self.dstHH }
//
//                    guard let outPB = self.getReusableBuffer(width: dstW, height: dstH),
//                          let yTexOut = self.makeTexture(from: outPB, planeIndex: 0),
//                          let uvTexOut = self.makeTexture(from: outPB, planeIndex: 1),
//                          let yTexIn = self.makeTexture(from: inBuffer, planeIndex: 0),
//                          let uvTexIn = self.makeTexture(from: inBuffer, planeIndex: 1),
//                          let cmd = self.queue.makeCommandBuffer() else {
//                        cont.resume(returning: nil)
//                        return
//                    }
//
//                    // 動態 tile
//                    let now = CFAbsoluteTimeGetCurrent()
//                    let delta = now - self.lastFrameTime
//                    self.lastFrameTime = now
//                    let targetDelta = 1.0 / 60.0
//                    let dynamicScale = max(1, min(3, Int(targetDelta / delta)))
//
//                    self.logTo("GPU: \(srcW)x\(srcH) -> \(dstW)x\(dstH)")
//
//                    self.renderPlaneYUV(cmd: cmd,
//                                        srcY: yTexIn, srcUV: uvTexIn,
//                                        dstY: yTexOut, dstUV: uvTexOut,
//                                        angle: angle,
//                                        dynamicScale: dynamicScale)
//
//                    cmd.addCompletedHandler { _ in
//                        self.logTo("GPU FrameDown")
//                        cont.resume(returning: self.wrapPixelBuffer(outPB, originalSampleBuffer: sampleBuffer))
//                    }
//                    cmd.commit()
//                }
//            }
//        }
//    }
//
//    // MARK: - Render Plane
//    private func renderPlaneYUV(cmd: MTLCommandBuffer,
//                                srcY: MTLTexture, srcUV: MTLTexture,
//                                dstY: MTLTexture, dstUV: MTLTexture,
//                                angle: RotationAngle,
//                                dynamicScale: Int = 1) {
//
//        guard let compute = computePipeline, let encoder = cmd.makeComputeCommandEncoder() else { return }
//
//        encoder.setComputePipelineState(compute)
//        encoder.setTexture(srcY, index: 0)
//        encoder.setTexture(srcUV, index: 1)
//        encoder.setTexture(dstY, index: 2)
//        encoder.setTexture(dstUV, index: 3)
//
//        let baseW = min(compute.threadExecutionWidth, 32)
//        let baseH = max(1, compute.maxTotalThreadsPerThreadgroup / baseW)
//        let maxThreads = compute.maxTotalThreadsPerThreadgroup
//        let tgWidth = min(baseW * dynamicScale, maxThreads)
//        let tgHeight = min(baseH * dynamicScale, maxThreads / tgWidth)
//
//        var params = Params(
//            srcWidth: UInt32(srcY.width),
//            srcHeight: UInt32(srcY.height),
//            dstWidth: UInt32(dstY.width),
//            dstHeight: UInt32(dstY.height),
//            angle: UInt32(angle.rawValue),
//            useBicubic: useBic ? 1 : 0,
//            tileWidth: UInt32(tgWidth),
//            tileHeight: UInt32(tgHeight)
//        )
//
//        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
//        encoder.dispatchThreads(MTLSize(width: dstY.width, height: dstY.height, depth: 1),
//                                threadsPerThreadgroup: MTLSize(width: tgWidth, height: tgHeight, depth: 1))
//        encoder.endEncoding()
//    }
//
//    // MARK: - PixelBuffer Pool
//    private func getReusableBuffer(width: Int, height: Int) -> CVPixelBuffer? {
//        poolLock.lock()
//        defer { poolLock.unlock() }
//
//        if let idx = bufferPool.firstIndex(where: { CVPixelBufferGetWidth($0.pixelBuffer) == width &&
//                                                    CVPixelBufferGetHeight($0.pixelBuffer) == height }) {
//            bufferPool[idx].lastUsed = Date()
//            return bufferPool[idx].pixelBuffer
//        }
//
//        // create new buffer if not found
//        var newPB: CVPixelBuffer?
//        let attrs: [String: Any] = [
//            kCVPixelBufferMetalCompatibilityKey as String: true,
//            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
//            kCVPixelBufferWidthKey as String: width,
//            kCVPixelBufferHeightKey as String: height
//        ]
//        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs as CFDictionary, &newPB)
//
//        if let pb = newPB { bufferPool.append(PooledBuffer(pixelBuffer: pb, lastUsed: Date())) }
//
//        if bufferPool.count > maxPoolSize {
//            bufferPool.sort { $0.lastUsed < $1.lastUsed }
//            bufferPool.removeFirst(bufferPool.count - maxPoolSize)
//        }
//
//        return newPB
//    }
//
//    private func makeTexture(from pixelBuffer: CVPixelBuffer, planeIndex: Int) -> MTLTexture? {
//        guard let cache = textureCache else { return nil }
//        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
//        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
//        let pixelFormat: MTLPixelFormat = (planeIndex == 0) ? .r8Unorm : .rg8Unorm
//
//        var cvTex: CVMetalTexture?
//        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil,
//                                                               pixelFormat, width, height, planeIndex, &cvTex)
//        guard status == kCVReturnSuccess, let tex = cvTex else { return nil }
//        return CVMetalTextureGetTexture(tex)
//    }
//
//    private func buildComputePipeline() -> Bool {
//        do {
//            let lib = device.makeDefaultLibrary()
//            guard let kernel = lib?.makeFunction(name: "rotateNV12_tileBicubicUV") else { return false }
//            computePipeline = try device.makeComputePipelineState(function: kernel)
//            return true
//        } catch {
//            return false
//        }
//    }
//
//    // MARK: - Wrap PixelBuffer
//    private func wrapPixelBuffer(_ pixelBuffer: CVPixelBuffer, originalSampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
//        var timingInfo = CMSampleTimingInfo.invalid
//        CMSampleBufferGetSampleTimingInfo(originalSampleBuffer, at: 0, timingInfoOut: &timingInfo)
//
//        var formatDesc: CMFormatDescription?
//        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
//                                                           imageBuffer: pixelBuffer,
//                                                           formatDescriptionOut: &formatDesc) == noErr,
//              let fmt = formatDesc else { return nil }
//
//        var newBuffer: CMSampleBuffer?
//        guard CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
//                                                 imageBuffer: pixelBuffer,
//                                                 dataReady: true,
//                                                 makeDataReadyCallback: nil,
//                                                 refcon: nil,
//                                                 formatDescription: fmt,
//                                                 sampleTiming: &timingInfo,
//                                                 sampleBufferOut: &newBuffer) == noErr else { return nil }
//        return newBuffer
//    }
//
//    // MARK: - Semaphore
//    private func releaseSlot() { inflightSemaphore.signal() }
//    private func waitForAvailableSlot() async {
//        await withCheckedContinuation { cont in
//            DispatchQueue.global(qos: .userInitiated).async {
//                self.inflightSemaphore.wait()
//                cont.resume()
//            }
//        }
//    }
//}
//
