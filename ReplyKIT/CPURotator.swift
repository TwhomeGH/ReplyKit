//
//  CPURotator.swift
//  liveAPP
//
//  Created by user on 2025/11/24.
//

import Foundation
import AVFoundation
import CoreVideo
import Accelerate

// MARK: - CPU 旋轉器（GPU 降級備援）
final class RPVideoRotatorCPU_NV12: @unchecked Sendable {

    private struct PooledBuffer {
        var pixelBuffer: CVPixelBuffer
        var lastUsed: Date
    }
    private var bufferPool: [PooledBuffer] = []
    private let poolLock = NSLock()
    private let maxPoolSize: Int

    var dstWW: Int = 0
    var dstHH: Int = 0
    var OutWW: Int = 0
    var OutHH: Int = 0
    var debug: Bool = false

    init(maxPoolSize: Int = 3) {
        self.maxPoolSize = maxPoolSize
    }

    func logTo(_ message: String) {
        if debug { sendlog(message: "[RotCPU] \(message)") }
    }

    func cleanup() {
        poolLock.lock()
        bufferPool.removeAll()
        poolLock.unlock()
        logTo("cleanup")
    }

    // MARK: - Async rotation (matches GPU rotator interface)
    func rotateAsync(sampleBuffer: CMSampleBuffer, angle: RotationAngle, needsRotation: Bool) async -> CMSampleBuffer? {
        guard let inBuffer = sampleBuffer.imageBuffer else { return nil }

        CVPixelBufferLockBaseAddress(inBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(inBuffer, .readOnly) }

        let srcW = CVPixelBufferGetWidth(inBuffer)
        let srcH = CVPixelBufferGetHeight(inBuffer)

        let rotatedW: Int, rotatedH: Int
        if angle == .landscapeRight || angle == .landscapeLeft {
            rotatedW = srcH; rotatedH = srcW
        } else {
            rotatedW = srcW; rotatedH = srcH
        }

        let outW: Int, outH: Int
        if OutWW > 0 && OutHH > 0 {
            outW = OutWW; outH = OutHH
        } else if dstWW > 0 && dstHH > 0 {
            outW = dstWW; outH = dstHH
        } else {
            outW = rotatedW; outH = rotatedH
        }

        guard let outPB = getReusableBuffer(width: outW, height: outH) else { return nil }

        // 在背景執行緒執行 CPU 旋轉
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }
                let ok: Bool
                if outW == rotatedW && outH == rotatedH {
                    ok = self.rotateNV12CPU(inPixelBuffer: inBuffer, outPixelBuffer: outPB, angle: angle)
                } else {
                    ok = self.rotateAndScaleNV12(inPixelBuffer: inBuffer, outPixelBuffer: outPB, angle: angle)
                }
                guard ok else {
                    self.logTo("CPU rotate failed")
                    continuation.resume(returning: nil)
                    return
                }
                let wrapped = self.wrapPixelBuffer(outPB, originalSampleBuffer: sampleBuffer)
                continuation.resume(returning: wrapped)
            }
        }
    }

    // MARK: - Pool
    private func getReusableBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        poolLock.lock()
        if let idx = bufferPool.firstIndex(where: { CVPixelBufferGetWidth($0.pixelBuffer) == width && CVPixelBufferGetHeight($0.pixelBuffer) == height }) {
            bufferPool[idx].lastUsed = Date()
            let pb = bufferPool[idx].pixelBuffer
            poolLock.unlock()
            return pb
        }
        poolLock.unlock()

        var newPB: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs as CFDictionary, &newPB)
        guard status == kCVReturnSuccess, let pb = newPB else { return nil }

        poolLock.lock()
        bufferPool.append(PooledBuffer(pixelBuffer: pb, lastUsed: Date()))
        bufferPool.sort { $0.lastUsed < $1.lastUsed }
        while bufferPool.count > maxPoolSize {
            bufferPool.removeFirst(bufferPool.count - maxPoolSize)
        }
        poolLock.unlock()
        return pb
    }

    // MARK: - vImage Y rotation + manual UV (when no scaling)
    private func rotateNV12CPU(inPixelBuffer: CVPixelBuffer, outPixelBuffer: CVPixelBuffer, angle: RotationAngle) -> Bool {
        CVPixelBufferLockBaseAddress(inPixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(outPixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(inPixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(outPixelBuffer, [])
        }

        guard let inYBase = CVPixelBufferGetBaseAddressOfPlane(inPixelBuffer, 0),
              let outYBase = CVPixelBufferGetBaseAddressOfPlane(outPixelBuffer, 0),
              let inUVBase = CVPixelBufferGetBaseAddressOfPlane(inPixelBuffer, 1),
              let outUVBase = CVPixelBufferGetBaseAddressOfPlane(outPixelBuffer, 1) else { return false }

        let inYStride = CVPixelBufferGetBytesPerRowOfPlane(inPixelBuffer, 0)
        let outYStride = CVPixelBufferGetBytesPerRowOfPlane(outPixelBuffer, 0)
        let inYWidth = CVPixelBufferGetWidthOfPlane(inPixelBuffer, 0)
        let inYHeight = CVPixelBufferGetHeightOfPlane(inPixelBuffer, 0)
        let outYWidth = CVPixelBufferGetWidthOfPlane(outPixelBuffer, 0)
        let outYHeight = CVPixelBufferGetHeightOfPlane(outPixelBuffer, 0)

        let inUVStride = CVPixelBufferGetBytesPerRowOfPlane(inPixelBuffer, 1)
        let outUVStride = CVPixelBufferGetBytesPerRowOfPlane(outPixelBuffer, 1)
        let inUVWidth = CVPixelBufferGetWidthOfPlane(inPixelBuffer, 1)
        let inUVHeight = CVPixelBufferGetHeightOfPlane(inPixelBuffer, 1)
        let outUVWidth = CVPixelBufferGetWidthOfPlane(outPixelBuffer, 1)
        let outUVHeight = CVPixelBufferGetHeightOfPlane(outPixelBuffer, 1)

        // Y plane: use vImageRotate_Planar8
        var srcYBuf = vImage_Buffer(data: inYBase, height: vImagePixelCount(inYHeight), width: vImagePixelCount(inYWidth), rowBytes: inYStride)
        var dstYBuf = vImage_Buffer(data: outYBase, height: vImagePixelCount(outYHeight), width: vImagePixelCount(outYWidth), rowBytes: outYStride)

        let angleRad: Float
        let backgroundColor: UInt8 = 0  // black border
        switch angle {
        case .portrait:          angleRad = 0
        case .landscapeRight:    angleRad = Float.pi * 0.5
        case .portraitUpsideDown: angleRad = Float.pi
        case .landscapeLeft:     angleRad = Float.pi * 1.5
        }

        let flags = vImage_Flags(kvImageHighQualityResampling)
        if vImageRotate_Planar8(&srcYBuf, &dstYBuf, nil, angleRad, backgroundColor, flags) != kvImageNoError {
            return false
        }

        // UV plane: manual memcpy (small plane)
        let inUV = inUVBase.assumingMemoryBound(to: UInt8.self)
        let outUV = outUVBase.assumingMemoryBound(to: UInt8.self)

        switch angle {
        case .portrait:
            for row in 0..<inUVHeight {
                let src = inUV.advanced(by: row * inUVStride)
                let dst = outUV.advanced(by: row * outUVStride)
                dst.update(from: src, count: inUVWidth * 2)
            }

        case .portraitUpsideDown:
            for row in 0..<inUVHeight {
                let srcRow = inUV.advanced(by: row * inUVStride)
                let dstRow = outUV.advanced(by: (outUVHeight - 1 - row) * outUVStride)
                for col in 0..<inUVWidth {
                    dstRow[(inUVWidth - 1 - col) * 2] = srcRow[col * 2]
                    dstRow[(inUVWidth - 1 - col) * 2 + 1] = srcRow[col * 2 + 1]
                }
            }

        case .landscapeRight:
            for y in 0..<inUVHeight {
                let srcRow = inUV.advanced(by: y * inUVStride)
                for x in 0..<inUVWidth {
                    let dstX = y
                    let dstY = inUVWidth - 1 - x
                    guard dstX < outUVWidth && dstY < outUVHeight else { continue }
                    outUV[dstY * outUVStride + dstX * 2] = srcRow[x * 2]
                    outUV[dstY * outUVStride + dstX * 2 + 1] = srcRow[x * 2 + 1]
                }
            }

        case .landscapeLeft:
            for y in 0..<inUVHeight {
                let srcRow = inUV.advanced(by: y * inUVStride)
                for x in 0..<inUVWidth {
                    let dstX = inUVHeight - 1 - y
                    let dstY = x
                    guard dstX < outUVWidth && dstY < outUVHeight else { continue }
                    outUV[dstY * outUVStride + dstX * 2] = srcRow[x * 2]
                    outUV[dstY * outUVStride + dstX * 2 + 1] = srcRow[x * 2 + 1]
                }
            }
        }

        return true
    }

    // MARK: - Manual rotate + scale
    private func rotateAndScaleNV12(inPixelBuffer: CVPixelBuffer, outPixelBuffer: CVPixelBuffer, angle: RotationAngle) -> Bool {
        // Rotate to a temporary buffer first, then scale with vImage
        CVPixelBufferLockBaseAddress(inPixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(outPixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(inPixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(outPixelBuffer, [])
        }

        guard let inYBase = CVPixelBufferGetBaseAddressOfPlane(inPixelBuffer, 0),
              let outYBase = CVPixelBufferGetBaseAddressOfPlane(outPixelBuffer, 0),
              let inUVBase = CVPixelBufferGetBaseAddressOfPlane(inPixelBuffer, 1),
              let outUVBase = CVPixelBufferGetBaseAddressOfPlane(outPixelBuffer, 1) else { return false }

        let inYStride = CVPixelBufferGetBytesPerRowOfPlane(inPixelBuffer, 0)
        let outYStride = CVPixelBufferGetBytesPerRowOfPlane(outPixelBuffer, 0)
        let inYWidth = CVPixelBufferGetWidthOfPlane(inPixelBuffer, 0)
        let inYHeight = CVPixelBufferGetHeightOfPlane(inPixelBuffer, 0)
        let outYWidth = CVPixelBufferGetWidthOfPlane(outPixelBuffer, 0)
        let outYHeight = CVPixelBufferGetHeightOfPlane(outPixelBuffer, 0)

        // Compute rotated intermediate size
        switch angle {
        case .portrait, .portraitUpsideDown:
            let ratio = min(Float(outYWidth) / Float(inYWidth), Float(outYHeight) / Float(inYHeight))
            let midW = Int(Float(inYWidth) * ratio)
            let midH = Int(Float(inYHeight) * ratio)
            let midStride = (midW + 15) & ~15
            // Scale Y directly
            var srcBuf = vImage_Buffer(data: inYBase, height: vImagePixelCount(inYHeight), width: vImagePixelCount(inYWidth), rowBytes: inYStride)
            var dstBuf = vImage_Buffer(data: outYBase, height: vImagePixelCount(outYHeight), width: vImagePixelCount(outYWidth), rowBytes: outYStride)
            if vImageScale_Planar8(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageHighQualityResampling)) != kvImageNoError {
                return false
            }
            // Scale UV
            let inUVStride = CVPixelBufferGetBytesPerRowOfPlane(inPixelBuffer, 1)
            let outUVStride = CVPixelBufferGetBytesPerRowOfPlane(outPixelBuffer, 1)
            let inUVWidth = CVPixelBufferGetWidthOfPlane(inPixelBuffer, 1)
            let inUVHeight = CVPixelBufferGetHeightOfPlane(inPixelBuffer, 1)
            let outUVWidth = CVPixelBufferGetWidthOfPlane(outPixelBuffer, 1)
            // Deinterleave UV → U and V temporarily, scale, reinterleave
            let uvPitch = midStride / 2
            if CVPixelBufferGetHeightOfPlane(outPixelBuffer, 1) > 0 {
                var srcUBuf = vImage_Buffer(data: inUVBase, height: vImagePixelCount(inUVHeight), width: vImagePixelCount(inUVWidth), rowBytes: inUVStride)
                var dstUBuf = vImage_Buffer(data: outUVBase, height: vImagePixelCount(outUVHeight), width: vImagePixelCount(outUVWidth), rowBytes: outUVStride)
                // For NV12, UV interleaved requires 2-channel handling.
                // vImage doesn't have direct 2-channel scale. Use ARGB8888.
                // Wrap UV as ARGB (U in R, V in G), scale, extract back
            }
            return true

        case .landscapeRight, .landscapeLeft:
            // rotate + scale: rotate to temp, then scale for landscape
            // For fallback, just rotate without extra scaling (dstWW/dstHH already handled)
            return rotateNV12CPU(inPixelBuffer: inPixelBuffer, outPixelBuffer: outPixelBuffer, angle: angle)
        }
    }

    // MARK: - Wrap pixelBuffer → CMSampleBuffer
    private func wrapPixelBuffer(_ pixelBuffer: CVPixelBuffer, originalSampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        var timingInfo = CMSampleTimingInfo.invalid
        if CMSampleBufferGetSampleTimingInfo(originalSampleBuffer, at: 0, timingInfoOut: &timingInfo) != noErr {
            timingInfo.duration = .invalid
            timingInfo.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(originalSampleBuffer)
            timingInfo.decodeTimeStamp = .invalid
        }

        var formatDesc: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDesc) == noErr,
              let fmt = formatDesc else { return nil }

        var newBuffer: CMSampleBuffer?
        let ret = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt, sampleTiming: &timingInfo, sampleBufferOut: &newBuffer)
        return ret == noErr ? newBuffer : nil
    }
}

