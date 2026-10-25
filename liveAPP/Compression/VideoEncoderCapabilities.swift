import Foundation
import VideoToolbox

/// 以系統登錄的編碼器清單回答硬體編碼能力。
/// 只讀登錄資料，不建立編碼 session，因此不與擷取排他鎖互動，也不影響進行中的擷取。
enum VideoEncoderCapabilities {
    /// 系統回報具硬體加速的編碼格式；程序的執行期內不變，故只列舉一次。
    /// nil 表示無法讀取清單，能力未知，呼叫端應保留選項。
    private static let hardwareCodecs: Set<CMVideoCodecType>? = {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr,
              let encoders = list as? [[String: Any]] else { return nil }
        var codecs: Set<CMVideoCodecType> = []
        for encoder in encoders {
            guard let codec = encoder[kVTVideoEncoderList_CodecType as String] as? Int else { continue }
            // 缺少硬體欄位時無法判定，沿用「登錄即可用」以免誤藏可用選項。
            if let hardware = encoder[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool,
               !hardware { continue }
            codecs.insert(CMVideoCodecType(truncatingIfNeeded: codec))
        }
        return codecs
    }()

    /// 查詢指定格式是否有硬體編碼器；清單不可讀時不預先隱藏，實際寫入階段仍會再驗證。
    static func isHardwareEncodeSupported(_ codec: CMVideoCodecType) -> Bool {
        hardwareCodecs?.contains(codec) ?? true
    }
}
