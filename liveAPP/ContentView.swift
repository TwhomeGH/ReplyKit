import ReplayKit
import SwiftUI
import Combine
import os
import Foundation

/// 分頁與頂層生命週期入口；各功能狀態由原本擁有者管理。
struct ContentView: View {

    @Environment(\.scenePhase) private var scenePhase


    @EnvironmentObject var logModel: LogModel

    @StateObject private var pageState = PageState()

    @AppStorage("BacklogTime",store:userDefaults) private var logTime = false

    @AppStorage("onlogPage",store:userDefaults) private var onlogPage = false


    @AppStorage("onAudioPage",store:userDefaults) private var onAudioPage = false



    var body: some View {

        TabView(selection: $pageState.currentPage) {

            homeView()
                .tabItem { Label("tab.home", systemImage: "gear") }
                .tag(AppPage.home)



            DeviceView()
                .tabItem { Label("tab.deviceInfo", systemImage: "cpu") }
                .tag(AppPage.testpage)

            LogView()
                .environmentObject(logModel)
                .tabItem { Label("tab.logs", systemImage: "apple.terminal") }
                .tag(AppPage.log)

            LiveVolumeView()
                .environmentObject(pageState)
                .tabItem { Label("tab.volume", systemImage: "speaker.wave.2.circle.fill") }
                .tag(AppPage.audio)

            PIPView().tabItem { Label("tab.chat", systemImage: "pip.enter") }
                .tag(AppPage.PIPChat)

            TTSSettingsView()
                .tabItem { Label("tab.tts", systemImage: "speaker.wave.2") }
                .tag(AppPage.tts)

            VideoBitrateView()
                .tabItem { Label("tab.bitrate", systemImage: "chart.bar.xaxis") }
                .tag(AppPage.videoBitrate)

        }
        .onChange(of: pageState.currentPage) { newValue in
            sendlog(message:"Page:\(newValue)")

            if newValue == .log {
                pageState.onlogPage = true
                onlogPage = true
                LPConfig.shared.onLogPage = true
                CFNotificationCenterPostNotification(cfCenter, CFNotificationName("onlogPage" as CFString), nil, nil, true)
            } else if !logTime {
                pageState.onlogPage = false
                onlogPage = false
                LPConfig.shared.onLogPage = false
                CFNotificationCenterPostNotification(cfCenter, CFNotificationName("onlogPage" as CFString), nil, nil, true)
            }

            if newValue == .audio {
                pageState.onAudioPage = true
                onAudioPage = true
                sendlog(message:"onAudioPage: \(onAudioPage)")
                SocketServer.shared.broadcastPushState(key: "onAudioPage", value: true)
            } else {
                pageState.onAudioPage = false
                onAudioPage = false
                sendlog(message:"onAudioPage: \(onAudioPage)")
                SocketServer.shared.broadcastPushState(key: "onAudioPage", value: false)
            }
        }


        .onChange(of: scenePhase ){
                newPhase in

            switch newPhase {
            case .active:

                SocketServer.shared.ensureRunning()

                if pageState.onlogPage {
                    if onlogPage == false {
                        onlogPage=true

                        CFNotificationCenterPostNotification(cfCenter, CFNotificationName("onlogPage" as CFString), nil, nil, true)

                    }
                }

                sendlog(message: "正在App中！")



                if pageState.onAudioPage {
                    if onAudioPage == false {
                        onAudioPage=true

                        SocketServer.shared.broadcastPushState(key: "onAudioPage", value: true)

                        sendlog(message: "正在App AudioPage")
                    }
                }


            case .background:



                if onlogPage == true {



                    if logTime {

                        sendlog(message: "應用已進入後台App 仍保持更新logPage")


                    } else {

                        sendlog(message: "應用已進入後台App 停止更新logPage")

                        onlogPage=false


                        CFNotificationCenterPostNotification(cfCenter, CFNotificationName("onlogPage" as CFString), nil, nil, true)

                    }


                }

                if onAudioPage == true {
                    onAudioPage=false

                    SocketServer.shared.broadcastPushState(key: "onAudioPage", value: false)

                    sendlog(message: "應用已進入後台App 停止監聽AudioPage")

                }

            case .inactive:

                sendlog(message: "正在離開App")


            @unknown default:
                sendlog(message:"後台未知狀態 不處理")
            }
        }



    }
}

#Preview {
    ContentView()
}
