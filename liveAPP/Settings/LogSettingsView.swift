import ReplayKit
import SwiftUI
import Combine
import os
import Foundation

/// 日誌與顯示設定頁；本批只拆檔，內部分區留待後續整理。
struct LogSettingsView: View {
    @AppStorage("logURL", store: userDefaults) private var logURL = "http://192.168.0.242:3000/post"
    @AppStorage("AppLanguage", store: userDefaults) private var appLanguageRawValue = AppLanguage.system.rawValue
    @Environment(\.dismiss) private var dismiss

    @State private var tempEndpoint = ""
    @State private var testResult: String?
    @State private var isTesting = false


    @ObservedObject private var gpuSettings = GPUSettingsViewModel.shared

    @AppStorage("fadeAlpha", store: userDefaults) private var fadeAlpha = 0.08

    @AppStorage("fadeTime", store: userDefaults) private var fadeTime = 0.5

    @AppStorage("scrollTime", store: userDefaults) private var scrollTime = 0.2

    @AppStorage("PIPFontMain", store: userDefaults) private var PIPFontMain = 14.0
    @AppStorage("PIPFontSecond", store: userDefaults) private var PIPFontSecond = 10.0
    @AppStorage("PIPAdOverlayFont", store: userDefaults) private var PIPAdOverlayFont = 13.0
    @AppStorage("PIPAdOverlayUserFont", store: userDefaults) private var PIPAdOverlayUserFont = 14.0
    @AppStorage("PIPAdOverlaySpacing", store: userDefaults) private var PIPAdOverlaySpacing = 4.5
    @AppStorage("PIPAdOverlayDuration", store: userDefaults) private var PIPAdOverlayDuration = 5.0

    @AppStorage("broadcastExtension", store: userDefaults) private var broadcastExtension = (Bundle.main.bundleIdentifier ?? "nuclear.liveAPP") + ".ReplyKIT"


    var body: some View {
        NavigationView {
            Form {

                LogSettingView()

                NavigationLink("關於與建置資訊") {
                    AboutBuildView()
                }

                NavigationLink("Socket 連線") {
                    SocketConnectionSettingsView()
                }

                Section(header: Text("appLanguage.section")) {
                    Picker("appLanguage.picker", selection: $appLanguageRawValue) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(LocalizedStringKey(language.titleKey)).tag(language.rawValue)
                        }
                    }
                    Text("appLanguage.restartHint")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                NavigationLink("settings.audio.title") {
                    AudioSettingsView()
                }

                NavigationLink("settings.pipLog.title") {
                    PIPSettingsView()
                }

                NavigationLink("settings.pipLayout.title") {
                    PIPLayoutSettingsView()
                }

                NavigationLink("settings.outputOverlay.title") {
                    OverlaySettingsView()
                }

                NavigationLink("settings.gpu.title") {
                    GPURotateView(viewModel: gpuSettings)
                }


                Section(header: Text("settings.broadcastExtension.section")) {
                    TextField((Bundle.main.bundleIdentifier ?? "nuclear.liveAPP") + ".ReplyKIT", text: $broadcastExtension)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.caption)
                    Text("settings.broadcastExtension.restartNote")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("settings.apiEndpoint.section")) {
                    TextField("https://example.com/api/logs", text: $tempEndpoint)
                        .keyboardType(.URL)
                        .autocapitalization(.none)

                    Button("settings.apiEndpoint.testConnection") {
                        testResult = nil
                        isTesting = true
                        testConnection(to: tempEndpoint)
                    }
                    .disabled(tempEndpoint.trimmingCharacters(in: .whitespaces).isEmpty)

                    if let result = testResult {
                        Text(result)
                            .foregroundColor(result.contains("成功") ? .green : .red)
                    }

                    Button("settings.apiEndpoint.fetchVideoOutput") {
                        CFNotificationCenterPostNotification(cfCenter, CFNotificationName("VideoSet" as CFString), nil, nil, true)
                    }
                }


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
                        step:0.1

                    )


                    Text("建議值: 14.0"
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
                        step:0.1

                    )
                    .onChange(of: PIPFontSecond) { newVal in



                        logTo("Second FontSize -> \(newVal) ")
                        LPConfig.shared.PIPChatFontSecondSize = newVal




                        }

                    Text("建議值: 10.0"
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
                        step:0.1
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
                        step:0.1
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
                        step:0.5
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
                        step:0.5
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

                    Text("建議值: 0.1"
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

                    Text("建議值: 0.5 秒"
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

                    Text("建議值: 0.2 秒"
                    )
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(.bottom, 5)

                }



            }
            .navigationTitle("settings.main.title")
            .onAppear {
                tempEndpoint = logURL
            }
            .onDisappear {

                logURL = tempEndpoint.trimmingCharacters(in: .whitespaces)

                logger.debug("logURL:\(logURL)")

                LPConfig.shared.logURL = logURL


                CFNotificationCenterPostNotification(cfCenter, CFNotificationName("logURL" as CFString), nil, nil, true)


            }

        }
    }

    private func testConnection(to urlString: String) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)) else {
            testResult = "❌ 無效的 URL 格式"
            isTesting = false
            return
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        formatter.locale = Locale.current

        let now = Date()
        let timeString = formatter.string(from: now)


        let payload: [String: Any] = [
            "title": "測試日誌連線",
            "body": "這是一筆測試資料，用於驗證 POST JSON 是否成功",
            "time": timeString
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            testResult = "❌ 無法建立 JSON 資料"
            isTesting = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                isTesting = false
                if let error = error {
                    testResult = "❌ 測試失敗：\(error.localizedDescription)"
                } else if let httpResponse = response as? HTTPURLResponse {
                    if (200...299).contains(httpResponse.statusCode) {
                        testResult = "✅ 測試成功（狀態碼 \(httpResponse.statusCode)）"
                    } else {
                        testResult = "⚠️ 伺服器回應：\(httpResponse.statusCode)"
                    }
                } else {
                    testResult = "❌ 未知的回應格式"
                }
            }
        }.resume()
    }

}
