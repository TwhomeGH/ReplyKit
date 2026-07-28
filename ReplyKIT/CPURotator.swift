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

// MARK: - Sendable wrapper for CoreVideo types
private struct UnsafeSendableValue<T>: @unchecked Sendable {
    let value: T
}

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

        // 閮? letterbox嚗niform scale + 蝵桐葉
        let scaleX = Float(outW) / Float(rotatedW)
        let scaleY = Float(outH) / Float(rotatedH)
        let uniformScale = min(scaleX, scaleY)
        let scaledW = Int(Float(rotatedW) * uniformScale)
        let scaledH = Int(Float(rotatedH) * uniformScale)
        let offsetX = max(0, (outW - scaledW) / 2)
        let offsetY = max(0, (outH - scaledH) / 2)

        // ?刻??臬銵??瑁? CPU ??
        return await withCheckedContinuation { continuation in
            let sendableIn = UnsafeSendableValue(value: inBuffer as CVImageBuffer)
            let sendableOut = UnsafeSendableValue(value: outPB)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }
                let ok: Bool
                if scaledW == rotatedW && scaledH == rotatedH {
                    // ?∠葬?橘???頧?+ letterbox 蝵桐葉
                    ok = self.rotateNV12CPUWithLetterbox(
                        inPixelBuffer: sendableIn.value, outPixelBuffer: sendableOut.value, angle: angle,
                        scaledW: scaledW, scaledH: scaledH,
                        offsetX: offsetX, offsetY: offsetY
                    )
                } else {
                    // ?? + 蝮格 + letterbox
                    ok = self.rotateAndScaleNV12(
                        inPixelBuffer: sendableIn.value, outPixelBuffer: sendableOut.value, angle: angle,
                        rotatedW: rotatedW, rotatedH: rotatedH,
                        scaledW: scaledW, scaledH: scaledH,
                        offsetX: offsetX, offsetY: offsetY
                    )
                }
                guard ok else {
                    self.logTo("CPU rotate failed")
                    continuation.resume(returning: nil)
                    return
                }
                let wrapped = self.wrapPixelBuffer(sendableOut.value, originalSampleBuffer: sampleBuffer)
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

    // MARK: - Rotate + letterbox (rotate to temp, then center-copy into output)
    private func rotateNV12CPUWithLetterbox(inPixelBuffer: CVPixelBuffer, outPixelBuffer: CVPixelBuffer,
                                            angle: RotationAngle,
                                            scaledW: Int, scaledH: Int,
                                            offsetX: Int, offsetY: Int) -> Bool {
        guard let tempPB = getReusableBuffer(width: scaledW, height: scaledH) else {
            logTo("rotateNV12CPUWithLetterbox: temp buffer alloc failed")
            return false
        }
        guard rotateNV12CPU(inPixelBuffer: inPixelBuffer, outPixelBuffer: tempPB, angle: angle) else {
            return false
        }
        // Black-fill output, then copy temp into center region
        CVPixelBufferLockBaseAddress(tempPB, .readOnly)
        CVPixelBufferLockBaseAddress(outPixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(tempPB, .readOnly)
            CVPixelBufferUnlockBaseAddress(outPixelBuffer, [])
        }
        guard let tempYBase = CVPixelBufferGetBaseAddressOfPlane(tempPB, 0),
              let outYBase = CVPixelBufferGetBaseAddressOfPlane(outPixelBuffer, 0),
              let tempUVBase = CVPixelBufferGetBaseAddressOfPlane(tempPB, 1),
              let outUVBase = CVPixelBufferGetBaseAddressOfPlane(outPixelBuffer, 1) else { return false }

        let outYStride = CVPixelBufferGetBytesPerRowOfPlane(outPixelBuffer, 0)
        let outH = CVPixelBufferGetHeightOfPlane(outPixelBuffer, 0)
        let outYWidth = CVPixelBufferGetWidthOfPlane(outPixelBuffer, 0)
        let tempYStride = CVPixelBufferGetBytesPerRowOfPlane(tempPB, 0)

        let outUVStride = CVPixelBufferGetBytesPerRowOfPlane(outPixelBuffer, 1)
        let outUVHeight = CVPixelBufferGetHeightOfPlane(outPixelBuffer, 1)
        let outUVWidth = CVPixelBufferGetWidthOfPlane(outPixelBuffer, 1)
        let tempUVStride = CVPixelBufferGetBytesPerRowOfPlane(tempPB, 1)

        // Fill Y plane with black
        for row in 0..<outH {
            memset(outYBase.advanced(by: row * outYStride), 0, outYWidth)
        }
        // Fill UV plane with neutral (128)
        for row in 0..<outUVHeight {
            memset(outUVBase.advanced(by: row * outUVStride), 128, outUVWidth * 2)
        }
        // Copy temp Y into center
        for row in 0..<scaledH {
            let dstRow = outYBase.advanced(by: (offsetY + row) * outYStride + offsetX)
            memcpy(dstRow, tempYBase.advanced(by: row * tempYStride), scaledW)
        }
        // Copy temp UV into center
        let scaledUVW = scaledW / 2
        let scaledUVH = scaledH / 2
        let uvOffX = offsetX / 2
        let uvOffY = offsetY / 2
        for row in 0..<scaledUVH {
            let dstRow = outUVBase.advanced(by: (uvOffY + row) * outUVStride + uvOffX * 2)
            memcpy(dstRow, tempUVBase.advanced(by: row * tempUVStride), scaledUVW * 2)
        }
        return true
    }

    // MARK: - Rotate + scale + letterbox
    private func rotateAndScaleNV12(inPixelBuffer: CVPixelBuffer, outPixelBuffer: CVPixelBuffer, angle: RotationAngle,
                                     rotatedW: Int, rotatedH: Int,
                                     scaledW: Int, scaledH: Int,
                                     offsetX: Int, offsetY: Int) -> Bool {
        guard let tempPB = getReusableBuffer(width: rotatedW, height: rotatedH) else {
            logTo("rotateAndScale: temp buffer alloc failed")
            return false
        }
        guard rotateNV12CPU(inPixelBuffer: inPixelBuffer, outPixelBuffer: tempPB, angle: angle) else {
            return false
        }
        // Scale temp ??scaled buffer via vImage, then letterbox-copy to output
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
        let outYWidth = CVPixelBufferGetWidthOfPlane(outPixelBuffer, 0)
        let outYHeight = CVPixelBufferGetHeightOfPlane(outPixelBuffer, 0)
        let outUVStride = CVPixelBufferGetBytesPerRowOfPlane(outPixelBuffer, 1)
        let outUVHeight = CVPixelBufferGetHeightOfPlane(outPixelBuffer, 1)
        let outUVWidth = CVPixelBufferGetWidthOfPlane(outPixelBuffer, 1)

        // Allocate planar buffers for scaled Y and UV
        let yPixels = scaledW * scaledH
        let uvPixels = (scaledW / 2) * (scaledH / 2)
        let scaledY = UnsafeMutablePointer<UInt8>.allocate(capacity: yPixels)
        let scaledU = UnsafeMutablePointer<UInt8>.allocate(capacity: uvPixels)
        let scaledV = UnsafeMutablePointer<UInt8>.allocate(capacity: uvPixels)
        defer { scaledY.deallocate(); scaledU.deallocate(); scaledV.deallocate() }

        // Scale Y plane
        var srcYBuf = vImage_Buffer(data: tempYBase, height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(tempPB, 0)), width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(tempPB, 0)), rowBytes: tempYStride)
        var dstYBuf = vImage_Buffer(data: scaledY, height: vImagePixelCount(scaledH), width: vImagePixelCount(scaledW), rowBytes: scaledW)
        if vImageScale_Planar8(&srcYBuf, &dstYBuf, nil, vImage_Flags(kvImageHighQualityResampling)) != kvImageNoError {
            return false
        }
        // Deinterleave UV, scale, reinterleave
        let tempUVWidth = CVPixelBufferGetWidthOfPlane(tempPB, 1)
        let tempUVHeight = CVPixelBufferGetHeightOfPlane(tempPB, 1)
        let srcUV = tempUVBase.assumingMemoryBound(to: UInt8.self)
        let tempUVSize = tempUVWidth * tempUVHeight
        let uFrom = UnsafeMutablePointer<UInt8>.allocate(capacity: tempUVSize)
        let vFrom = UnsafeMutablePointer<UInt8>.allocate(capacity: tempUVSize)
        defer { uFrom.deallocate(); vFrom.deallocate() }
        for i in 0..<tempUVSize {
            uFrom[i] = srcUV[i * 2]
            vFrom[i] = srcUV[i * 2 + 1]
        }
        var uSrcBuf = vImage_Buffer(data: uFrom, height: vImagePixelCount(tempUVHeight), width: vImagePixelCount(tempUVWidth), rowBytes: tempUVWidth)
        var uDstBuf = vImage_Buffer(data: scaledU, height: vImagePixelCount(scaledH / 2), width: vImagePixelCount(scaledW / 2), rowBytes: scaledW / 2)
        if vImageScale_Planar8(&uSrcBuf, &uDstBuf, nil, vImage_Flags(kvImageHighQualityResampling)) != kvImageNoError {
            return false
        }
        var vSrcBuf = vImage_Buffer(data: vFrom, height: vImagePixelCount(tempUVHeight), width: vImagePixelCount(tempUVWidth), rowBytes: tempUVWidth)
        var vDstBuf = vImage_Buffer(data: scaledV, height: vImagePixelCount(scaledH / 2), width: vImagePixelCount(scaledW / 2), rowBytes: scaledW / 2)
        if vImageScale_Planar8(&vSrcBuf, &vDstBuf, nil, vImage_Flags(kvImageHighQualityResampling)) != kvImageNoError {
            return false
        }
        // Black-fill output Y and UV
        for row in 0..<outYHeight {
            memset(outYBase.advanced(by: row * outYStride), 0, outYWidth)
        }
        for row in 0..<outUVHeight {
            memset(outUVBase.advanced(by: row * outUVStride), 128, outUVWidth * 2)
        }
        // Copy scaled Y into center of output
        for row in 0..<scaledH {
            memcpy(outYBase.advanced(by: (offsetY + row) * outYStride + offsetX),
                   scaledY.advanced(by: row * scaledW), scaledW)
        }
        // Copy re-interleaved UV into center
        let halfSW = scaledW / 2, halfSH = scaledH / 2
        let uvOffX = offsetX / 2, uvOffY = offsetY / 2
        for row in 0..<halfSH {
            let dstRow = outUVBase.advanced(by: (uvOffY + row) * outUVStride + uvOffX * 2)
            for x in 0..<halfSW {
                let typedDst = dstRow.assumingMemoryBound(to: UInt8.self)
                    typedDst[x * 2] = scaledU[row * halfSW + x]
                    typedDst[x * 2 + 1] = scaledV[row * halfSW + x]
            }
        }
        return true
    }

    // MARK: - Wrap pixelBuffer ??CMSampleBuffer
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

