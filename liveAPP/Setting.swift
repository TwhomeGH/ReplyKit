//
//  Setting.swift
//  liveAPP
//
//  Created by user on 2025/11/1.
//


import SwiftUI

import Foundation
import Network

final class GPUSettingsViewModel: ObservableObject {

    static let shared = GPUSettingsViewModel()

    @AppStorage("profileName", store: userDefaults) var displayName = ""

    @AppStorage("dstW", store: userDefaults) var dstW = 0
    @AppStorage("dstH", store: userDefaults) var dstH = 0

    @AppStorage("odstW", store: userDefaults) var odstW = 0
    @AppStorage("odstH", store: userDefaults) var odstH = 0

    @AppStorage("RotateOriginal",store:userDefaults) var RotateOriginal = false

    @AppStorage("BufferCount", store: userDefaults) var BufferCount = -1

    @AppStorage(
        "Rotate",
        store: userDefaults
    ) var RotateRawValue:Int = RotateDirection.landscapeRight.rawValue



    @Published var configs: [GPUOutputConfig] = []

    @Published var selectedConfig: GPUOutputConfig? = nil
    @Published var selectedConfigID: UUID?



    let defaultConfigs: [GPUOutputConfig] = [
        GPUOutputConfig(name: "原始大小", width: 0, height: 0),
        GPUOutputConfig(
            name: "1080p 16:9 [1728x1201]",
            width: 1728,
            height: 1201,
            owidth: 1920,
            oheight: 1080
        ),
        GPUOutputConfig(
            name: "1080p 16:9 [1555x1080]",
            width: 1555,
            height: 1080,
            owidth: 1920,
            oheight: 1080
        ),
        GPUOutputConfig(
            name: "1080p 16:9",
            width: 1552,
            height: 1080,
            owidth: 1920,
            oheight: 1080
        ),
        GPUOutputConfig(
            name: "720p 16:9",
            width: 1034,
            height: 720,
            owidth: 1280,
            oheight: 720
        ),

        GPUOutputConfig(name: "1080p", width: 1552, height: 1080),
        GPUOutputConfig(name: "720p", width: 1034, height: 720)

    ]


    func applyRotate(_ rotate: RotateDirection) {
        guard let cfg = selectedConfig else { return }

        cfg.Rotate = rotate

        logTo("Rotate->\(rotate)")
        CFNotificationCenterPostNotification(
            cfCenter,
            CFNotificationName("Rotate" as CFString),
            nil, nil, true
        )

        GPUOutputConfig.save(configs)
        GPUOutputConfig.saveSelected(selectedConfig)
    }


    func applyConfig(id: UUID) {
        guard let cfg = configs.first(where: { $0.id == id }) else { return }

        selectedConfig = cfg

        if displayName != cfg.name {
            displayName = cfg.name
        }
        if dstW != cfg.width {
            dstW = cfg.width
        }
        if dstH != cfg.height {
            dstH = cfg.height
        }

        if odstW != cfg.owidth {
            odstW = cfg.owidth
        }

        if odstH != cfg.oheight {
            odstH = cfg.oheight

        }

        if RotateOriginal != cfg.originonly {
            RotateOriginal = cfg.originonly
        }
        if RotateRawValue != cfg.Rotate.rawValue {
            RotateRawValue = cfg.Rotate.rawValue

        }

        CFNotificationCenterPostNotification(cfCenter, CFNotificationName("OutW" as CFString), nil, nil, true)
        CFNotificationCenterPostNotification(cfCenter, CFNotificationName("OutH" as CFString), nil, nil, true)

        GPUOutputConfig.save(configs)
        GPUOutputConfig.saveSelected(selectedConfig)
    }

    func rebuildDefaultsIfMissing() {


        for defaultCfg in defaultConfigs {
            // 如果 configs 沒有同名的預設配置，就加入
            if !configs.contains(where: { $0.name == defaultCfg.name }) {
                configs.append(defaultCfg)
            }
        }

        // 排序：先按照 defaultConfigs 的順序，後面接用戶自訂的
            configs.sort { a, b in
                let aIndex = defaultConfigs.firstIndex(where: { $0.name == a.name }) ?? Int.max
                let bIndex = defaultConfigs.firstIndex(where: { $0.name == b.name }) ?? Int.max
                return aIndex < bIndex
            }


    }



    init() {
        configs = GPUOutputConfig.load(
            defaults: defaultConfigs
        )

        selectedConfig = GPUOutputConfig.loadSelected() ?? configs.first

        selectedConfigID = selectedConfig?.id


        let selName = selectedConfig?.name ?? "None"

        if displayName != selName {
            displayName = selName
        }

        let selW = selectedConfig?.width ?? 0

        if dstW != selW {
            dstW = selW

        }

        let selH = selectedConfig?.height ?? 0

        if dstH != selH {
            dstH = selH
        }

        let oselW = selectedConfig?.owidth ?? 0

        if odstW != oselW {
            odstW = oselW

        }

        let oselH = selectedConfig?.oheight ?? 0

        if odstH != oselH {
            odstH = oselH
        }

        


        let selOrigin = selectedConfig?.originonly ?? false

        if RotateOriginal != selOrigin {
            RotateOriginal = selOrigin
        }


        let selRotate = selectedConfig?.Rotate ?? RotateDirection.landscapeRight

        if RotateRawValue != selRotate.rawValue {
            RotateRawValue = selRotate.rawValue
        }

    }


}



struct GPURotateView: View {
    @ObservedObject var viewModel: GPUSettingsViewModel
    @AppStorage("useBic",store:userDefaults) private var useBic = false


    var body: some View {
        Form {
            Section(header: Text("gpu.output.section")) {


                Picker(
                    String(localized: "gpu.config.select"),
                    selection:$viewModel.selectedConfigID
                ) {
                    ForEach(viewModel.configs) { config in
                        Text(config.name).tag(config.id)
                    }
                }.onChange(of: viewModel.selectedConfigID) { newID in
                    guard let id = newID else { return }
                    viewModel.applyConfig(id: id)
                }



                Button("gpu.config.addCustom") {
                    let newConfig = GPUOutputConfig(name: "\(AppLanguage.localized("gpu.config.customName")) \(viewModel.configs.count + 1)", width: viewModel.dstW, height: viewModel.dstH)

                    viewModel.configs.append(newConfig)
                    viewModel.selectedConfig = newConfig

                    GPUOutputConfig.save(viewModel.configs)
                    GPUOutputConfig.saveSelected(viewModel.selectedConfig)
                }
                if let index = viewModel.configs.firstIndex(where: { $0.id == viewModel.selectedConfig?.id }) {

                    Button("\(AppLanguage.localized("gpu.config.deleteCurrent")): \(viewModel.configs[index].name)") {
                        viewModel.configs.remove(at: index)
                        viewModel.selectedConfig = viewModel.configs.last

                        GPUOutputConfig.save(viewModel.configs)
                        GPUOutputConfig.saveSelected(viewModel.selectedConfig)

                    }.disabled(
                        viewModel.configs.count <= 1
                    )
                    // 如果只剩 3 個，按鈕停用
                }

                Button("gpu.config.rebuildDefaults") {
                    viewModel.rebuildDefaultsIfMissing()
                }


                Text("\(AppLanguage.localized("gpu.canvas.outputSize")) [\(viewModel.odstW) x \(viewModel.odstH)]")
                Text("gpu.canvas.zeroUsesGpuSize")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 5)


                Text("\(AppLanguage.localized("gpu.processing.size")) [\(viewModel.dstW) x \(viewModel.dstH)]")
                Text("gpu.processing.zeroUsesOriginal")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 5)



                Text("gpu.config.name")

                TextField(
                    AppLanguage.localized("gpu.config.namePlaceholder"),
                    text: $viewModel.displayName
                )
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: viewModel.displayName) { newVal in

                        if let index = viewModel.configs.firstIndex(
                            where: { $0.id == viewModel.selectedConfig?.id
                            }) {
                        viewModel.configs[index].name = newVal
                    }

                    viewModel.selectedConfig?.name = newVal
                    GPUOutputConfig.save(viewModel.configs)

                }


                HStack(spacing: 20) {


                    Picker(
                        AppLanguage.localized("gpu.rotate.selectDirection"),
                        selection:$viewModel.RotateRawValue
                    ) {
                        ForEach(RotateDirection.allCases) { direction in
                            Text(direction.description).tag(direction)
                        }

                    }.onChange(of: viewModel.RotateRawValue) { newRotate in
                        viewModel
                            .applyRotate(
                                RotateDirection(
                                    rawValue: newRotate
                                ) ?? .landscapeRight
                            )
                    }


                    // 假設 ipad.landscape 本身是 90°，我們要扣掉這個 90°
                    let baseOffset: Double = 90

                    // 圖示
                        Image(systemName: "ipad.landscape") // 基礎箭頭
                            .rotationEffect(
                                Angle(
                                degrees:
                                    Double(
                                        viewModel.selectedConfig?.Rotate.rawValue ?? 0
                                    ) - baseOffset
                                )
                            )
                            .font(.title) // 大小可調整
                            .animation(.easeInOut, value: viewModel.selectedConfig?.Rotate.rawValue)


                }


                Toggle(isOn:$viewModel.RotateOriginal){
                    Text("gpu.rotate.outputOnly")
                }.onChange(of:viewModel.RotateOriginal) { newVal in
                    viewModel.selectedConfig?.originonly = newVal
                    logTo("只改輸出寬高->\(newVal)")
                }

                Text("gpu.rotate.outputOnlyHint")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 5)


                Text("gpu.canvas.width")

                TextField(AppLanguage.localized("gpu.canvas.width"), value: $viewModel.odstW, format: .number)
                  .textFieldStyle(RoundedBorderTextFieldStyle())
                  .onChange(of: viewModel.odstW) { newVal in

                      if let index = viewModel.configs.firstIndex(
                          where: { $0.id == viewModel.selectedConfig?.id
                          }) {
                          viewModel.configs[index].owidth = newVal
                     }

                      viewModel.selectedConfig?.owidth = newVal

                      CFNotificationCenterPostNotification(cfCenter, CFNotificationName("OutW" as CFString), nil, nil, true)

                      GPUOutputConfig.save(viewModel.configs)

                  }

                Text("gpu.canvas.height")

                TextField(AppLanguage.localized("gpu.canvas.height"), value: $viewModel.odstH, format: .number)
                  .textFieldStyle(RoundedBorderTextFieldStyle())

                  .onChange(of: viewModel.odstH) { newVal in

                      if let index = viewModel.configs.firstIndex(
                          where: { $0.id == viewModel.selectedConfig?.id
                          }) {
                          viewModel.configs[index].oheight = newVal
                      }

                      viewModel.selectedConfig?.oheight = newVal

                      CFNotificationCenterPostNotification(cfCenter, CFNotificationName("OutH" as CFString), nil, nil, true)


                      GPUOutputConfig.save(viewModel.configs)

                  }



                Text("gpu.processing.width")

                TextField(AppLanguage.localized("gpu.processing.width"), value: $viewModel.dstW, format: .number)
                  .textFieldStyle(RoundedBorderTextFieldStyle())

                  .onChange(of: viewModel.dstW) { newVal in

                      if let index = viewModel.configs.firstIndex(
                          where: { $0.id == viewModel.selectedConfig?.id
                          }) {
                          viewModel.configs[index].width = newVal
                      }

                      viewModel.selectedConfig?.width = newVal

                      CFNotificationCenterPostNotification(cfCenter, CFNotificationName("OutW" as CFString), nil, nil, true)

                  }


                Text("gpu.processing.height")

                TextField(AppLanguage.localized("gpu.processing.height"), value: $viewModel.dstH, format: .number)
                  .textFieldStyle(RoundedBorderTextFieldStyle())

                  .onChange(of: viewModel.dstH) { newVal in

                      if let index = viewModel.configs.firstIndex(
                          where: { $0.id == viewModel.selectedConfig?.id
                          }) {
                          viewModel.configs[index].height = newVal
                  }

                      viewModel.selectedConfig?.height = newVal

                      CFNotificationCenterPostNotification(cfCenter, CFNotificationName("OutH" as CFString), nil, nil, true)

                  }




                TextField(
                    AppLanguage.localized("gpu.buffer.placeholder"),
                    value: $viewModel.BufferCount,
                    format: .number
                )
                    .frame(maxWidth: .infinity)
                     .textFieldStyle(RoundedBorderTextFieldStyle())
                     .keyboardType(.numberPad)

                     .onChange(of: viewModel.BufferCount) { _ in

                             // 將數值發送到 Extension 或 Rotator
                             CFNotificationCenterPostNotification(cfCenter, CFNotificationName("MaxInfilght" as CFString), nil, nil, true)

                    }

                Stepper(
                    "\(AppLanguage.localized("gpu.buffer.count")): \(viewModel.BufferCount == -1 ? AppLanguage.localized("common.auto") : "\(viewModel.BufferCount)")",
                    value: $viewModel.BufferCount,
                    in: -1...100
                )
                    .onChange(of: viewModel.BufferCount) { _ in

                        logTo("VBuffer -> \(viewModel.BufferCount) ")

                    }

                Text("gpu.buffer.recommendation"
                )
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 5)

                Toggle(isOn:$useBic){
                    Text("gpu.bicubic.enable")
                }
                Text("gpu.bicubic.description"
                )
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 5)
                Text("gpu.bilinear.description"
                )
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 5)



            }
        }
        .navigationTitle(String(localized: "settings.gpu.title"))

        .onDisappear {
            GPUOutputConfig.save(viewModel.configs)
            GPUOutputConfig.saveSelected(viewModel.selectedConfig)
        }

    }
}


struct AudioSettingsView:View {
    @AppStorage(StreamAudioBitrate.storageKey, store: userDefaults) private var streamAudioBitrate = StreamAudioBitrate.automatic.rawValue

    @AppStorage("isOringinAudio",store:userDefaults)  private var isOringinAudio = true

    @AppStorage("enableNoiseFix",store:userDefaults) private var enableNoiseFix = false
    @AppStorage("enableEchoFix",store:userDefaults) private var enableEchoFix = false
    @AppStorage("enableAGCFix",store:userDefaults) private var enableAGCFix = false
    @AppStorage("enableMetalAudio",store:userDefaults) private var enableMetalAudio = false


    var body: some View {
        Form {
            Section(header: Text(AppLanguage.localized("audio.bitrate.title"))) {
                Picker(AppLanguage.localized("audio.bitrate.title"), selection: $streamAudioBitrate) {
                    ForEach(StreamAudioBitrate.allCases) { option in
                        Text(AppLanguage.localized(option.titleKey)).tag(option.rawValue)
                    }
                }
                Text(AppLanguage.localized("audio.bitrate.help"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section(header: Text("settings.audio.title")) {
            
                Toggle(isOn:$isOringinAudio){
                                Text("audio.original.enable")
                            }

                Text("audio.original.description")
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.bottom, 5)

                Toggle(isOn:$enableNoiseFix){
                    Text("audio.noiseReduction.enable")
                }

                Text("audio.noiseReduction.description")
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.bottom, 5)

                Toggle(isOn:$enableEchoFix){
                    Text("audio.echoCancellation.enable")
                }

                Text("audio.echoCancellation.description")
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.bottom, 5)

                Toggle(isOn:$enableAGCFix){
                    Text("audio.agc.enable")
                }

                Text("audio.agc.description")
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.bottom, 5)

                Toggle(isOn:$enableMetalAudio){
                    Text("audio.metalNoise.enable")
                }

                Text("audio.metalNoise.description")
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.bottom, 5)


                Text("common.comingSoon")


            }
        }.navigationTitle(String(localized: "settings.audio.title"))
    }
    
}

// MARK: PIP日誌設置
struct PIPSettingsView: View {
    @AppStorage("PIPLog",store:userDefaults) private var PIPLog = false
    @AppStorage("PIPChatLog",store:userDefaults) private var PIPChatLog = false
    @AppStorage("PIPLayoutLog",store:userDefaults) private var PIPLayoutLog = false
    @AppStorage("PIPFrameLog",store:userDefaults) private var PIPFrameLog = false


    var body: some View {
        Form {
            Toggle(isOn: $PIPLog){
                Text("pipLog.pip.enable")
            }.onChange(of:PIPLog) { newValue in
                logger.debug("PIPLog:\(newValue)")
                LPConfig.shared.PIPLog = newValue
            }

            Text("pipLog.pip.description")
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.bottom, 5)

            Toggle(isOn: $PIPChatLog){
                Text("pipLog.chat.enable")
            }.onChange(of:PIPChatLog) { newValue in
                logger.debug("PIPChatLog:\(newValue)")
                LPConfig.shared.PIPChatLog = newValue
            }

            Text("pipLog.chat.description")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 5)


            Toggle(isOn: $PIPLayoutLog){
                Text("pipLog.layout.enable")
            }.onChange(of:PIPLayoutLog) { newValue in
                logger.debug("PIPLayoutLog:\(newValue)")
                sendlog(message: "PIPLayoutLog:\(newValue)")
            }

            Toggle(isOn: $PIPFrameLog){
                Text("pipLog.frame.enable")
            }.onChange(of:PIPFrameLog) { newValue in
                logger.debug("PIPFrameLog:\(newValue)")
                sendlog(message: "PIPFrameLog:\(newValue)")
            }


        }
        .navigationTitle(String(localized: "settings.pipLog.title"))
    }
    
}


struct LogSettingView:View {

    @AppStorage("onlogPage",store:userDefaults) private var onlogPage = false



        
    @AppStorage("BacklogTime",store:userDefaults) private var logTime = false

    @AppStorage("Enablelog",store:userDefaults) private var Enablelog = false
    @AppStorage("EnableRotatelog",store:userDefaults) private var EnableRotatelog = false
    @AppStorage("EnableSocketlog",store:userDefaults) private var EnableSocketlog = false
    @AppStorage("EnableTimeDebug",store:userDefaults) private var EnableTimeDebug = false
    @AppStorage("EnablePipelineLog",store:userDefaults) private var EnablePipelineLog = false









    




    




    var body: some View {
        Section(header: Text("logSettings.debug.section")) {

            Toggle(isOn: $Enablelog){
                Text("啟用調試用日誌 ！")
            }.onChange(of:Enablelog) { newValue in
                CFNotificationCenterPostNotification(cfCenter, CFNotificationName("Enablelog" as CFString), nil, nil, true)
            }



            Text("啟用日誌後, 會依用戶選擇App內顯示或外部服務器顯示 ，用於除錯或排查問題。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 5)


            Toggle(isOn: $logTime){
                Text("停用非日誌頁面頻率調整 ！")
            }.onChange(of: logTime ) { newValue in


                if newValue {
                    sendlog(message: "停用非日誌頁調整")
                    onlogPage = true

                } else {
                    sendlog(message: "啟用非日誌頁調整")
                    onlogPage = false

                }

                    CFNotificationCenterPostNotification(cfCenter, CFNotificationName("onlogPage" as CFString), nil, nil, true)



            }

            Text("啟用後 進入後台或非日誌頁不會發生日誌暫停")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 5)

            

            Toggle(isOn: Binding(
                get: { userDefaults?.bool(forKey: "enableRTMPLog") ?? false },
                set: { userDefaults?.set($0, forKey: "enableRTMPLog") }
            )){
                Text("啟用 RTMP 內部日誌")
            }

            Text("顯示 RTMP 連線層的內部事件日誌，便於排查連線問題")
            .font(.footnote)
            .foregroundColor(.secondary)
            .padding(.bottom, 5)

            Toggle(isOn: $EnableRotatelog){
                Text("啟用畫面旋轉調試日誌 ！")
            }
            .onChange(of:EnableRotatelog) { newValue in
                CFNotificationCenterPostNotification(cfCenter, CFNotificationName("DebugRotate" as CFString), nil, nil, true)
            }

            Text("啟用後顯示, 關於畫面GPU旋轉處理情況")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 5)


            Toggle(isOn: $EnableTimeDebug){
                Text("啟用畫面旋轉時間軸信息 ！")
            }
            .onChange(of:EnableTimeDebug) { newValue in
                CFNotificationCenterPostNotification(cfCenter, CFNotificationName("DebugTime" as CFString), nil, nil, true)
            }
            Text("啟用後顯示, 關於畫面GPU旋轉處理時間軸延遲")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 5)

            Toggle(isOn: $EnablePipelineLog){
                Text("啟用管線調試日誌 ！")
            }
            .onChange(of:EnablePipelineLog) { newValue in
                CFNotificationCenterPostNotification(cfCenter, CFNotificationName("DebugPipeline" as CFString), nil, nil, true)
            }
            Text("啟用後顯示, 視頻/音頻幀流動日誌")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 5)

            if LPConfig.isSideload {
                HStack {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.orange)
                    Text("🔒 側載模式：Socket 日誌強制啟用")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                }
                Text("側載下無 App Group，日誌透過 Socket 轉送，可在檔案 App 查看 Documents/log.txt")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 5)
            } else {
                Toggle(isOn: $EnableSocketlog){
                    Text("啟用Socket轉送日誌 ！")
                }
                .onChange(of:EnableSocketlog) { newValue in

                    if newValue {
                        sendlog(message: "停用監聽日誌文件 已使用Socket轉送")
                        SharedResources.shared.releaseLogReceiver()

                    } else {

                        sendlog(message: "啟用監聽日誌文件 已停用Socket轉送")
                        SharedResources.shared.setupLogReceiver()

                    }

                    LPConfig.shared.SocketLog = newValue

                    SocketServer.shared.broadcast(type:"log",key: "Rebuild Socket", value: "OK Socket")

                    CFNotificationCenterPostNotification(cfCenter, CFNotificationName("SocketLog" as CFString), nil, nil, true)
                }

                Text("啟用備用Socket顯示傳遞日誌,當你處於側載時使用它代替AppGroup更新共享文件")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 5)
            }

        }



    }
}




enum PortState {
    case stopped
    case listening
    case broken
}

final class AppMessagePort {
    static let shared = AppMessagePort()

    private var localPort: CFMessagePort?
    private var remotePort: CFMessagePort?

    private(set) var state: PortState = .stopped

    var endP:CFString?

    var isConnect = false


    private init() {
    }

    func logTo( _ mes:String){
        sendlog(message: "[CFPort] \(mes)")
    }
    func teardown() {

        if let lp = localPort {
            CFMessagePortInvalidate(lp)
            localPort = nil
        }

        if let rp = remotePort {
            CFMessagePortInvalidate(rp)
            remotePort = nil
        }

        endP = nil
        isConnect = false
        state = .stopped

        logTo("🧹 CFMessagePort 已完全停用")
    }

    func setupReceiver() {

        teardown() // 先清乾淨，避免殘留


        var context = CFMessagePortContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
            retain: { info in
                let unmanaged = Unmanaged<AppMessagePort>.fromOpaque(info!)
                _ = unmanaged.retain()
                return info
            },
            release: { info in
                Unmanaged<AppMessagePort>.fromOpaque(info!).release()
            },
            copyDescription: nil
        )


        let callback: CFMessagePortCallBack = { port, msgid, cfData, info -> Unmanaged<CFData>? in
            if let data = cfData as Data?,
               let obj = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
               let str = String(data: pretty, encoding: .utf8) {

                AppMessagePort.shared.logTo("📨 來自 Extension:\n\(str)")

                if !AppMessagePort.shared.isConnect {
                    AppMessagePort.shared.connectToExtension()
                }

            } else {
                AppMessagePort.shared.logTo("📨 來自 Extension: <無法解析>")
            }
            return nil
        }


        localPort = CFMessagePortCreateLocal(nil,
                                             "group.nuclear.liveAPP.AppPort" as CFString,
                                             callback,
                                             &context,
                                             nil)

        if let lp = localPort {
            endP = CFMessagePortGetName(lp)
            state = .listening
        } else {
            endP = nil
            state = .broken
            logTo("❌ localPort 建立失敗（App Group / 權限 / 名稱衝突）")
        }

        if let localPort {
            let rl = CFMessagePortCreateRunLoopSource(nil, localPort, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), rl, .defaultMode)
        }

        logTo("Port Add App \(String(describing: endP))")
    }

    func connectToExtension() {

        disconnectFromExt()

        remotePort = CFMessagePortCreateRemote(nil, "group.nuclear.liveAPP.ExtPort" as CFString)

        if remotePort != nil {
            isConnect = true
            logTo("連接建立到擴展！")
        } else {
            isConnect = false
            logTo("❌ 無法建立到擴展 Port")
        }

    }

    func disconnectFromExt() {
        if remotePort != nil {

            CFMessagePortInvalidate(remotePort)
            remotePort = nil

            isConnect = false
            logTo("擃展連接已取消")
        }
    }

    // 發送訊息到 extension
    func send(toExtension dict: [String: Any]) {

        guard state == .listening else {
                logTo("⚠️ IPC 未啟動，忽略送出")
                return
            }

        guard
            let remote = remotePort,
            let data = try? JSONSerialization.data(withJSONObject: dict)
        else { return }

        logTo("SendRes")

        let status = CFMessagePortSendRequest(
            remote,
            99,
            data as CFData,
            1,
            1,
            nil,
            nil
        )

        if status != kCFMessagePortSuccess {
            logTo("❌ SendRequest 失敗 \(status)")
            disconnectFromExt() // 或 teardown，看需求
        }

       
    }
}






final class LocalNetworkPermissionManager: ObservableObject {
    private var browser: NWBrowser?

    var status : String = ""

    func requestPermission(completion: @escaping (Bool) -> Void) {

        
        let params = NWParameters.tcp
        params.includePeerToPeer = true

        let descriptor = NWBrowser.Descriptor.bonjour(
            type: "_http._tcp",
            domain: ""  
        )

        let browser = NWBrowser(for: descriptor, using: params)
        self.browser = browser

        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                browser.cancel()
                self.status = "✅ Local network permission granted"

                completion(true)

            case .failed(let error):
                self.status = "❌ Browser failed:\(error)"
                browser.cancel()

                completion(false)


            default:
                break
            }


        }

        browser.start(queue: .main)
      

    }

}
