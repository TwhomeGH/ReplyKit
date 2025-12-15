//
//  Setting.swift
//  liveAPP
//
//  Created by user on 2025/11/1.
//


import SwiftUI

import Foundation

final class GPUSettingsViewModel: ObservableObject {
    @AppStorage("dstW", store: userDefaults) var dstW = 0
    @AppStorage("dstH", store: userDefaults) var dstH = 0
    @AppStorage("useBic", store: userDefaults) var useBic = false
    @AppStorage("MaxInfilght", store: userDefaults) var maxInflightFrames = 4

    @Published var configs: [GPUOutputConfig] = []
    @Published var selectedConfig: GPUOutputConfig? = nil

    init() {
        configs = GPUOutputConfig.load(defaults: [
            GPUOutputConfig(name: "1080p", width: 1552, height: 1080),
            GPUOutputConfig(name: "720p", width: 1034, height: 720),
            GPUOutputConfig(name: "原始大小", width: 0, height: 0)
        ])
        selectedConfig = GPUOutputConfig.loadSelected() ?? configs.first
        dstW = selectedConfig?.width ?? 0
        dstH = selectedConfig?.height ?? 0
    }

    func updateSelectedConfig() {
        if let index = configs.firstIndex(where: { $0.id == selectedConfig?.id }) {
            configs[index].width = dstW
            configs[index].height = dstH
            selectedConfig = configs[index]
            GPUOutputConfig.save(configs)
            GPUOutputConfig.saveSelected(selectedConfig)
        }
    }
}


struct GPURotateView: View {
    @ObservedObject var viewModel: GPUSettingsViewModel
    @FocusState private var isDstWFocused: Bool
    @FocusState private var isDstHFocused: Bool
    @FocusState var isFocusedMax: Bool


    var body: some View {
        Form {
            Section(header: Text("GPU旋轉處理 輸出設置")) {
                Text("輸出寬高 [\(viewModel.dstW) x \(viewModel.dstH)]")
                Text("0代表 使用原始寬高")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 5)

                Picker("選擇配置", selection: $viewModel.selectedConfig) {
                    ForEach(viewModel.configs) { config in
                        Text(config.name).tag(config as GPUOutputConfig?)
                    }
                }
                .onChange(of: viewModel.selectedConfig) { cfg in
                    guard let cfg else { return }
                    viewModel.dstW = cfg.width
                    viewModel.dstH = cfg.height
                    CFNotificationCenterPostNotification(cfCenter, CFNotificationName("OutW" as CFString), nil, nil, true)
                    CFNotificationCenterPostNotification(cfCenter, CFNotificationName("OutH" as CFString), nil, nil, true)

                    GPUOutputConfig.saveSelected(viewModel.selectedConfig)
                }

                Button("新增自訂配置") {
                    let newConfig = GPUOutputConfig(name: "自訂 \(viewModel.configs.count + 1)", width: viewModel.dstW, height: viewModel.dstH)
                    viewModel.configs.append(newConfig)
                    viewModel.selectedConfig = newConfig
                    GPUOutputConfig.save(viewModel.configs)
                    GPUOutputConfig.saveSelected(viewModel.selectedConfig)
                }
                if let index = viewModel.configs.firstIndex(where: { $0.id == viewModel.selectedConfig?.id }) {

                    Button("刪除當前配置: \(viewModel.configs[index].name)") {
                        viewModel.configs.remove(at: index)
                        viewModel.selectedConfig = viewModel.configs.first
                        GPUOutputConfig.save(viewModel.configs)
                        GPUOutputConfig.saveSelected(viewModel.selectedConfig)
                    }.disabled(viewModel.configs.count <= 3)
                    // 如果只剩 3 個，按鈕停用
                }

                TextField("寬度", value: $viewModel.dstW, format: .number)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .focused($isDstWFocused)
                    .onChange(of: isDstWFocused) { focused in
                        if !focused {
                            viewModel.updateSelectedConfig()
                            CFNotificationCenterPostNotification(cfCenter, CFNotificationName("OutW" as CFString), nil, nil, true)
                        }
                    }

                TextField("高度", value: $viewModel.dstH, format: .number)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .focused($isDstHFocused)
                    .onChange(of: isDstHFocused) { focused in
                        if !focused {
                            viewModel.updateSelectedConfig()
                            CFNotificationCenterPostNotification(cfCenter, CFNotificationName("OutH" as CFString), nil, nil, true)
                        }
                    }

                Toggle("使用 Bicubic 插值", isOn: $viewModel.useBic)
                    .onChange(of: viewModel.useBic) { _ in
                        CFNotificationCenterPostNotification(cfCenter, CFNotificationName("useBic" as CFString), nil, nil, true)
                    }

                Text("使用 16 個鄰近像素計算 運算較慢，但細節保留更好，邊緣更平滑，大動態畫面旋轉時不容易出現模糊或鋸齒感。"
                )
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 5)

                TextField("直接輸入數量", value: $viewModel.maxInflightFrames, format: .number)
                    .frame(maxWidth: .infinity)
                     .textFieldStyle(RoundedBorderTextFieldStyle())
                     .keyboardType(.numberPad)
                     .focused($isFocusedMax)
                     .onChange(of: isFocusedMax) { newValue in

                         if newValue {
                             // 將數值發送到 Extension 或 Rotator
                             CFNotificationCenterPostNotification(cfCenter, CFNotificationName("MaxInfilght" as CFString), nil, nil, true)
                         }
                    }

                Stepper("[棄用]同時處理數量：\(viewModel.maxInflightFrames)", value: $viewModel.maxInflightFrames, in: 1...1000)
                    .onChange(of: viewModel.maxInflightFrames) { _ in
                        CFNotificationCenterPostNotification(cfCenter, CFNotificationName("MaxInfilght" as CFString), nil, nil, true)
                    }
            }
        }
        .navigationTitle("GPU輸出設置")

        .onDisappear {
            GPUOutputConfig.save(viewModel.configs)
            GPUOutputConfig.saveSelected(viewModel.selectedConfig)
        }

    }
}

struct LogSettingView:View {

    @AppStorage("onlogPage",store:userDefaults) private var onlogPage = false


    @AppStorage("BacklogTime",store:userDefaults) private var logTime = false

    @AppStorage("Enablelog",store:userDefaults) private var Enablelog = false

    @AppStorage("EnableRotatelog",store:userDefaults) private var EnableRotatelog = false

    @AppStorage("ChangeBit",store:userDefaults) private var ChangeBit = true

    var body: some View {
        Section(header: Text("除錯日誌")) {

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


            Button("測試擴展通信傳遞"){
                AppMessagePort.shared.send(toExtension: ["ping": "From_App"])

                SocketServer.shared?.broadcast(type:"log",key: "test3", value: "OK Socket")

            }


        }

        Section(header: Text("網路")) {
            Toggle(isOn: $ChangeBit){
                Text("停用自動碼率調整策略 ！")
            }
            .onChange(of:ChangeBit) { newValue in
                CFNotificationCenterPostNotification(cfCenter, CFNotificationName("ChangeBit" as CFString), nil, nil, true)
            }
            Text("停用後不管網路狀況做調整")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 5)


        }
    }
}





final class AppMessagePort {
    static let shared = AppMessagePort()

    private var localPort: CFMessagePort?
    private var remotePort: CFMessagePort?

    var endP:CFString?

    var isConnect = false


    private init() {
    }

    func logTo( _ mes:String){
        sendlog(message: "[CFPort] \(mes)")
    }
    func setupReceiver() {
        var context = CFMessagePortContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
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

        endP = CFMessagePortGetName(localPort)


        if let localPort {
            let rl = CFMessagePortCreateRunLoopSource(nil, localPort, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), rl, .defaultMode)
        }

        logTo("Port Add App \(String(describing: endP))")
    }

    func connectToExtension() {

        disconnectFromExt()

        remotePort = CFMessagePortCreateRemote(nil, "group.nuclear.liveAPP.ExtPort" as CFString)

        isConnect = true
        logTo("連接建立到擴展！")
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
        guard
            let remote = remotePort,
            let data = try? JSONSerialization.data(withJSONObject: dict)
        else { return }

        logTo("SendRes")
        CFMessagePortSendRequest(
            remote,
            99,                    // message id
            data as CFData,
            1,
            1,
            nil,
            nil
        )

       
    }
}


