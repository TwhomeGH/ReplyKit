import Foundation
import VideoToolbox

/// 查詢條件也是快取鍵；結果只代表此尺寸與編碼器模式回報的能力。
struct H264CapabilityRequest: Hashable, Sendable {
    let width: Int
    let height: Int
    let lowLatency: Bool
}

/// 系統回報的選項及失敗階段；成功查詢不代表所有 FPS／碼率組合皆能編碼。
struct H264CapabilityResult: Sendable {
    let values: [String]
    let status: OSStatus
    let stage: String
}

/// 序列化背景查詢；不保存 VT session 或影像，最多快取八組成功結果。
actor H264EncoderCapabilities {
    static let shared = H264EncoderCapabilities()
    private var cache: [H264CapabilityRequest: H264CapabilityResult] = [:]

    /// 建立暫用 session 讀取 ProfileLevel 值清單，結束時立即釋放。
    /// refresh 允許裝置資源狀態改變後重新查詢；失敗不快取。
    func query(_ request: H264CapabilityRequest, refresh: Bool = false) -> H264CapabilityResult {
        if !refresh, let result = cache[request] { return result }
        guard let width = Int32(exactly: request.width), let height = Int32(exactly: request.height),
              width > 0, height > 0 else {
            return .init(values: [], status: kVTParameterErr, stage: "dimensions")
        }
        // 查詢期間共用擷取排他鎖；側載只能保護同程序。
        let lease: CaptureLease
        do { lease = try CaptureLease.acquire() }
        catch { return .init(values: [], status: OSStatus((error as NSError).code), stage: "captureLease") }
        defer { withExtendedLifetime(lease) {} }
        var session: VTCompressionSession?
        let specification: CFDictionary? = request.lowLatency
            ? [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary : nil
        let createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: width, height: height,
            codecType: kCMVideoCodecType_H264, encoderSpecification: specification,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session
        )
        defer { if let session { VTCompressionSessionInvalidate(session) } }
        guard createStatus == noErr, let session else {
            return .init(values: [], status: createStatus, stage: "create")
        }
        var properties: CFDictionary?
        let status = VTSessionCopySupportedPropertyDictionary(session, supportedPropertyDictionaryOut: &properties)
        guard status == noErr, let dictionary = properties as? [String: Any],
              let profile = dictionary[kVTCompressionPropertyKey_ProfileLevel as String] as? [String: Any],
              let values = profile[kVTPropertySupportedValueListKey as String] as? [String] else {
            return .init(values: [], status: status, stage: "supportedValues")
        }
        let result = H264CapabilityResult(values: H264EncodingProfile.supportedValues(values), status: status, stage: "supportedValues")
        if !result.values.isEmpty {
            if cache.count >= 8 { cache.removeAll() }
            cache[request] = result
        }
        return result
    }
}
