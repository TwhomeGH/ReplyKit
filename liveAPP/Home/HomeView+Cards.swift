import ReplayKit
import SwiftUI
import Combine
import os
import Foundation

/// 主頁卡片組合；狀態仍由 homeView 持有，不建立額外服務。
extension homeView {
    /// 擷取來源與開始操作；保留 Socket ready 檢查及原本廣播按鈕位置。
    var captureCard: some View {
        GroupBox(AppLanguage.localized("home.capture")) {
            VStack(alignment: .leading, spacing: 16) {
#if os(iOS)
                    CaptureSelectionView()
                    StreamBtn.frame(width: 1,height: 1).opacity(0.001)
                    Button(action: {



                        guard !capture.isBusy else { return }
                        if captureBackend == CaptureBackend.screenCaptureKit.rawValue {
                            capture.startScreenCapture(url: rtmpURL, key: rtmpKey, mode: CaptureWorkMode(rawValue: captureWorkMode) ?? .stream)
                            return
                        }
                        Task {
                            let ready = await SocketServer.shared.prepareForBroadcastAndWaitReady()
                            guard ready else {
                                sendlog(title: "BroadcastButton", message: "SocketServer listener not ready, cancel broadcast trigger")
                                return
                            }
                            await MainActor.run {
                                guard !capture.isBusy else { return }
                                BroadcastButton.Coordinator.trigger()
                            }
                        }
                    }) {
                        Text(captureBackend == CaptureBackend.screenCaptureKit.rawValue ? AppLanguage.localized("capture.start." + (CaptureWorkMode(rawValue: captureWorkMode) ?? .stream).rawValue) : AppLanguage.localized("capture.start.stream"))
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.blue)
                            .cornerRadius(8)
                    }
                    .disabled(capture.isBusy)
                    .padding(.horizontal)

#endif

#if os(macOS)
                    BroadcastButtonMac( coordinator: StreamBtnMac)


                    Button(action: {
                        StreamBtnMac.rtmpURL = rtmpURL
                        StreamBtnMac.rtmpKey = rtmpKey

                    }) {
                        Text(AppLanguage.localized("capture.start.stream"))
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.green)
                            .cornerRadius(8)
                    }
                    .padding(.horizontal)
#endif

            }
            .padding(.vertical, 8)
        }
    }

    /// 組合串流、編碼、ReplayKit 操作及權限卡片，讀寫主頁的既有狀態。
    var settingsCards: some View {
        VStack(alignment: .leading, spacing: 16) {
            if needsStreamingSettings {
                GroupBox(AppLanguage.localized("home.streaming")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(rtmpURL.isEmpty ? AppLanguage.localized("home.noEndpoint") : rtmpURL)
                            .font(.subheadline)
                            .privacySensitive()
                            .textSelection(.enabled)
                        Label(rtmpKey.isEmpty ? AppLanguage.localized("home.noKey") : AppLanguage.localized("home.keySet"), systemImage: "key")
                            .foregroundStyle(.secondary)
                        Button(AppLanguage.localized("home.editEndpoint")) { showForm = true }
                            .buttonStyle(.bordered)
                        Divider()
                        bitrateControls
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
                GroupBox {
                    DisclosureGroup(AppLanguage.localized("home.encoding")) {
                        if usesScreenCaptureKit {
                            Text(AppLanguage.localized("home.fixedCodec"))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                            Picker("編碼格式", selection: $videoCodec) {
                                Text("H264").tag("H264")
                                Text("HEVC").tag("HEVC")
                            }
                            .pickerStyle(.segmented)

                            if videoCodec == "H264" {
                                Picker("H264配置", selection: selectedProfile) {
                                    ForEach(H264Profile.allCases) { profile in
                                        Text(profile.rawValue).tag(profile)
                                    }
                                }
                                .pickerStyle(.menu)
                                Text("當前選擇:  \(selectedProfile.wrappedValue.rawValue)")
                            } else {
                                Picker("HEVC配置", selection: selectedHEVCProfile) {
                                    ForEach(HEVCProfile.allCases) { profile in
                                        Text(profile.rawValue).tag(profile)
                                    }
                                }
                                .pickerStyle(.menu)
                                Text("當前選擇: HEVC \(selectedHEVCProfile.wrappedValue.rawValue)")
                            }
                            }.padding(.top, 8)
                        }
                    }
                }
            }
            if !usesScreenCaptureKit {
                GroupBox {
                    DisclosureGroup(AppLanguage.localized("home.replayControls")) {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(AppLanguage.localized("home.pause"), isOn: $PauseStream)
                                .onChange(of: PauseStream) { paused in
                                    notifyReplayKit(paused ? "PauseStream" : "ResumeStream")
                                }
                                .onAppear { if PauseStream { notifyReplayKit("PauseStream") } }
                            HStack {
                                Text(AppLanguage.localized("home.direction"))
                                Spacer()
                                Button(AppLanguage.localized("home.landscape")) { notifyReplayKit("orientationV") }
                                Button(AppLanguage.localized("home.portrait")) { notifyReplayKit("orientationH") }
                            }
#if os(iOS)
                            Toggle(AppLanguage.localized("home.lockDetection"), isOn: $lockDetect)
                                .onChange(of: lockDetect) { enabled in
                                    if enabled {
                                        StableLockRotationDetector.shared.debugMode = true
                                        StableLockRotationDetector.shared.startMonitoring()
                                    } else {
                                        StableLockRotationDetector.shared.stopMonitoring()
                                    }
                                }
#endif
                        }.padding(.top, 8)
                    }
                }
            }
            GroupBox {
                DisclosureGroup(AppLanguage.localized("home.permissions")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Button(AppLanguage.localized("home.networkPermission")) {
                            permissionManager.requestPermission { _ in showLocalAlert = true }
                        }
                        .alert(isPresented: $showLocalAlert) {
                            Alert(title: Text("本地網路權限"), message: Text(permissionManager.status), dismissButton: .default(Text("好")))
                        }
                        Button(AppLanguage.localized("home.micPermission")) { checkMicrophonePermission() }
                            .alert(isPresented: $showAlert) {
                                Alert(title: Text("麥克風權限"), message: Text(micStatus), dismissButton: .default(Text("好")))
                            }
                    }.padding(.top, 8)
                }
            }
        }
    }

    /// 碼率滑桿結束編輯時才保存並通知，維持原本更新頻率。
    private var bitrateControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(AppLanguage.localized("home.bitrate"))：\(manager.multiplier * 100) kbps").font(.headline)
            Slider(value: Binding(
                get: { Double(manager.multiplier) },
                set: { manager.setMultiplier($0) }
            ), in: 10...200, step: 1) { editing in
                if !editing {
                    manager.updateStreamBitrate()
                }
            }
            .accessibilityLabel(AppLanguage.localized("home.bitrate"))
            HStack {
                Text("1000 kbps")
                Spacer()
                Text("20000 kbps")
            }.font(.caption).foregroundStyle(.secondary)
            if usesScreenCaptureKit {
                Text(AppLanguage.localized("home.nextStart"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// 傳送既有 Darwin 事件名稱，不重建推流或 Socket。
    private func notifyReplayKit(_ name: String) {
        CFNotificationCenterPostNotification(cfCenter, CFNotificationName(name as CFString), nil, nil, true)
    }


}
