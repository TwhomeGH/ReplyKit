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
    @AppStorage("dstW", store: userDefaults) var dstW = 0
    @AppStorage("dstH", store: userDefaults) var dstH = 0
    @AppStorage("BufferCount", store: userDefaults) var BufferCount = 5

    @AppStorage(
        "Rotate",
        store: userDefaults
    ) var RotateRawValue:Int = RotateDirection.landscapeRight.rawValue

    var Rotate: RotateDirection {
        get { RotateDirection(rawValue: RotateRawValue) ?? .landscapeRight }
        set { RotateRawValue = newValue.rawValue }
    }

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
        Rotate = selectedConfig?.Rotate ?? RotateDirection.landscapeRight

    }

    func updateSelectedConfig() {
        if let index = configs.firstIndex(where: { $0.id == selectedConfig?.id }) {
            configs[index].width = dstW
            configs[index].height = dstH
            configs[index].Rotate = Rotate

            selectedConfig = configs[index]
            GPUOutputConfig.save(configs)
            GPUOutputConfig.saveSelected(selectedConfig)
        }
    }
}


struct GPURotateView: View {
    @ObservedObject var viewModel: GPUSettingsViewModel


    @AppStorage("useBic",store:userDefaults) private var useBic = false

    @AppStorage("RotateOriginal",store:userDefaults) private var RotateOriginal = false


    var body: some View {
        Form {
            Section(header: Text("GPU旋轉處理 輸出設置")) {
                Toggle(isOn:$RotateOriginal){
                    Text("只改輸出寬高[畫布本身]")
                }
                Text("開啟後GPU旋轉處理 會忽視寬高設定按原始")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 5)

                Text("輸出寬高 [\(viewModel.dstW) x \(viewModel.dstH)]")
                Text("0代表 使用原始寬高")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 5)

                HStack(spacing: 20) {


                    Picker("選擇方向", selection: Binding(
                        get: { viewModel.selectedConfig?.Rotate ?? .landscapeRight },
                        set: { newRotate in
                            guard var cfg = viewModel.selectedConfig else { return }

                            cfg.Rotate = newRotate

                            logTo("Rotate->\(cfg.Rotate)")

                            viewModel.Rotate = newRotate
                            viewModel.updateSelectedConfig()

                            GPUOutputConfig.saveSelected(viewModel.selectedConfig)


                            CFNotificationCenterPostNotification(cfCenter, CFNotificationName("Rotate" as CFString), nil, nil, true)

                        }
                    )) {
                        ForEach(RotateDirection.allCases) { direction in
                            Text(direction.description).tag(direction)
                        }
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

                Picker("選擇配置", selection: $viewModel.selectedConfig) {
                    ForEach(viewModel.configs) { config in
                        Text(config.name).tag(config as GPUOutputConfig?)
                    }
                }
                .onChange(of: viewModel.selectedConfig) { cfg in
                    guard let cfg else { return }
                    viewModel.dstW = cfg.width
                    viewModel.dstH = cfg.height
                    viewModel.Rotate = cfg.Rotate

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

                    .onChange(of: viewModel.dstW) { _ in

                            viewModel.updateSelectedConfig()
                            CFNotificationCenterPostNotification(cfCenter, CFNotificationName("OutW" as CFString), nil, nil, true)

                    }

                TextField("高度", value: $viewModel.dstH, format: .number)
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                    .onChange(of: viewModel.dstH) { _ in

                            viewModel.updateSelectedConfig()
                            CFNotificationCenterPostNotification(cfCenter, CFNotificationName("OutH" as CFString), nil, nil, true)

                    }

               

                TextField(
                    "直接輸入數量",
                    value: $viewModel.BufferCount,
                    format: .number
                )
                    .frame(maxWidth: .infinity)
                     .textFieldStyle(RoundedBorderTextFieldStyle())
                     .keyboardType(.numberPad)

                     .onChange(of: viewModel.dstW) { _ in

                             // 將數值發送到 Extension 或 Rotator
                             CFNotificationCenterPostNotification(cfCenter, CFNotificationName("MaxInfilght" as CFString), nil, nil, true)

                    }

                Stepper(
                    "輸入緩衝區數量：\(viewModel.BufferCount)",
                    value: $viewModel.BufferCount,
                    in: 1...100
                )
                    .onChange(of: viewModel.BufferCount) { _ in

                        logTo("VBuffer -> \(viewModel.BufferCount) ")

                    }

                Text("建議值: 5或3 太大可能爆內存"
                )
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 5)

                Toggle(isOn:$useBic){
                    Text("啟用Bicubic")
                }
                Text("雙三次插值算法經常用於圖像或者影片的縮放，它能比占主導地位的雙線性濾波算法保留更好的細節品質"
                )
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 5)
                Text("預設使用：雙線性內插值算法放大後的圖像質量較高，不會出現像素值不連續的的情況。然而此算法具有低通濾波器的性質，使高頻分量受損，所以可能會使圖像輪廓在一定程度上變得模糊"
                )
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 5)



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

    @AppStorage("PIPLog",store:userDefaults) private var PIPLog = false

    @AppStorage("PIPChatLog",store:userDefaults) private var PIPChatLog = false


    @AppStorage("BacklogTime",store:userDefaults) private var logTime = false

    @AppStorage("Enablelog",store:userDefaults) private var Enablelog = false

    @AppStorage("EnableRotatelog",store:userDefaults) private var EnableRotatelog = false

    @AppStorage("EnableSocketlog",store:userDefaults) private var EnableSocketlog = false


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


            Toggle(isOn: $PIPLog){
                Text("啟用PIP子母窗口調試用日誌 ！")
            }.onChange(of:PIPLog) { newValue in
                logger.debug("PIPLog:\(newValue)")
                LPConfig.shared.PIPLog = newValue
            }

            Text("啟用後顯示, 關於PIP畫面情況")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 5)

            Toggle(isOn: $PIPChatLog){
                Text("啟用PIP子母窗口 訊息處理 調試日誌 ！")
            }.onChange(of:PIPChatLog) { newValue in
                logger.debug("PIPChatLog:\(newValue)")
                LPConfig.shared.PIPChatLog = newValue
            }

            Text("啟用後顯示, 關於PIP訊息處理動畫日誌")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 5)


            Button("測試擴展通信傳遞"){
                AppMessagePort.shared.send(toExtension: ["ping": "From_App"])

                SocketServer.shared
                    .broadcast(type:"log",key: "test3", value: "OK Socket")
                SocketServer.shared.broadcast(type: "testRTMP", key: "test3", value: "OK")

            }
            Button("Socket重連"){
                CFNotificationCenterPostNotification(cfCenter, CFNotificationName("SocketRetry" as CFString), nil, nil, true)

            }
            Text("如果通信斷線了可以用這個重建")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 5)



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
            domain: "localhost"
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
