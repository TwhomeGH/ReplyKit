import Foundation
import SwiftUI

/// 進階編碼相容選項；CAVLC 與 VT 速度優先分開，避免一個開關同時改變兩種行為。
struct LegacyEncodingSettingsView: View {
  @AppStorage("BitRateMode", store: userDefaults) private var bitRateMode = 0
  @AppStorage("KeyFrameInterval", store: userDefaults) private var keyFrameInterval = 2
  @AppStorage("allowFrameReordering", store: userDefaults) private var allowFrameReordering = false
  @AppStorage("h264useCAVLC", store: userDefaults) private var h264useCAVLC = false
  @AppStorage("vtSpeedPriority", store: userDefaults) private var vtSpeedPriority = false
  @AppStorage("videoScalingMode", store: userDefaults) private var videoScalingMode = VideoScalingMode.letterbox.rawValue
  @AppStorage("isLowLatencyRateControlEnabled", store: userDefaults)
  private var isLowLatencyRateControlEnabled = false
  @AppStorage("useEnhancedRTMP", store: userDefaults) private var useEnhancedRTMP = true
  @AppStorage("captureBackend", store: userDefaults)
  private var captureBackend = CaptureBackend.replayKit.rawValue

  private let bitRateOptions = ["ABR", "CBR", "VBR"]

  private var usesScreenCaptureKit: Bool {
    CaptureBackend(rawValue: captureBackend) == .screenCaptureKit
  }

  init() {
    let defaults = userDefaults ?? .standard
    // 舊版 CAVLC 開關同時控制 VT 速度優先；升級時保留原本行為，之後可再分開關閉。
    if defaults.object(forKey: "vtSpeedPriority") == nil {
      defaults.set(defaults.bool(forKey: "h264useCAVLC"), forKey: "vtSpeedPriority")
    }
  }

  var body: some View {
    Form {
      Section(AppLanguage.localized("encoding.bitrate.section")) {
        Picker(AppLanguage.localized("encoding.bitrate.mode"), selection: $bitRateMode) {
          ForEach(bitRateOptions.indices, id: \.self) { index in
            Text(bitRateOptions[index]).tag(index)
          }
        }
        .pickerStyle(.segmented)

        HStack {
          Text(AppLanguage.localized("encoding.keyframe"))
          TextField("2", value: $keyFrameInterval, format: .number)
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .frame(width: 80)
          Text(keyFrameInterval == 0
            ? AppLanguage.localized("encoding.keyframe.auto")
            : "\(keyFrameInterval)s")
            .foregroundStyle(.secondary)
            .font(.caption)
        }
        .onChange(of: keyFrameInterval) { value in
          if value < 0 {
            keyFrameInterval = 0
          } else if value > 60 {
            keyFrameInterval = 60
          }
        }
        Text(AppLanguage.localized("encoding.keyframe.help"))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      Section(AppLanguage.localized("encoding.h264.section")) {
        Toggle(isOn: $h264useCAVLC) {
          Text(AppLanguage.localized("encoding.cavlc"))
        }
        Text(AppLanguage.localized("encoding.cavlc.help"))
          .font(.footnote)
          .foregroundStyle(.secondary)

        if usesScreenCaptureKit {
          Text(AppLanguage.localized("encoding.sckBframes"))
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else {
          Toggle(isOn: $allowFrameReordering) {
            Text(AppLanguage.localized("encoding.bframes"))
          }
          Text(AppLanguage.localized("encoding.bframes.help"))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }

      Section(AppLanguage.localized("encoding.vt.section")) {
        Toggle(isOn: $vtSpeedPriority) {
          Text(AppLanguage.localized("encoding.vtSpeed"))
        }
        Text(AppLanguage.localized("encoding.vtSpeed.help"))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      Section(AppLanguage.localized("encoding.scaling.section")) {
        if usesScreenCaptureKit {
          Text(AppLanguage.localized("encoding.scaling.sck"))
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else {
          Picker(AppLanguage.localized("encoding.scaling.section"),
                 selection: $videoScalingMode) {
            ForEach(VideoScalingMode.allCases) { mode in
              Text(AppLanguage.localized("encoding.scaling." + mode.rawValue))
                .tag(mode.rawValue)
            }
          }
          Text(AppLanguage.localized("encoding.scaling." + videoScalingMode + ".help"))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }

      Section(AppLanguage.localized("encoding.rtmp.section")) {
        Toggle(isOn: $isLowLatencyRateControlEnabled) {
          Text(AppLanguage.localized("encoding.lowLatency"))
        }
        Text(AppLanguage.localized("encoding.lowLatency.help"))
          .font(.footnote)
          .foregroundStyle(.secondary)

        Toggle(isOn: $useEnhancedRTMP) {
          Text(AppLanguage.localized("encoding.ertmp"))
        }
        Text(AppLanguage.localized("encoding.ertmp.help"))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .navigationTitle(AppLanguage.localized("settings.category.encoding"))
  }
}
