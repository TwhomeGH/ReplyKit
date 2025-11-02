//
//  Untitled.swift
//  liveAPP
//
//  Created by user on 2025/10/24.
//

import UIKit
import CoreMedia
import VideoToolbox
import Accelerate

// MARK: 暫停中
// 建立 PixelBuffer
// MARK: - 工具
/// 建立或重用一個指定格式的 CVPixelBuffer。
///
/// - Parameters:
///   - width: 寬度（像素）
///   - height: 高度（像素）
///   - format: Pixel 格式（例如 kCVPixelFormatType_32BGRA / kCVPixelFormatType_420YpCbCr8BiPlanarFullRange）
///   - reuse: 可選，傳入舊的 buffer 用於重用（若尺寸與格式相同）
/// - Returns: 可用的 CVPixelBuffer（新建或重用）
func createPixelBuffer(width: Int, height: Int, format: OSType, reuse existing: CVPixelBuffer?) -> CVPixelBuffer? {
    // ✅ 若已有可重用 buffer 且尺寸、格式一致，直接回傳
    if let existing = existing,
       CVPixelBufferGetWidth(existing) == width,
       CVPixelBufferGetHeight(existing) == height,
       CVPixelBufferGetPixelFormatType(existing) == format {
        sendlog(message: "♻️ Reuse PixelBuffer (\(width)x\(height), format: \(format))")
        
        return existing
    }

    // ✅ 否則重新建立
    var buffer: CVPixelBuffer?
    let attrs = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true
    ] as CFDictionary

    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        format,
        attrs,
        &buffer
    )

    if status == kCVReturnSuccess, let buffer = buffer {
            sendlog(message: "🆕 Created new PixelBuffer (\(width)x\(height), format: \(format))")
            return buffer
        } else {
            sendlog(message: "❌ Failed to create PixelBuffer (status: \(status))")
            return nil
        }

}

// MARK: - 建立 CGContext
func createContext(for pixelBuffer: CVPixelBuffer) -> CGContext? {
    let flags = CVPixelBufferLockFlags(rawValue: 0)
    guard kCVReturnSuccess == CVPixelBufferLockBaseAddress(pixelBuffer, flags),
          let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        sendlog(message: "❌ createContext: 無法 lock 或 baseAddress 為 nil")
        return nil
    }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

    let context = CGContext(data: baseAddress,
                            width: width,
                            height: height,
                            bitsPerComponent: 8,
                            bytesPerRow: bytesPerRow,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
    return context
}


// MARK: - 更新暫停畫面
func updatePausedContext(buffer: CVPixelBuffer, context: CGContext, text: String) {
    let flags = CVPixelBufferLockFlags(rawValue: 0)
    guard kCVReturnSuccess == CVPixelBufferLockBaseAddress(buffer, flags) else {
        sendlog(message: "❌ updatePausedContext: 無法 lock buffer")
        return
    }
    defer { CVPixelBufferUnlockBaseAddress(buffer, flags) }

    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)

    // 防呆
    guard context.width == width, context.height == height else {
        sendlog(message: "⚠️ updatePausedContext: context 尺寸與 buffer 不符")
        return
    }

    // 黑底
    context.setFillColor(UIColor.black.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // 文字
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.boldSystemFont(ofSize: CGFloat(height) * 0.08),
        .foregroundColor: UIColor.white,
        .paragraphStyle: paragraph
    ]
    let textRect = CGRect(x: 0, y: (height-50)/2, width: width, height: 50)
    NSString(string: text).draw(in: textRect, withAttributes: attrs)
}


// MARK: - BGRA -> NV12
func convertBGRAtoNV12(bgra: CVPixelBuffer, nv12: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(bgra, .readOnly)
    CVPixelBufferLockBaseAddress(nv12, [])
    defer {
        CVPixelBufferUnlockBaseAddress(bgra, .readOnly)
        CVPixelBufferUnlockBaseAddress(nv12, [])
    }

    var sourceBuffer = vImage_Buffer(data: CVPixelBufferGetBaseAddress(bgra),
                                     height: vImagePixelCount(CVPixelBufferGetHeight(bgra)),
                                     width: vImagePixelCount(CVPixelBufferGetWidth(bgra)),
                                     rowBytes: CVPixelBufferGetBytesPerRow(bgra))

    var destY = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(nv12, 0),
                              height: vImagePixelCount(CVPixelBufferGetHeight(nv12)),
                              width: vImagePixelCount(CVPixelBufferGetWidth(nv12)),
                              rowBytes: CVPixelBufferGetBytesPerRowOfPlane(nv12, 0))

    var destUV = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(nv12, 1),
                               height: vImagePixelCount(CVPixelBufferGetHeight(nv12)/2),
                               width: vImagePixelCount(CVPixelBufferGetWidth(nv12)/2),
                               rowBytes: CVPixelBufferGetBytesPerRowOfPlane(nv12, 1))

    // 建立默認 BT.601 色彩矩陣
    var matrix = vImage_ARGBToYpCbCr()
    // 建立 pixel range (full 0~255)
    var pixelRange = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240, YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)


    vImageConvert_ARGB8888To420Yp8_CbCr8(
        &sourceBuffer,
        &destY,
        &destUV,
        &matrix,
        &pixelRange,
        vImage_Flags(kvImageNoFlags)
    )
}

// MARK: - SampleBuffer
// 修改後：透過參數傳入 frameIndex，返回新的 frameIndex
func createSampleBuffer(
    from pixelBuffer: CVPixelBuffer,
    frameIndex: inout Int,
    timescale: CMTimeScale = 30
) -> CMSampleBuffer? {
    var newSampleBuffer: CMSampleBuffer?
    var videoInfo: CMVideoFormatDescription?

    // 建立格式描述
    let status = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &videoInfo
    )
    guard status == noErr, let formatDesc = videoInfo else {
        sendlog(message: "❌ createSampleBuffer: formatDesc 生成失敗 (\(status))")
        return nil
    }

    // 固定 FPS
    let frameDuration = CMTime(value: 1, timescale: timescale)

    // 使用遞增的 PTS，確保時間連續
    let pts = CMTime(value: CMTimeValue(frameIndex), timescale: timescale)
    frameIndex += 1

    var timing = CMSampleTimingInfo(
        duration: frameDuration,
        presentationTimeStamp: pts,
        decodeTimeStamp: .invalid
    )

    let sampleStatus = CMSampleBufferCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: formatDesc,
        sampleTiming: &timing,
        sampleBufferOut: &newSampleBuffer
    )

    guard sampleStatus == noErr else {
        sendlog(message: "❌ createSampleBuffer: CMSampleBuffer 建立失敗 (\(sampleStatus))")
        return nil
    }

    return newSampleBuffer
}
