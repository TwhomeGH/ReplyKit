import Testing
import VideoToolbox
@testable import liveAPP

/// 舊偏好與系統能力清單的回歸測試；不依賴模擬器的硬體編碼器。
struct H264EncodingProfileTests {
    @Test func legacyProfilesKeepProfileAndUseAutomaticLevel() {
        for (legacy, automatic) in [("Baseline", "AutoBaseline"), ("Main", "AutoMain"), ("High", "AutoHigh")] {
            #expect(H264EncodingProfile.resolve(legacy) == H264EncodingProfile.resolve(automatic))
            #expect(H264EncodingProfile.resolve(legacy).hasSuffix("AutoLevel"))
        }
        #expect(H264EncodingProfile.resolve("High") == kVTProfileLevel_H264_High_AutoLevel as String)
    }

    @Test func explicitLevelIsPreservedAndInvalidLegacyValueFallsBack() {
        let explicit = kVTProfileLevel_H264_High_4_2 as String
        #expect(H264EncodingProfile.resolve(explicit) == explicit)
        #expect(H264EncodingProfile.resolve("invalid") == kVTProfileLevel_H264_Main_AutoLevel as String)
        #expect(H264EncodingProfile.resolve("HEVC_Main_AutoLevel") == kVTProfileLevel_H264_Main_AutoLevel as String)
    }

    @Test func capabilitiesNeverInventMissingOptions() {
        #expect(H264EncodingProfile.supportedValues([]).isEmpty)
        let high = kVTProfileLevel_H264_High_AutoLevel as String
        #expect(H264EncodingProfile.supportedValues([high, high, "HEVC_Main_AutoLevel"]) == [high])
    }

    @Test func invalidDimensionsFailBeforeCreatingEncoder() async {
        let result = await H264EncoderCapabilities.shared.query(.init(width: Int.max, height: 1080, lowLatency: false))
        #expect(result.values.isEmpty)
        #expect(result.stage == "dimensions")
        #expect(result.status == kVTParameterErr)
    }
}
