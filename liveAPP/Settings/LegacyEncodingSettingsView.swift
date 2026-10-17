/// 進階編碼相容選項；沿用既有偏好，實際支援依擷取來源決定。
import Foundation

import SwiftUI

struct LegacyEncodingSettingsView: View {
  @AppStorage("BitRateMode", store: userDefaults) private var BitRateMode = 0
  @AppStorage("KeyFrameInterval", store: userDefaults) private var KeyFrameInterval = 2
  @AppStorage("allowFrameReordering", store: userDefaults) private var allowFrameReordering = false
  @AppStorage("h264useCAVLC", store: userDefaults) private var h264useCAVLC: Bool = false
  @AppStorage("isLowLatencyRateControlEnabled", store: userDefaults) private
    var isLowLatencyRateControlEnabled = false
  let BitRateOptions = ["ABR", "CBR", "VBR"]
  var body: some View {
    Form {
      Picker("請選擇一個位元率模式", selection: $BitRateMode) {
        ForEach(0..<BitRateOptions.count, id: \.self) { index in
          Text(BitRateOptions[index]).tag(index)
        }
      }
      .pickerStyle(.segmented)  // 可改成 .menu 看起來像下拉選單

      Text(
        "目前選擇：\(BitRateOptions.indices.contains(BitRateMode) ? BitRateOptions[BitRateMode] : "—")"
      )
      .padding()

      HStack {
        Text("關鍵幀間隔 (秒)")
        TextField("2", value: $KeyFrameInterval, format: .number)
          .textFieldStyle(RoundedBorderTextFieldStyle())
          .frame(width: 80)
        Text("\(KeyFrameInterval == 0 ? "編碼器自動" : "\(KeyFrameInterval)秒")")
          .foregroundColor(.secondary)
          .font(.caption)
      }
      Text("預設 2 秒（Twitch/YouTube/Restream 建議值），0=編碼器自動")
        .font(.footnote)
        .foregroundColor(.secondary)

      Toggle(isOn: $h264useCAVLC) {
        Text("使用輕負載編碼器 CAVLC！ 可用於降低編碼壓力")
      }

      Text("開啟後用CAVLC & 實驗性軟體節流 改善VT過載問題 & 啟用VT編碼速度優先策略")
        .font(.footnote)
        .foregroundColor(.secondary)
        .padding(.bottom, 5)

      Toggle(isOn: $allowFrameReordering) {
        Text("啟用允許B-Frame 此功能存在不穩定性可能破壞穩定性！")
      }

      Text("允許重排 壓縮改善")
        .font(.footnote)
        .foregroundColor(.secondary)
        .padding(.bottom, 5)

      Toggle(isOn: $isLowLatencyRateControlEnabled) {
        Text("啟用低延遲處理！")
      }

      Text("啟用後會對使用低延遲推流")
        .font(.footnote)
        .foregroundColor(.secondary)
        .padding(.bottom, 5)

      Toggle(
        isOn: Binding(
          get: { userDefaults?.bool(forKey: "useEnhancedRTMP") ?? true },
          set: { userDefaults?.set($0, forKey: "useEnhancedRTMP") }
        )
      ) {
        Text("啟用 Enhanced RTMP (E-RTMP)")
      }

      Text("啟用後使用增強型 RTMP 協定，提高傳輸效率")
        .font(.footnote)
        .foregroundColor(.secondary)
        .padding(.bottom, 5)

    }
    .navigationTitle(AppLanguage.localized("settings.category.encoding"))

  }
}
