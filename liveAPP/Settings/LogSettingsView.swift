/// 日誌記錄、除錯與 POST 轉送設定；全域選項由 AppSettingsView 提供。
import Foundation

import SwiftUI

struct LogSettingsView: View {
  @AppStorage("logURL", store: userDefaults) private var logURL = "http://192.168.0.242:3000/post"
  @State private var tempEndpoint = ""
  @State private var testResult: String?
  @State private var isTesting = false
  var body: some View {
    Form {
      LogSettingView()
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

      }
    }
    .navigationTitle(AppLanguage.localized("settings.category.logs"))
    .onAppear { tempEndpoint = logURL }
    .onDisappear {
      let endpoint = tempEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
      guard endpoint != logURL else { return }
      logURL = endpoint
      LPConfig.shared.logURL = endpoint
      CFNotificationCenterPostNotification(
        cfCenter, CFNotificationName("logURL" as CFString), nil, nil, true)
    }
  }

  /// 以目前輸入測試既有日誌 POST 端點，結果回主執行緒顯示。
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
      "time": timeString,
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
