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
            let inBuf = inBuffer
            let outBuf = outPB
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }
                let ok: Bool
                if outW == rotatedW && outH == rotatedH {
                    ok = self.rotateNV12CPU(inPixelBuffer: inBuf, outPixelBuffer: outBuf, angle: angle)
                } else {
                    ok = self.rotateAndScaleNV12(inPixelBuffer: inBuf, outPixelBuffer: outBuf, angle: angle,
                                                 rotatedW: rotatedW, rotatedH: rotatedH,
                                                 srcW: srcW, srcH: srcH)
                }
                guard ok else {
                    self.logTo("CPU rotate failed")
                    continuation.resume(returning: nil)
                    return
                }
                let wrapped = self.wrapPixelBuffer(outBuf, originalSampleBuffer: sampleBuffer)
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

    // MARK: - Manual rotate + scale (rotate to temp, then vImage scale)
    private func rotateAndScaleNV12(inPixelBuffer: CVPixelBuffer, outPixelBuffer: CVPixelBuffer, angle: RotationAngle,
                                     rotatedW: Int, rotatedH: Int, srcW: Int, srcH: Int) -> Bool {
        guard let tempPB = getReusableBuffer(width: rotatedW, height: rotatedH) else {
            logTo("rotateAndScale: temp buffer alloc failed")
            return false
        }
        guard rotateNV12CPU(inPixelBuffer: inPixelBuffer, outPixelBuffer: tempPB, angle: angle) else {
            return false
        }
        // vImage scale temp → out
        CVPixelBufferLockBaseAddress(tempPB, .readOnly)
        CVPixelBufferLockBaseAddress(outPixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(tempPB, .readOnly)
            CVPixelBufferUnlockBaseAddress(outPixelBuffer, [])
        }
        guard let tempYBase = CVPixelBufferGetBaseAddressOfPlane(tempPB, 0),
              let outYBase = CVPixelBufferGetBaseAddressOfPlane(outPixelBuffer, 0),
              let tempUVBase = CVPixelBufferGetBaseAddressOfPlane(tempPB, 1),
              let outUVBase = CVPixelBufferGetBaseAddressOfPlane(outPixelBuffer, 1) else {
            return false
        }
        let tempYStride = CVPixelBufferGetBytesPerRowOfPlane(tempPB, 0)
        let outYStride = CVPixelBufferGetBytesPerRowOfPlane(outPixelBuffer, 0)
        let tempYWidth = CVPixelBufferGetWidthOfPlane(tempPB, 0)
        let tempYHeight = CVPixelBufferGetHeightOfPlane(tempPB, 0)
        let outYWidth = CVPixelBufferGetWidthOfPlane(outPixelBuffer, 0)
        let outYHeight = CVPixelBufferGetHeightOfPlane(outPixelBuffer, 0)

        var srcYBuf = vImage_Buffer(data: tempYBase, height: vImagePixelCount(tempYHeight), width: vImagePixelCount(tempYWidth), rowBytes: tempYStride)
        var dstYBuf = vImage_Buffer(data: outYBase, height: vImagePixelCount(outYHeight), width: vImagePixelCount(outYWidth), rowBytes: outYStride)
        if vImageScale_Planar8(&srcYBuf, &dstYBuf, nil, vImage_Flags(kvImageHighQualityResampling)) != kvImageNoError {
            return false
        }
        // UV scale via ARGB wrapper
        let tempUVStride = CVPixelBufferGetBytesPerRowOfPlane(tempPB, 1)
        let outUVStride = CVPixelBufferGetBytesPerRowOfPlane(outPixelBuffer, 1)
        let tempUVWidth = CVPixelBufferGetWidthOfPlane(tempPB, 1)
        let tempUVHeight = CVPixelBufferGetHeightOfPlane(tempPB, 1)

        var srcUVBuf = vImage_Buffer(data: tempUVBase, height: vImagePixelCount(tempUVHeight), width: vImagePixelCount(tempUVWidth), rowBytes: tempUVStride)
        var dstUVBuf = vImage_Buffer(data: outUVBase, height: vImagePixelCount(outYHeight / 2), width: vImagePixelCount(outYWidth / 2), rowBytes: outUVStride)
        // Use vImageScale_Planar8 on a deinterleaved UV approach:
        // For NV12, UV is 2-channel interleaved. We wrap as planar8 and scale each channel.
        let uvPixels = Int(tempUVHeight) * tempUVStride
        let uTemp = UnsafeMutablePointer<UInt8>.allocate(capacity: uvPixels / 2)
        let vTemp = UnsafeMutablePointer<UInt8>.allocate(capacity: uvPixels / 2)
        defer { uTemp.deallocate(); vTemp.deallocate() }
        // Deinterleave
        let srcUV = tempUVBase.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(tempUVWidth * tempUVHeight) {
            uTemp[i] = srcUV[i * 2]
            vTemp[i] = srcUV[i * 2 + 1]
        }
        let uOutSize = (outYWidth / 2) * (outYHeight / 2)
        let uOut = UnsafeMutablePointer<UInt8>.allocate(capacity: uOutSize)
        let vOut = UnsafeMutablePointer<UInt8>.allocate(capacity: uOutSize)
        defer { uOut.deallocate(); vOut.deallocate() }

        var uSrcBuf = vImage_Buffer(data: uTemp, height: vImagePixelCount(tempUVHeight), width: vImagePixelCount(tempUVWidth), rowBytes: tempUVWidth)
        var uDstBuf = vImage_Buffer(data: uOut, height: vImagePixelCount(outYHeight / 2), width: vImagePixelCount(outYWidth / 2), rowBytes: outYWidth / 2)
        if vImageScale_Planar8(&uSrcBuf, &uDstBuf, nil, vImage_Flags(kvImageHighQualityResampling)) != kvImageNoError {
            return false
        }
        var vSrcBuf = vImage_Buffer(data: vTemp, height: vImagePixelCount(tempUVHeight), width: vImagePixelCount(tempUVWidth), rowBytes: tempUVWidth)
        var vDstBuf = vImage_Buffer(data: vOut, height: vImagePixelCount(outYHeight / 2), width: vImagePixelCount(outYWidth / 2), rowBytes: outYWidth / 2)
        if vImageScale_Planar8(&vSrcBuf, &vDstBuf, nil, vImage_Flags(kvImageHighQualityResampling)) != kvImageNoError {
            return false
        }
        // Re-interleave
        let outUV = outUVBase.assumingMemoryBound(to: UInt8.self)
        let outUVWidth = outYWidth / 2
        for y in 0..<(outYHeight / 2) {
            let rowOffset = y * (outYWidth / 2)
            for x in 0..<outUVWidth {
                outUV[y * outUVStride + x * 2] = uOut[rowOffset + x]
                outUV[y * outUVStride + x * 2 + 1] = vOut[rowOffset + x]
            }
        }
        return true
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

