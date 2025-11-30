//
//  CPURotator.swift
//  liveAPP
//
//  Created by user on 2025/11/24.
//

// MARK: CPU
import Foundation
import AVFoundation
import CoreVideo
import VideoToolbox

import RTMPHaishinKit

//MARK: VTool

final class VTEncoder {
    private var session: VTCompressionSession?

    var onEncoded: ((CMSampleBuffer) -> Void)?

    init?(width: Int, height: Int) {
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { _, _, status, infoFlags, sampleBuffer in
                guard status == noErr, let sb = sampleBuffer else { return }
                // TODO: 你在這裡送 RTMP / SRT / WebRTC / FileWriter

                sendlog(message:"Encoded frame: \(sb)")

            },
            refcon: nil,
            compressionSessionOut: &session
        )

        if status != noErr { return nil }

        VTSessionSetProperty(session!, key:kVTCompressionPropertyKey_RealTime,
                             value:kCFBooleanTrue
        )
        VTCompressionSessionPrepareToEncodeFrames(session!)
    }

    // MARK: SampleBuffer
    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = sampleBuffer.imageBuffer else { return }

        var timing = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing)

        VTCompressionSessionEncodeFrame(
            session!,
            imageBuffer: imageBuffer,
            presentationTimeStamp: timing.presentationTimeStamp,
            duration: timing.duration,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    // MARK: CVPixel
    func encode(pixelBuffer: CVPixelBuffer, pts: CMTime) {
            VTCompressionSessionEncodeFrame(
                session!,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: pts,
                duration: .invalid,
                frameProperties: nil,
                sourceFrameRefcon: nil,
                infoFlagsOut: nil
            )
        }


    func finish() {
        VTCompressionSessionCompleteFrames(session!, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session!)
        session = nil
    }
}

//MARK: CPU, sourceFrameRefcon:
final class RPVideoRotatorCPU_NV12: @unchecked Sendable {

    enum RotationAngle: UInt32, CaseIterable {
        case angle0 = 0, angle90 = 90, angle180 = 180, angle270 = 270
    }

    // MARK: - pool
    private struct PooledBuffer {
        var pixelBuffer: CVPixelBuffer
        var lastUsed: Date
    }
    private var bufferPool: [PooledBuffer] = []
    private let poolLock = NSLock()
    private let maxPoolSize: Int

    private var vtEncoder: VTEncoder?

    private var currentEncoderWidth: Int = 0
    private var currentEncoderHeight: Int = 0

    private var inflightSemaphore: DispatchSemaphore

    var dstWW: Int = 0
    var dstHH: Int = 0
    var debug: Bool = false

    init?(dstW: Int = 0, dstH: Int = 0, debug: Bool = false, maxPoolSize: Int = 5) {
        self.dstWW = dstW
        self.dstHH = dstH
        self.debug = debug
        self.maxPoolSize = maxPoolSize

        let recommended = ProcessInfo.processInfo.activeProcessorCount
        let inflightCount = max(2, min(8, recommended))
        inflightSemaphore = DispatchSemaphore(value: inflightCount)


    }

    func logTo(_ message: String) {
        if debug {
            print("[RotCPU] \(message)")
        }
    }

    func cleanup() {
        poolLock.lock()
        bufferPool.removeAll()
        
        poolLock.unlock()

        vtEncoder?.finish()
        vtEncoder = nil

        logTo("cleanup")
    }

    // async wait
    private func waitForAvailableSlot() async {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                self.inflightSemaphore.wait()
                cont.resume()
            }
        }
    }
    private func releaseSlot() {
        inflightSemaphore.signal()
    }

    // MARK: - main API (async)
    func rotateCPU(sampleBuffer: CMSampleBuffer,
                   angle: RotationAngle,
                   completion: @escaping (CMSampleBuffer?) -> Void) {

        Task {
            await waitForAvailableSlot()
        }

        guard let inBuffer = sampleBuffer.imageBuffer else {
            releaseSlot()
            completion(nil)
            return
        }

        CVPixelBufferLockBaseAddress(inBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(inBuffer, .readOnly) }

        let srcW = CVPixelBufferGetWidth(inBuffer)
        let srcH = CVPixelBufferGetHeight(inBuffer)




        var dstW = (angle == .angle90 || angle == .angle270) ? srcH : srcW
        var dstH = (angle == .angle90 || angle == .angle270) ? srcW : srcH


        if dstWW > 0 && dstHH > 0 { dstW = dstWW; dstH = dstHH }

        // 壓縮視頻處理
        if vtEncoder == nil || currentEncoderWidth != dstW || currentEncoderHeight != dstH {
            vtEncoder = VTEncoder(width: dstW, height: dstH)
            currentEncoderWidth = dstW
            currentEncoderHeight = dstH
            logTo("VTEncoder initialized: \(dstW)x\(dstH)")
        }

        guard let outPB = getReusableBuffer(width: dstW, height: dstH) else {
            releaseSlot()
            completion(nil)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            defer {
                self.releaseSlot() // 無論成功或失敗都釋放 slot
            }

            let ok = self.rotateNV12CPU(inPixelBuffer: inBuffer, outPixelBuffer: outPB, angle: angle)

            guard ok else {
                self.logTo("CPU rotate failed")
                completion(nil)
                return
            }

            guard let wrapped = self.wrapPixelBuffer(outPB, originalSampleBuffer: sampleBuffer) else {
                self.logTo("wrapPixelBuffer failed")
                completion(nil)
                return
            }

            self.logTo("CPU rotate done: \(srcW)x\(srcH) -> \(dstW)x\(dstH)")

            // ✅ 直接餵 VTEncoder
            if let encoder = self.vtEncoder {
                encoder.encode(wrapped)
            }

            completion(wrapped) // 回傳結果
        }
    }


    // MARK: - pool utilities
    private func getReusableBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        poolLock.lock()
        // find exact match
        if let idx = bufferPool.firstIndex(where: { CVPixelBufferGetWidth($0.pixelBuffer) == width && CVPixelBufferGetHeight($0.pixelBuffer) == height }) {
            bufferPool[idx].lastUsed = Date()
            let pb = bufferPool[idx].pixelBuffer
            poolLock.unlock()
            return pb
        }
        poolLock.unlock()

        // create new
        var newPB: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] // allow IOSurface
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs as CFDictionary, &newPB)
        guard status == kCVReturnSuccess, let pb = newPB else { return nil }

        poolLock.lock()
        bufferPool.append(PooledBuffer(pixelBuffer: pb, lastUsed: Date()))
        // trim
        bufferPool.sort { $0.lastUsed < $1.lastUsed }
        while bufferPool.count > maxPoolSize {
            bufferPool.removeFirst(bufferPool.count - maxPoolSize)
        }
        logTo("bufferCount:\(bufferPool.count)")
        poolLock.unlock()

        return pb
    }

    // MARK: - CPU NV12 rotation (manual memcpy)
    // Supports 0/90/180/270. Assumes full-range NV12 (Y plane full size, UV interleaved half size).
    private func rotateNV12CPU(inPixelBuffer: CVPixelBuffer, outPixelBuffer: CVPixelBuffer, angle: RotationAngle) -> Bool {
        CVPixelBufferLockBaseAddress(inPixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(outPixelBuffer, [])

        defer {
            CVPixelBufferUnlockBaseAddress(inPixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(outPixelBuffer, [])
        }

        // Y plane
        guard let inYBase = CVPixelBufferGetBaseAddressOfPlane(inPixelBuffer, 0),
              let outYBase = CVPixelBufferGetBaseAddressOfPlane(outPixelBuffer, 0) else { return false }

        let inYStride = CVPixelBufferGetBytesPerRowOfPlane(inPixelBuffer, 0)
        let outYStride = CVPixelBufferGetBytesPerRowOfPlane(outPixelBuffer, 0)
        let inYWidth = CVPixelBufferGetWidthOfPlane(inPixelBuffer, 0)
        let inYHeight = CVPixelBufferGetHeightOfPlane(inPixelBuffer, 0)
        let outYWidth = CVPixelBufferGetWidthOfPlane(outPixelBuffer, 0)
        let outYHeight = CVPixelBufferGetHeightOfPlane(outPixelBuffer, 0)

        // UV plane
        guard let inUVBase = CVPixelBufferGetBaseAddressOfPlane(inPixelBuffer, 1),
              let outUVBase = CVPixelBufferGetBaseAddressOfPlane(outPixelBuffer, 1) else { return false }

        let inUVStride = CVPixelBufferGetBytesPerRowOfPlane(inPixelBuffer, 1)
        let outUVStride = CVPixelBufferGetBytesPerRowOfPlane(outPixelBuffer, 1)
        let inUVWidth = CVPixelBufferGetWidthOfPlane(inPixelBuffer, 1)  // W/2
        let inUVHeight = CVPixelBufferGetHeightOfPlane(inPixelBuffer, 1) // H/2
        let outUVWidth = CVPixelBufferGetWidthOfPlane(outPixelBuffer, 1)
        let outUVHeight = CVPixelBufferGetHeightOfPlane(outPixelBuffer, 1)

        let inY = inYBase.assumingMemoryBound(to: UInt8.self)
        let outY = outYBase.assumingMemoryBound(to: UInt8.self)
        let inUV = inUVBase.assumingMemoryBound(to: UInt8.self)
        let outUV = outUVBase.assumingMemoryBound(to: UInt8.self)

        switch angle {
        case .angle0:
            // copy Y
            for row in 0..<inYHeight {
                let src = inY.advanced(by: row * inYStride)
                let dst = outY.advanced(by: row * outYStride)
                dst.update(from: src, count: inYWidth)
            }
            // copy UV
            for row in 0..<inUVHeight {
                let src = inUV.advanced(by: row * inUVStride)
                let dst = outUV.advanced(by: row * outUVStride)
                dst.update(from: src, count: inUVWidth * 2)
            }

        case .angle180:
            for row in 0..<inYHeight {
                let srcRow = inY.advanced(by: row * inYStride)
                let dstRow = outY.advanced(by: (outYHeight - 1 - row) * outYStride)
                for col in 0..<inYWidth {
                    dstRow[inYWidth - 1 - col] = srcRow[col]
                }
            }
            for row in 0..<inUVHeight {
                let srcRow = inUV.advanced(by: row * inUVStride)
                let dstRow = outUV.advanced(by: (outUVHeight - 1 - row) * outUVStride)
                for col in 0..<inUVWidth {
                    dstRow[(inUVWidth - 1 - col) * 2 + 0] = srcRow[col * 2 + 0]
                    dstRow[(inUVWidth - 1 - col) * 2 + 1] = srcRow[col * 2 + 1]
                }
            }

        case .angle90:
            for y in 0..<inYHeight {
                let srcRow = inY.advanced(by: y * inYStride)
                for x in 0..<inYWidth {
                    let dstX = y
                    let dstY = inYWidth - 1 - x
                    guard dstX < outYWidth && dstY < outYHeight else { continue }
                    outY[dstY * outYStride + dstX] = srcRow[x]
                }
            }
            for y in 0..<inUVHeight {
                let srcRow = inUV.advanced(by: y * inUVStride)
                for x in 0..<inUVWidth {
                    let dstX = y
                    let dstY = inUVWidth - 1 - x
                    guard dstX < outUVWidth && dstY < outUVHeight else { continue }
                    outUV[dstY * outUVStride + dstX * 2 + 0] = srcRow[x*2 + 0]
                    outUV[dstY * outUVStride + dstX * 2 + 1] = srcRow[x*2 + 1]
                }
            }

        case .angle270:
            for y in 0..<inYHeight {
                let srcRow = inY.advanced(by: y * inYStride)
                for x in 0..<inYWidth {
                    let dstX = inYHeight - 1 - y
                    let dstY = x
                    guard dstX < outYWidth && dstY < outYHeight else { continue }
                    outY[dstY * outYStride + dstX] = srcRow[x]
                }
            }
            for y in 0..<inUVHeight {
                let srcRow = inUV.advanced(by: y * inUVStride)
                for x in 0..<inUVWidth {
                    let dstX = inUVHeight - 1 - y
                    let dstY = x

                    guard dstX < outUVWidth && dstY < outUVHeight else { continue }
                    outUV[dstY * outUVStride + dstX*2 + 0] = srcRow[x*2 + 0]
                    outUV[dstY * outUVStride + dstX*2 + 1] = srcRow[x*2 + 1]
                }
            }
        }

        return true
    }


    // MARK: - wrap pixelBuffer -> CMSampleBuffer
    private func wrapPixelBuffer(_ pixelBuffer: CVPixelBuffer, originalSampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        var timingInfo = CMSampleTimingInfo.invalid
        if CMSampleBufferGetSampleTimingInfo(originalSampleBuffer, at: 0, timingInfoOut: &timingInfo) != noErr {
            // fallback: create timing from CFAbsoluteTime
            timingInfo.duration = CMTime.invalid
            timingInfo.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(originalSampleBuffer)
            timingInfo.decodeTimeStamp = .invalid
        }

        var formatDesc: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDesc) == noErr,
              let fmt = formatDesc else { return nil }

        var newBuffer: CMSampleBuffer?
        let ret = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt, sampleTiming: &timingInfo, sampleBufferOut: &newBuffer)
        guard ret == noErr else { return nil }
        return newBuffer
    }
}

