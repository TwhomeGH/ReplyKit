import ReplayKit
import SwiftUI
import Combine
import os
import Foundation

/// 主頁狀態與響應式排版入口；卡片見 HomeView_Cards.swift。
/// 保留型別名稱與 property wrapper 所有權，避免改變視圖生命週期。
@MainActor struct homeView:View{
#if os(iOS)
    /// 沿用 App 共用擷取協調器；畫面只觀察，不自行建立擷取服務。
    @ObservedObject var capture = CaptureCoordinator.shared
    @AppStorage("captureBackend", store: userDefaults) var captureBackend = CaptureBackend.replayKit.rawValue
    @AppStorage("captureWorkMode", store: userDefaults) var captureWorkMode = CaptureWorkMode.stream.rawValue
#endif
    @Environment(\.scenePhase) private var scenePhase

    @State var showAlert = false
    @State var showLocalAlert = false

    @State var micStatus = "未知狀態"

    @AppStorage("logAppBackground",store:userDefaults) private var logAppBackground = false


    @AppStorage("rtmpURL",store: userDefaults) var rtmpURL: String = ""
    @AppStorage("rtmpKey",store: userDefaults) var rtmpKey: String = ""
    @AppStorage("broadcastExtension",store: userDefaults) var broadcastExtension: String = (Bundle.main.bundleIdentifier ?? "nuclear.liveAPP") + ".ReplyKIT"

    @State private var streamBtn = BroadcastButton(
        rtmpURL: "rtmp://192.168.0.102/live",
        rtmpKey: "stream1?vhost=live2"
    )

    /// 由主頁持有的碼率模型；拆分卡片不改變其建立次數。
    @StateObject var manager = BitrateManager()

    var StreamBtn: BroadcastButton {
        streamBtn
    }

    // iOS BroadcastButton - 透過 computed property StreamBtn 在 body 中建立
#if os(iOS)
    // （StreamBtn 為 computed property，見上方）
#endif
    // macOS BroadcastButton
#if os(macOS)
    @StateObject var StreamBtnMac = BroadcastButtonMac.Coordinator()
#endif





#if os(iOS)
    /// 查詢或請求麥克風權限，結果更新主頁提示狀態。
    func checkMicrophonePermission() {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            micStatus = "已允許麥克風 ✅"
            showAlert = true
        case .denied:
            micStatus = "麥克風被拒絕 ❌，請到設定開啟"
            showAlert = true
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    micStatus = granted ? "已允許麥克風 ✅" : "拒絕麥克風 ❌"
                    showAlert = true
                }
            }
        @unknown default:
            micStatus = "未知狀態"
            showAlert = true
        }
    }
#else
    /// 查詢或請求麥克風權限，結果更新主頁提示狀態。
    func checkMicrophonePermission() {
        print("notmake")
    }



#endif



    @State var lockDetect=false


    @State var showForm = false
    @AppStorage("PauseStream",store: userDefaults) var PauseStream: Bool = false

    @StateObject var permissionManager = LocalNetworkPermissionManager()




    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 目前是否選用 ScreenCaptureKit；其他平台維持既有後備路徑。
    var usesScreenCaptureKit: Bool {
#if os(iOS)
        captureBackend == CaptureBackend.screenCaptureKit.rawValue
#else
        false
#endif
    }

    /// 僅本地錄製時隱藏 RTMP 設定，不清除保存值。
    var needsStreamingSettings: Bool {
#if os(iOS)
        !usesScreenCaptureKit || (CaptureWorkMode(rawValue: captureWorkMode) ?? .stream).wantsStreaming
#else
        true
#endif
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("松鼠推流").font(.largeTitle.bold())
                    if geometry.size.width >= 850 && !dynamicTypeSize.isAccessibilitySize {
                        HStack(alignment: .top, spacing: 20) {
                            captureCard.frame(width: max(0, (min(geometry.size.width, 1200) - 52) / 2), alignment: .topLeading)
                            settingsCards.frame(width: max(0, (min(geometry.size.width, 1200) - 52) / 2), alignment: .topLeading)
                        }
                    } else {
                        captureCard
                        settingsCards
                    }
                }
                .padding(16)
                .frame(width: min(geometry.size.width, 1200), alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
                .transaction { $0.animation = nil }
            }
        }
        .sheet(isPresented: $showForm) { FormView() }
    }

}
