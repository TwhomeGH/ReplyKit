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

    @AppStorage("profileName", store: userDefaults) var displayName = ""

    @AppStorage("dstW", store: userDefaults) var dstW = 0
    @AppStorage("dstH", store: userDefaults) var dstH = 0

    @AppStorage("odstW", store: userDefaults) var odstW = 0
    @AppStorage("odstH", store: userDefaults) var odstH = 0

    @AppStorage("RotateOriginal",store:userDefaults) var RotateOriginal = false

    @AppStorage("BufferCount", store: userDefaults) var BufferCount = 5

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

        if odstH != cfg.owidth {
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
            Section(header: Text("輸出設置")) {


                Picker(
                    "選擇配置",
                    selection:$viewModel.selectedConfigID
                ) {
                    ForEach(viewModel.configs) { config in
                        Text(config.name).tag(config.id)
                    }
                }.onChange(of: viewModel.selectedConfigID) { newID in
                    guard let id = newID else { return }
                    viewModel.applyConfig(id: id)
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
                        viewModel.selectedConfig = viewModel.configs.last

                        GPUOutputConfig.save(viewModel.configs)
                        GPUOutputConfig.saveSelected(viewModel.selectedConfig)

                    }.disabled(
                        viewModel.configs.count <= 1
                    )
                    // 如果只剩 3 個，按鈕停用
                }

                Button("重建預設配置") {
                    viewModel.rebuildDefaultsIfMissing()
                }


                Text("畫布輸出寬高 [\(viewModel.odstW) x \(viewModel.odstH)]")
                Text("0代表 以GPU輸出寬高為準")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 5)


                Text("GPU輸出寬高 [\(viewModel.dstW) x \(viewModel.dstH)]")
                Text("0代表 使用原始寬高")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 5)



                Text("配置名稱")

                TextField(
                    "配置名稱 可以重新設定",
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
                        "選擇方向",
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
                    Text("只改輸出寬高[畫布本身]")
                }.onChange(of:viewModel.RotateOriginal) { newVal in
                    viewModel.selectedConfig?.originonly = newVal
                    logTo("只改輸出寬高->\(newVal)")
                }

                Text("開啟後GPU旋轉處理 會忽視寬高設定按原始大小")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 5)


                Text("畫布輸出寬度")

                TextField("畫布寬度", value: $viewModel.odstW, format: .number)
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

                Text("畫布輸出高度")

                TextField("畫布高度", value: $viewModel.odstH, format: .number)
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



                Text("GPU輸出寬度")

                TextField("寬度", value: $viewModel.dstW, format: .number)
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


                Text("GPU輸出高度")

                TextField("高度", value: $viewModel.dstH, format: .number)
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
                    "直接輸入數量",
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


struct AudioSettingsView:View {

    @AppStorage("isOringinAudio",store:userDefaults)  private var isOringinAudio = true

    @AppStorage("enableNoiseFix",store:userDefaults) private var enableNoiseFix = false
    @AppStorage("enableEchoFix",store:userDefaults) private var enableEchoFix = false
    @AppStorage("enableAGCFix",store:userDefaults) private var enableAGCFix = false
    @AppStorage("enableMetalAudio",store:userDefaults) private var enableMetalAudio = false


    var body: some View {
        Form {
            Section(header: Text("音訊設置")) {
            
                Toggle(isOn:$isOringinAudio){
                                Text("啟用原味音訊處理！")
                            }

                Text("啟用後忽視音訊處理 直接原封不動送進去")                                                                                                     
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.bottom, 5)

                Toggle(isOn:$enableNoiseFix){
                    Text("啟用降噪功能！")
                }

                Text("啟用後會對音訊進行降噪處理，減少背景噪聲，提升語音清晰度 頻譜減法去除")                                                                                                     
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.bottom, 5)

                Toggle(isOn:$enableEchoFix){
                    Text("啟用回音消除功能！")
                }

                Text("啟用後會對音訊進行回音處理，減少應用音量重疊")                                                                                                     
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.bottom, 5)

                Toggle(isOn:$enableAGCFix){
                    Text("啟用自動音量調整功能！")
                }

                Text("啟用後會對音訊進行自動大小增益")                                                                                                     
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.bottom, 5)

                Toggle(isOn:$enableMetalAudio){
                    Text("啟用 Metal 加速降噪！")
                }

                Text("使用 GPU 加速降噪處理，降低 CPU 使用率，僅在啟用降噪時生效")                                                                                                     
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.bottom, 5)


                Text("敬請期待！")


            }
        }.navigationTitle("音訊設置")
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


            Toggle(isOn: $PIPLayoutLog){
                Text("啟用PIP子母窗口 佈局調試日誌 ！")
            }.onChange(of:PIPLayoutLog) { newValue in
                logger.debug("PIPLayoutLog:\(newValue)")
                sendlog(message: "PIPLayoutLog:\(newValue)")
            }

            Toggle(isOn: $PIPFrameLog){
                Text("啟用PIP子母窗口 畫面幀調試日誌 ！")
            }.onChange(of:PIPFrameLog) { newValue in
                logger.debug("PIPFrameLog:\(newValue)")
                sendlog(message: "PIPFrameLog:\(newValue)")
            }


        }
        .navigationTitle("PIP日誌設置")
    }
    
}


struct LogSettingView:View {

    @AppStorage("onlogPage",store:userDefaults) private var onlogPage = false
    @AppStorage("allowFrameReordering",store:userDefaults) private var allowFrameReordering = true
    @AppStorage("BitRateMode",store:userDefaults)  private var BitRateMode = 0

    let BitRateOptions = ["ABR 平均碼率 VBR的改進版", "CBR 固定碼率", "VBR 可變位元率 iOS26後才有"]
        
    @AppStorage("BacklogTime",store:userDefaults) private var logTime = false

    @AppStorage("Enablelog",store:userDefaults) private var Enablelog = false
    @AppStorage("EnableRotatelog",store:userDefaults) private var EnableRotatelog = false
    @AppStorage("EnableSocketlog",store:userDefaults) private var EnableSocketlog = false
    @AppStorage("EnableTimeDebug",store:userDefaults) private var EnableTimeDebug = false

    @AppStorage("ChangeBit",store:userDefaults) private var ChangeBit = true
    @AppStorage("isLowLatencyRateControlEnabled",store:userDefaults)  private var isLowLatencyRateControlEnabled = true

    @AppStorage("isNotifyChat",store:userDefaults) private var isNotifyChat = false
    


    @ObservedObject var socket = SocketServer.shared

    var body: some View {
        Section(header: Text("除錯日誌")) {

            Toggle(isOn: $Enablelog){
                Text("啟用調試用日誌 ！")
            }.onChange(of:Enablelog) { newValue in
                CFNotificationCenterPostNotification(cfCenter, CFNotificationName("Enablelog" as CFString), nil, nil, true)
            }


            Toggle(isOn: $allowFrameReordering){
                Text("允許畫面幀捕捉！ 或許可以改進畫面品質")
            }.onChange(of:allowFrameReordering) { newValue in
                sendlog(message:"允許 ReplayKit 捕捉完整畫面幀 \(newValue)")
            }
            
            Text("啟用後 捕捉完整畫面幀 開啟逐幀錄製會增加 CPU/GPU 負擔，可能影響效能")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 5)


            Picker("請選擇一個位元率模式", selection: $BitRateMode) {
                ForEach(0..<BitRateOptions.count, id: \.self) { index in
                    Text(BitRateOptions[index]).tag(index)
                }
            }
            .pickerStyle(.segmented) // 可改成 .menu 看起來像下拉選單

            Text("目前選擇：\(BitRateOptions[BitRateMode])")
                .padding()

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

            Toggle(isOn:$isLowLatencyRateControlEnabled){
                    Text("啟用低延遲處理！")
            }

            Text("啟用後會對使用低延遲推流")                                                                                                     
            .font(.footnote)
            .foregroundColor(.secondary)
            .padding(.bottom, 5)

            Toggle(isOn:$isNotifyChat){
                                Text("啟用聊天訊息通知！")
                            }

            Text("作為PIP子母窗口應高運存占用的替代方案，啟用後會對聊天訊息使用系統通知處理，避免PIP停止時訊息無法顯示的問題")                                                                                                     
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
        Section(header: Text("直播計時器")) {

            Button("重新開始直播計時器"){
                sendlog(message: "直播開始計時器重啟")
                SocketServer.shared.StreamStarting()

            }

            Text("當直播計時器出現異常無法正常運行時可以用這個重啟它")
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.bottom, 5)

            Button("停止直播計時器 直播結束"){
                sendlog(message: "直播結束 計時器停止")
                SocketServer.shared.StreamStatusChanged(isLive: false)

            }

            Text("當直播結束時可以用這個停止計時器")
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.bottom, 5)

            

        }

        Section(header: Text("網路")) {

            Button("測試擴展通信傳遞"){
                // 未來計畫棄用 已經用Socket轉送處理了
                //AppMessagePort.shared.send(toExtension: ["ping": "From_App"])

                socket.broadcast(type:"log",key: "test3", value: "OK Socket")
                socket.broadcast(type: "testRTMP", key: "test3", value: "OK")

            }
            Button("Socket重連"){
                CFNotificationCenterPostNotification(cfCenter, CFNotificationName("SocketRetry" as CFString), nil, nil, true)

            }
            
            Text("如果通信斷線了可以用這個重建")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 5)

            Button("Socket服務器重啟"){
                socket.stop()
                socket.start()

            }
            Text("如果擴展初始連不上可以用他重啟服務端")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 5)

            Text("Socket運行情況:\(socket.isStopping ? "停止" : "運行中" ) ")

            Button("Socket服務器停止"){
                socket.stop()
            }


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
