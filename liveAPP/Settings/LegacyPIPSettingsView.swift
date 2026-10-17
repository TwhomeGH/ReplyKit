/// 舊版 PiP 字體與動畫設定；保留既有偏好及即時套用回呼。
import Foundation

import SwiftUI

struct LegacyPIPSettingsView: View {
  @AppStorage("fadeAlpha", store: userDefaults) private var fadeAlpha = 0.08
  @AppStorage("fadeTime", store: userDefaults) private var fadeTime = 0.5
  @AppStorage("scrollTime", store: userDefaults) private var scrollTime = 0.2
  @AppStorage("PIPFontMain", store: userDefaults) private var PIPFontMain = 14.0
  @AppStorage("PIPFontSecond", store: userDefaults) private var PIPFontSecond = 10.0
  @AppStorage("PIPAdOverlayFont", store: userDefaults) private var PIPAdOverlayFont = 13.0
  @AppStorage("PIPAdOverlayUserFont", store: userDefaults) private var PIPAdOverlayUserFont = 14.0
  @AppStorage("PIPAdOverlaySpacing", store: userDefaults) private var PIPAdOverlaySpacing = 4.5
  @AppStorage("PIPAdOverlayDuration", store: userDefaults) private var PIPAdOverlayDuration = 5.0
  var body: some View {
    Form {
      Section(header: Text("settings.pipLegacy.section")) {

        // MARK: 主要訊息

        TextField(
          "主訊息文字與圖片大小 直接輸入大小 14",
          value: $PIPFontMain,
          format: .number
        )
        .frame(maxWidth: .infinity)
        .textFieldStyle(RoundedBorderTextFieldStyle())
        .keyboardType(.numberPad)

        .onChange(of: PIPFontMain) { newVal in

          logTo("主訊息文字與圖片大小 -> \(newVal) ")
          LPConfig.shared.PIPChatFontMainSize = newVal

        }

        Stepper(
          "主訊息文字與圖片大小：\(PIPFontMain)",
          value: $PIPFontMain,
          in: 0...100,
          step: 0.1

        )

        Text(
          "建議值: 14.0"
        )
        .font(.footnote)
        .foregroundColor(.secondary)
        .padding(.bottom, 5)

        // MARK: 次要訊息
        TextField(
          "次要訊息文字與圖片大小 直接輸入大小 10",
          value: $PIPFontSecond,
          format: .number
        )
        .frame(maxWidth: .infinity)
        .textFieldStyle(RoundedBorderTextFieldStyle())
        .keyboardType(.numberPad)

        Stepper(
          "次要訊息文字大小：\(PIPFontSecond)",
          value: $PIPFontSecond,
          in: 0...100,
          step: 0.1

        )
        .onChange(of: PIPFontSecond) { newVal in

          logTo("Second FontSize -> \(newVal) ")
          LPConfig.shared.PIPChatFontSecondSize = newVal

        }

        Text(
          "建議值: 10.0"
        )
        .font(.footnote)
        .foregroundColor(.secondary)
        .padding(.bottom, 5)

        // MARK: Ad Overlay Font
        TextField(
          "廣告覆著字體大小 直接輸入大小 13",
          value: $PIPAdOverlayFont,
          format: .number
        )
        .frame(maxWidth: .infinity)
        .textFieldStyle(RoundedBorderTextFieldStyle())
        .keyboardType(.numberPad)

        Stepper(
          "廣告覆著字體大小：\(PIPAdOverlayFont)",
          value: $PIPAdOverlayFont,
          in: 1...100,
          step: 0.1
        )
        .onChange(of: PIPAdOverlayFont) { newVal in
          LPConfig.shared.PIPAdOverlayFontSize = newVal
        }

        Text("建議值: 13.0")
          .font(.footnote)
          .foregroundColor(.secondary)
          .padding(.bottom, 5)

        // MARK: Ad Overlay User Font
        TextField(
          "贊助者字體大小 直接輸入大小 11",
          value: $PIPAdOverlayUserFont,
          format: .number
        )
        .frame(maxWidth: .infinity)
        .textFieldStyle(RoundedBorderTextFieldStyle())
        .keyboardType(.numberPad)

        Stepper(
          "贊助者字體大小：\(PIPAdOverlayUserFont)",
          value: $PIPAdOverlayUserFont,
          in: 1...100,
          step: 0.1
        )
        .onChange(of: PIPAdOverlayUserFont) { newVal in
          LPConfig.shared.PIPAdOverlayUserFontSize = newVal
        }

        Text("建議值: 14.0")
          .font(.footnote)
          .foregroundColor(.secondary)
          .padding(.bottom, 5)

        // MARK: Ad Overlay Spacing
        TextField(
          "贊助者與內文間距 直接輸入大小 2",
          value: $PIPAdOverlaySpacing,
          format: .number
        )
        .frame(maxWidth: .infinity)
        .textFieldStyle(RoundedBorderTextFieldStyle())
        .keyboardType(.numberPad)

        Stepper(
          "贊助者與內文間距：\(PIPAdOverlaySpacing)",
          value: $PIPAdOverlaySpacing,
          in: 0...50,
          step: 0.5
        )
        .onChange(of: PIPAdOverlaySpacing) { newVal in
          LPConfig.shared.PIPAdOverlaySpacing = newVal
        }

        Text("建議值: 4.5")
          .font(.footnote)
          .foregroundColor(.secondary)
          .padding(.bottom, 5)

        // MARK: Ad Overlay Duration
        TextField(
          "廣告覆著停留秒數 直接輸入 5",
          value: $PIPAdOverlayDuration,
          format: .number
        )
        .frame(maxWidth: .infinity)
        .textFieldStyle(RoundedBorderTextFieldStyle())
        .keyboardType(.numberPad)

        Stepper(
          "廣告覆著停留秒數：\(PIPAdOverlayDuration)",
          value: $PIPAdOverlayDuration,
          in: 1...60,
          step: 0.5
        )
        .onChange(of: PIPAdOverlayDuration) { newVal in
          LPConfig.shared.PIPAdOverlayDuration = newVal
        }

        Text("建議值: 5.0")
          .font(.footnote)
          .foregroundColor(.secondary)
          .padding(.bottom, 5)

        // MARK: FadeSpeed
        TextField(
          "淡出速度 數值越高淡出越快 0.08",
          value: $fadeAlpha,
          format: .number
        )
        .frame(maxWidth: .infinity)
        .textFieldStyle(RoundedBorderTextFieldStyle())
        .keyboardType(.numberPad)

        Stepper(
          "訊息淡出速度：\(String(format: "%.2f", fadeAlpha))",
          value: $fadeAlpha,
          in: 0...100,
          step: 0.01

        )
        .onChange(of: fadeAlpha) { newVal in

          logTo("FadeSpeedAlpha -> \(newVal) ")
          LPConfig.shared.FadeAlpha = newVal

        }

        Text(
          "建議值: 0.1"
        )
        .font(.footnote)
        .foregroundColor(.secondary)
        .padding(.bottom, 5)

        // MARK: FadeTime

        TextField(
          "淡出時間間隔 直接輸入時長 1.0",
          value: $fadeTime,
          format: .number
        )
        .frame(maxWidth: .infinity)
        .textFieldStyle(RoundedBorderTextFieldStyle())
        .keyboardType(.numberPad)

        Stepper(
          "訊息淡出時間間隔：\(String(format: "%.2f", fadeTime))",
          value: $fadeTime,
          in: 0...100,
          step: 0.1

        )
        .onChange(of: fadeTime) { newVal in

          logTo("FadeTime -> \(newVal) ")
          LPConfig.shared.MessageFadeTime = newVal
          PIPService.shared.fadeTime(newVal)

        }

        Text(
          "建議值: 0.5 秒"
        )
        .font(.footnote)
        .foregroundColor(.secondary)
        .padding(.bottom, 5)

        // 滾動時長
        TextField(
          "滾動時長 直接輸入時長 1.0",
          value: $scrollTime,
          format: .number
        )
        .frame(maxWidth: .infinity)
        .textFieldStyle(RoundedBorderTextFieldStyle())
        .keyboardType(.numberPad)

        Stepper(
          "滾動時間：\(String(format: "%.2f", scrollTime))",
          value: $scrollTime,
          in: 0...100,
          step: 0.1

        )
        .onChange(of: scrollTime) { newVal in

          logTo("scrollTime -> \(newVal) ")
          LPConfig.shared.ScrollTime = newVal
          PIPService.shared.scrollTime(newVal)

        }

        Text(
          "建議值: 0.2 秒"
        )
        .font(.footnote)
        .foregroundColor(.secondary)
        .padding(.bottom, 5)

      }
    }
    .navigationTitle(AppLanguage.localized("settings.pipLegacy.section"))

  }
}
