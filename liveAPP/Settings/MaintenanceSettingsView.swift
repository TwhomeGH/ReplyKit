/// 手動連線與直播計時器維護；操作由使用者明確點擊觸發。
import Foundation

import SwiftUI

struct MaintenanceSettingsView: View {
  @ObservedObject private var socket = SocketServer.shared
  @AppStorage("ChangeBit", store: userDefaults) private var ChangeBit = true
  var body: some View {
    Form {
      Section(header: Text("logSettings.liveTimer.section")) {

        Button("重新開始直播計時器") {
          sendlog(message: "直播開始計時器重啟")
          SocketServer.shared.StreamStarting()

        }

        Text("當直播計時器出現異常無法正常運行時可以用這個重啟它")
          .font(.footnote)
          .foregroundColor(.secondary)
          .padding(.bottom, 5)

        Button("停止直播計時器 直播結束") {
          sendlog(message: "直播結束 計時器停止")
          SocketServer.shared.StreamStatusChanged(isLive: false)

        }

        Text("當直播結束時可以用這個停止計時器")
          .font(.footnote)
          .foregroundColor(.secondary)
          .padding(.bottom, 5)

      }

      Section(header: Text("logSettings.network.section")) {

        Button("測試擴展通信傳遞") {
          // 未來計畫棄用 已經用Socket轉送處理了
          //AppMessagePort.shared.send(toExtension: ["ping": "From_App"])

          socket.broadcast(type: "log", key: "test3", value: "OK Socket")
          socket.broadcast(type: "testRTMP", key: "test3", value: "OK")

        }
        Button("Socket重連") {
          CFNotificationCenterPostNotification(
            cfCenter, CFNotificationName("SocketRetry" as CFString), nil, nil, true)

        }

        Text("如果通信斷線了可以用這個重建")
          .font(.footnote)
          .foregroundColor(.secondary)
          .padding(.bottom, 5)

        Button("Socket服務器重啟") {
          socket.stop()
          socket.start()

        }
        Text("如果擴展初始連不上可以用他重啟服務端")
          .font(.footnote)
          .foregroundColor(.secondary)
          .padding(.bottom, 5)

        Text("Socket 狀態：\(socket.listenerStatus)")

        Button("Socket服務器停止") {
          socket.stop()
        }

        Toggle(isOn: $ChangeBit) {
          Text("[棄用]停用自動碼率調整策略 ！")
        }
        .onChange(of: ChangeBit) { newValue in
          CFNotificationCenterPostNotification(
            cfCenter, CFNotificationName("ChangeBit" as CFString), nil, nil, true)
        }
        Text("停用後不管網路狀況做調整")
          .font(.footnote)
          .foregroundColor(.secondary)
          .padding(.bottom, 5)

      }

      Button("settings.apiEndpoint.fetchVideoOutput") {
        CFNotificationCenterPostNotification(
          cfCenter, CFNotificationName("VideoSet" as CFString), nil, nil, true)
      }
    }
    .navigationTitle(AppLanguage.localized("settings.category.maintenance"))

  }
}
