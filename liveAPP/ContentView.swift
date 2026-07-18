//
//  ContentView.swift
//  liveAPP
//
//  Created by user on 2025/8/24.
//

import ReplayKit
import SwiftUI

import Combine
import os
import Foundation

let logger = Logger(subsystem: "nuclear.liveAPP", category: "extension")

let cfCenter = CFNotificationCenterGetDarwinNotifyCenter()


#if os(iOS)
let userDefaults: UserDefaults? = UserDefaults(
    suiteName: "group.nuclear.liveAPP"
) ?? .standard

#else
let userDefaults: UserDefaults = .standard
#endif



func setUserDefault<T>(_ value: T, forKey key: String) {
#if os(iOS)
    userDefaults?.set(value, forKey: key)
#else
    userDefaults.set(value, forKey: key)
#endif
}

func getUserDefault<T>(forKey key: String) -> T? {
#if os(iOS)
    
    let defaults = userDefaults
    switch T.self {
    case is Float.Type:
        return defaults?.float(forKey: key) as? T
    case is Double.Type:
        return defaults?.double(forKey: key) as? T
    case is Int.Type:
        return defaults?.integer(forKey: key) as? T
    case is Bool.Type:
        return defaults?.bool(forKey: key) as? T
    default:
        return defaults?.value(forKey: key) as? T
    }
    #else

    guard let userDefaults = userDefaults else { return nil }

    let defaults = userDefaults
    switch T.self {
    case is Float.Type:
        return defaults.float(forKey: key) as? T
    case is Double.Type:
        return defaults.double(forKey: key) as? T
    case is Int.Type:
        return defaults.integer(forKey: key) as? T
    case is Bool.Type:
        return defaults.bool(forKey: key) as? T
    default:
        return defaults.value(forKey: key) as? T
    }



    #endif
}





// ObservableObject 管理碼率
class BitrateManager: ObservableObject {
    @Published var multiplier: Int = 60

    let base: Int = 100_000       // 每單位 100 kbps
    @Published var bitrate: Int = 6_000_000    // 實際 bps

    init() {
        // 嘗試讀取 UserDefaults 的保存值

        if let saved: Int = getUserDefault(forKey: "bitRate"), saved != 0 {
            bitrate = saved
            multiplier = saved / base

            
        } else {
            bitrate = base * multiplier
            saveBitrate()
        }

    }

    func saveBitrate() {
        setUserDefault(bitrate, forKey: "bitRate")
        setUserDefault(multiplier, forKey: "bitRateMultiplier")
        
    }

    func updateStreamBitrate() {
        logger.info("Debug\(self.bitrate)")

        // multiplier 變動時更新實際 bitrate
        bitrate = base * multiplier
        
        saveBitrate()
        notifyStream()

    }

    private func notifyStream() {
            let cfCenter = CFNotificationCenterGetDarwinNotifyCenter()
            CFNotificationCenterPostNotification(cfCenter,
                                                 CFNotificationName("bitRateChange" as CFString),
                                                 nil, nil, true)
        }

}





#if os(iOS)
struct BroadcastButton: UIViewRepresentable {
    var preferredExtension: String
    var rtmpURL: String
    var rtmpKey: String
    var width: CGFloat
    var height: CGFloat
    var base: Int = 100_000
    var multiplier: Int = 34

    private func resolveExtension() -> String? {
        // 1. 從 PlugIns 動態發現——只選 broadcast upload extension
        if let plugInsURL = Bundle.main.builtInPlugInsURL,
           let entries = try? FileManager.default.contentsOfDirectory(at: plugInsURL, includingPropertiesForKeys: nil) {
            let appexEntries = entries.filter { $0.pathExtension == "appex" }
            sendlog(title: "BroadcastButton", message: "Found \(appexEntries.count) appex bundles in PlugIns")

            for entry in appexEntries {
                if let bundle = Bundle(url: entry), let bundleID = bundle.bundleIdentifier {
                    let isBroadcastUpload: Bool
                    if let extDict = bundle.infoDictionary?["NSExtension"] as? [String: Any],
                       let pointID = extDict["NSExtensionPointIdentifier"] as? String {
                        isBroadcastUpload = (pointID == "com.apple.broadcast-services-upload")
                    } else {
                        isBroadcastUpload = false
                    }
                    sendlog(title: "BroadcastButton", message: "  \(entry.lastPathComponent): bundleID=\(bundleID) type=\(isBroadcastUpload ? "broadcast-upload" : "other")")
                    if isBroadcastUpload {
                        sendlog(title: "BroadcastButton", message: "Selected broadcast upload extension: \(bundleID)")
                        return bundleID
                    }
                }
            }
            sendlog(title: "BroadcastButton", message: "No broadcast upload extension found in PlugIns")
        } else {
            sendlog(title: "BroadcastButton", message: "No PlugIns directory or unable to read")
        }

        // 2. 使用使用者設定的值
        if !preferredExtension.isEmpty {
            sendlog(title: "BroadcastButton", message: "Fallback to user setting: \(preferredExtension)")
            return preferredExtension
        }

        // 3. 從主 App bundle ID 推測
        if let bundleID = Bundle.main.bundleIdentifier {
            let candidate = bundleID + ".ReplyKIT"
            sendlog(title: "BroadcastButton", message: "Fallback to constructed: \(candidate)")
            return candidate
        }

        sendlog(title: "BroadcastButton", message: "Failed to resolve broadcast extension")
        return nil
    }

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: .zero)
        picker.preferredExtension = resolveExtension()
        picker.showsMicrophoneButton = true
        picker.isHidden = true

        sendlog(title: "BroadcastButton", message: "preferredExtension = \(picker.preferredExtension ?? "nil")")
        sendlog(title: "BroadcastButton", message: "Bundle.main.bundleIdentifier = \(Bundle.main.bundleIdentifier ?? "nil")")

        Coordinator.currentPicker = picker
        for view in picker.subviews {
            if let button = view as? UIButton {
                button.addTarget(context.coordinator, action: #selector(Coordinator.buttonTapped), for: .touchUpInside)
            }
        }

        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        let ext = resolveExtension()
        sendlog(title: "BroadcastButton", message: "updateUIView preferredExtension = \(ext ?? "nil")")
        uiView.preferredExtension = ext
        context.coordinator.rtmpURL = rtmpURL
        context.coordinator.rtmpKey = rtmpKey
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func triggerButton() {
        Coordinator.trigger()
    }

    class Coordinator: NSObject {
        static weak var currentPicker: RPSystemBroadcastPickerView?
        var rtmpURL: String = ""
        var rtmpKey: String = ""
        var UR: UIDeviceOrientation = .unknown

        @objc func buttonTapped() {
            self.UR = UIDevice.current.orientation
            sendlog(title: "BroadcastButton", message: "buttonTapped orientation=\(self.UR.rawValue)")
            logger.info("ROTATE:\(String(describing: self.UR))")
            userDefaults?.set(self.UR.rawValue, forKey: "L3Rotate")
        }

        static func trigger() {
            sendlog(title: "BroadcastButton", message: "trigger() called")

            let payload = [
                "type": "log",
                "message": "Socket連線測試"
            ]
            SocketServer.shared.queueSend(payload: payload)

            guard let picker = currentPicker else {
                sendlog(title: "BroadcastButton", message: "trigger() failed: currentPicker is nil")
                return
            }
            guard let button = picker.subviews.first(where: { $0 is UIButton }) as? UIButton else {
                sendlog(title: "BroadcastButton", message: "trigger() failed: no UIButton in picker subviews")
                return
            }
            sendlog(title: "BroadcastButton", message: "trigger() simulating button tap")
            button.sendActions(for: .touchUpInside)
        }
    }
}
#endif



// MARK: 全局實時音訊模塊
final class LiveVolumeModel: ObservableObject {
    static let shared = LiveVolumeModel()   // 全局共用單例

    @Published var micVolumeLive: Float = 0.0
    @Published var appVolumeLive: Float = 0.0

    private init() {
#if os(iOS)

        if !LPConfig.shared.SocketLog {
        CFNotificationCenterAddObserver(cfCenter,
                                        UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                                        { _, observer, name, _,_  in
            guard let observer = observer else { return }
            let model = Unmanaged<LiveVolumeModel>.fromOpaque(observer).takeUnretainedValue()

            model.micVolumeLive  = getUserDefault(forKey: "micVolumeLive") ?? 0.0
            model.appVolumeLive  = getUserDefault(forKey: "appVolumeLive") ?? 0.0
        },
                                        "LiveVolumeUpdated" as CFString,
                                        nil,
                                        .deliverImmediately)

        }

#else

        if !LPConfig.shared.SocketLog {
            NotificationCenter.default.addObserver(
                forName: Notification.Name("LiveVolumeUpdated"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.micVolumeLive = getUserDefault(forKey: "micVolumeLive") ?? 0.0
                    self.appVolumeLive = getUserDefault(forKey: "appVolumeLive") ?? 0.0
                }
            }

        }
#endif
    }

    deinit {
#if os(iOS)
        CFNotificationCenterRemoveEveryObserver(cfCenter,
            UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()))
#else
        NotificationCenter.default.removeObserver(self)
#endif
    }

    // 🔹 新增一個全局更新函數
    func updateVolumes(mic: Float? = nil, app: Float? = nil, persist: Bool = false) {
        if let mic = mic {
            self.micVolumeLive = mic
            if persist {
            setUserDefault(mic, forKey: "micVolumeLive")
            }
        }
        if let app = app {
            self.appVolumeLive = app
            if persist {
            setUserDefault(app, forKey: "appVolumeLive")
            }
        }

        // 發送通知，讓其他地方也能收到更新
#if os(iOS)
        CFNotificationCenterPostNotification(cfCenter,
                                             CFNotificationName("LiveVolumeUpdated" as CFString),
                                             nil,
                                             nil,
                                             true)
#else
        NotificationCenter.default.post(name: Notification.Name("LiveVolumeUpdated"), object: nil)
#endif
    }
}



// MARK: UI 百分比 (0~1) → 真實音量 (0~1)，曲線控制低音量更細膩
func percentageToVolume(_ percentage: Double) -> Double {
    let clamped = max(0, min(1, percentage))

    // 指數曲線 exponent < 1 → 前段變化慢，後段變化快
    let exponent: Double = 0.5
    return pow(clamped, exponent)
}

/// 真實音量 (0~1) → UI 百分比 (0~1)
func volumeToPercentage(_ volume: Double) -> Double {
    let clamped = max(0, min(1, volume))
    let exponent: Double = 0.5
    return pow(clamped, 1.0 / exponent)
}

// 自繪進度條 (取代 ProgressView)
struct SafeProgressBar: View {
    var value: Double      // 0.0 ~ 1.0
    var color: Color
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.gray.opacity(0.3))
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * CGFloat(min(max(value, 0), 1)))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.2), value: value)
    }
}

struct LiveVolumeView: View {


    @StateObject var model = LiveVolumeModel.shared

    @AppStorage("appVolume",store: userDefaults)  var appVolume: Double = 1.0
    @AppStorage("micVolume",store: userDefaults)  var micVolume: Double = 1.0

    @AppStorage("appAddVolume",store: userDefaults)  var appAddVolume: Double = 1.0
    @AppStorage("micAddVolume",store: userDefaults)  var micAddVolume: Double = 1.0



    init(){

    }

    var body: some View {


        VStack {
            VStack {
                Text("[棄用]App增益: \(String(format: "%.1f", appAddVolume)) 倍")
                    .font(.headline)


                Slider(value: $appAddVolume, in: 1...30, step: 0.1,
                    onEditingChanged: {
                    editing in

                    if !editing {


#if os(iOS)

                        CFNotificationCenterPostNotification(
                            cfCenter,
                            CFNotificationName("appAdd" as CFString),
                            nil,
                            nil,
                            true
                        )
#else
                        NotificationCenter.default
                            .post(
                                name: Notification.Name("appAdd"),
                                object: nil
                            )
#endif

                        sendlog(message: String(
                            format: "應用增益更新: %.1f 倍",
                            appAddVolume
                        ))

                    }

                }

                )



            }

            VStack {
                Text("Mic增益: \(String(format: "%.1f", micAddVolume)) 倍")
                    .font(.headline)



                Slider(value: $micAddVolume, in: 1...30, step: 0.1,
                        onEditingChanged: { editing in

                    if !editing {

#if os(iOS)



                        CFNotificationCenterPostNotification(
                            cfCenter,
                            CFNotificationName("micAdd" as CFString),
                            nil,
                            nil,
                            true
                        )
#else
                        NotificationCenter.default
                            .post(
                                name: Notification.Name("micAdd"),
                                object: nil
                            )
#endif

                        sendlog(message: String(
                            format: "Mic增益更新: %.1f 倍",
                            micAddVolume
                        ))


                    }


                }

                )

            }


            VStack {

                Text("App音量: \(String(format: "%.2f%%", volumeToPercentage(appVolume) * 100)) 原始:\(String(format: "%.2f%", appVolume * 100))")
                    .font(.headline)



                Slider(
                    value:
                        Binding(
                    get: { volumeToPercentage(appVolume) },            // 從 appVolume 轉百分比
                    set: { newValue in

                             // 邊界保護，避免浮點誤差
                            if abs(newValue - 1.0) < 0.001 {
                                appVolume = 1.0
                            } else if abs(newValue - 0.0) < 0.001 {
                                appVolume = 0.0
                            } else {
                                appVolume = percentageToVolume(newValue)
                            }

                        }
                    )
                        , in: 0.0...0.99, step: 0.01,
                        onEditingChanged: { editing in

                    if !editing {
                        


#if os(iOS)

                        CFNotificationCenterPostNotification(
                            cfCenter,
                            CFNotificationName(
                                "appVolumeChanged" as CFString
                            ),
                            nil,
                            nil,
                            true
                        )
#else
                        NotificationCenter.default
                            .post(
                                name: Notification.Name("appVolumeChanged"),
                                object: nil
                            )
#endif

                        sendlog(message: String(
                            format: "應用音量更新: %.2f%% (真實值: %.5f)",
                            appVolume * 100,
                            appVolume
                        ))

                    }

                }
                )




                // 標尺
                HStack {
                    Text("0%").font(.caption)
                    Spacer()
                    Text("25%").font(.caption)
                    Spacer()
                    Text("50%").font(.caption)
                    Spacer()
                    Text("75%").font(.caption)
                    Spacer()
                    Text("100%").font(.caption)
                }



                // 自繪進度條 (取代 ProgressView)
                SafeProgressBar(value: appVolume, color: .blue)
                    .padding(.vertical, 4)


            }



            VStack {
                // 顯示用：直接顯示真實音量百分比
                Text("Mic音量: \(String(format: "%.2f%%", volumeToPercentage(micVolume) * 100)) 原始:\(String(format: "%.2f%", micVolume * 100))")
                    .font(.headline)




                Slider(value:
                        Binding(
                    get: { volumeToPercentage(micVolume) },            // 從 micVolume 轉百分比
                    set: { newValue in

                           // 邊界保護，避免浮點誤差
                            if abs(newValue - 1.0) < 0.001 {
                                micVolume = 1.0
                            } else if abs(newValue - 0.0) < 0.001 {
                                micVolume = 0.0
                            } else {
                                micVolume = percentageToVolume(newValue)
                            }


                        }
                    )

                        , in: 0.0...0.99, step: 0.01,
                        onEditingChanged: { editing in

                    if !editing {
                        //let realVolume = percentageToVolume(Mic_percentage)
                        sendlog(message: String(
                            format: "麥克風音量更新: %.2f%% (真實值: %.5f)",
                            micVolume * 100,
                            micVolume
                        ))


#if os(iOS)

                        CFNotificationCenterPostNotification(
                            cfCenter,
                            CFNotificationName(
                                "micVolumeChanged" as CFString
                            ),
                            nil,
                            nil,
                            true
                        )

#else
                        NotificationCenter.default
                            .post(
                                name: Notification.Name("appVolumeChanged"),
                                object: nil
                            )
#endif
                    }

                }
                )




                // 標尺
                HStack {
                    Text("0%").font(.caption)
                    Spacer()
                    Text("25%").font(.caption)
                    Spacer()
                    Text("50%").font(.caption)
                    Spacer()
                    Text("75%").font(.caption)
                    Spacer()
                    Text("100%").font(.caption)
                }


                // 自繪進度條 (取代 ProgressView)
                SafeProgressBar(value: micVolume, color: .red)
                    .padding(.vertical, 4)

            }




            VStack(alignment: .leading) {
                Text("Mic Volume \(model.micVolumeLive)")


                // 自繪進度條 (取代 ProgressView)
                SafeProgressBar(value: Double(model.micVolumeLive), color: .red)
                    .padding(.vertical, 4)

            }
            VStack(alignment: .leading) {
                Text("App Volume \(model.appVolumeLive)")

                // 自繪進度條 (取代 ProgressView)
                SafeProgressBar(value: Double(model.appVolumeLive), color: .blue)
                    .padding(.vertical, 4)


            }
        }
        .padding()
    }
}










enum RotateDirection: Int, Codable, CaseIterable, Identifiable, CustomStringConvertible {
    case portrait = 0          // 直向
    case landscapeRight = 90   // 橫向，Home鍵右側
    case portraitUpsideDown = 180 // 反向直向
    case landscapeLeft = 270   // 橫向，Home鍵左側

    var id: Int { rawValue }

    
    var description: String {
        switch self {
        case .portrait: return "直向"
        case .landscapeRight: return "橫向  (Home鍵在右側)"
        case .portraitUpsideDown: return "反向直向"
        case .landscapeLeft: return "橫向 (Home鍵在左側)"
        }
    }
}


class GPUOutputConfig: Identifiable, ObservableObject, Codable {
    let id: UUID
    @Published var name: String
    @Published var width: Int
    @Published var height: Int

    @Published var owidth: Int
    @Published var oheight: Int
    @Published var originonly: Bool

    @Published var Rotate: RotateDirection

    init(
        id: UUID = UUID(),
        name: String,
        width: Int,
        height: Int,
        owidth:Int = 0,
        oheight:Int = 0,
        originonly:Bool = false,
        Rotate: RotateDirection = .landscapeRight
    ) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height

        self.owidth = owidth
        self.oheight = oheight
        self.originonly = originonly

        self.Rotate = Rotate

    }

    // MARK: - Codable 支援
    enum CodingKeys: CodingKey {
        case id, name, width, height, owidth,oheight,originonly,Rotate
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)

        owidth = try container.decode(Int.self, forKey: .owidth)
        oheight = try container.decode(Int.self, forKey: .oheight)

        originonly = try container.decode(Bool.self, forKey: .originonly)

        Rotate = try container.decode(RotateDirection.self, forKey: .Rotate)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)

        try container.encode(owidth, forKey: .owidth)
        try container.encode(oheight, forKey: .oheight)

        try container.encode(originonly, forKey: .originonly)


        try container.encode(Rotate, forKey: .Rotate)
    }

    // MARK: - 保存 & 讀取 整個配置列表
    static private let userDefaultsKey = "gpuConfigs"
    static private let userDefaultsSelectKey = "gpuConfigsSelect"

    static func save(_ configs: [GPUOutputConfig]) {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(configs) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    static func load(defaults: [GPUOutputConfig]? = nil) -> [GPUOutputConfig] {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let savedConfigs = try? JSONDecoder().decode([GPUOutputConfig].self, from: data) {
            return savedConfigs
        } else {
            return defaults ?? []
        }
    }  


    // MARK: - 保存當前選擇的配置
    static func saveSelected(_ config: GPUOutputConfig?) {
        guard let config else {
            logger.debug("無配置！GPUOutConfig")
            return
        }
        
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: userDefaultsSelectKey)
        }
    }


    // MARK: - 讀取當前選擇的配置
    static func loadSelected() -> GPUOutputConfig? {
        if let data = UserDefaults.standard.data(forKey: userDefaultsSelectKey),
           let config = try? JSONDecoder().decode(GPUOutputConfig.self, from: data) {
            return config
        }
        return nil
    }

    // MARK: - 快速清除所有記錄（可選）
    static func resetAll() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: userDefaultsSelectKey)
    }
}



struct LogSettingsView: View {
    @AppStorage("logURL", store: userDefaults) private var logURL = "http://192.168.0.242:3000/post"
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
    @AppStorage("PIPAdOverlayFont", store: userDefaults) private var PIPAdOverlayFont = 12.0

    @AppStorage("broadcastExtension", store: userDefaults) private var broadcastExtension = (Bundle.main.bundleIdentifier ?? "nuclear.liveAPP") + ".ReplyKIT"


    var body: some View {
        NavigationView {
            Form {
                
                LogSettingView()

                NavigationLink("音訊處理設置") {
                    AudioSettingsView()
                }

                NavigationLink("PIP子母窗口設置") {
                    PIPSettingsView()
                }

                NavigationLink("GPU旋轉處理設置") {
                    GPURotateView(viewModel: gpuSettings)
                }


                Section(header: Text("廣播擴展 Bundle ID")) {
                    TextField((Bundle.main.bundleIdentifier ?? "nuclear.liveAPP") + ".ReplyKIT", text: $broadcastExtension)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.caption)
                    Text("設定後需重新啟動廣播才生效")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("API 接口地址")) {
                    TextField("https://example.com/api/logs", text: $tempEndpoint)
                        .keyboardType(.URL)
                        .autocapitalization(.none)

                    Button("測試連線") {
                        testResult = nil
                        isTesting = true
                        testConnection(to: tempEndpoint)
                    }
                    .disabled(tempEndpoint.trimmingCharacters(in: .whitespaces).isEmpty)

                    if let result = testResult {
                        Text(result)
                            .foregroundColor(result.contains("成功") ? .green : .red)
                    }

                    Button("取得視頻輸出設定") {
                        CFNotificationCenterPostNotification(cfCenter, CFNotificationName("VideoSet" as CFString), nil, nil, true)
                    }
                }


                Section(header: Text("PIP 子母窗口")) {

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
                        "廣告覆著字體大小 直接輸入大小 12",
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

                    Text("建議值: 12.0")
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
            .navigationTitle("主設定頁面")
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

enum LogMode: Int, CaseIterable, Identifiable {
    case app = 1       // 對應 App
    case external = 0  // 對應 外部
    case both = 2

    var id: Int { self.rawValue }

    var description: String {
        switch self {
        case .app: return "App"
        case .external: return "外部"
        case .both: return "App + 外部"
        }
    }
}



// MARK: Log 顯示 UIViewRepresentable

struct LogTextView: UIViewRepresentable {

    @ObservedObject var logModel: LogModel

    @Binding var isNearBottom: Bool
    @Binding var coordinatorHolder: Coordinator?


    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    final class Coordinator: NSObject, UITextViewDelegate {

        var textView: UITextView?

        var currentLineCount = 0
        let maxLines = 3000

        var hasInitialLoad = false


        var userIsInteracting = false

        var isVisible = true

        var onNearBottomChanged: ((Bool) -> Void)?



        private var lastNearBottom: Bool?

        var isOK = false

        var scrollWorkItem: DispatchWorkItem?
        private let scrollDelay: TimeInterval = 0.2


        private func trimTextStorageIfNeeded(_ tv: UITextView) {
            guard currentLineCount > maxLines else { return }
            let excess = currentLineCount - maxLines
            let storage = tv.textStorage
            let nsString = storage.string as NSString

            // 計算前 excess 行的字元範圍
            var deleteEnd = 0
            var lineStart = 0
            for _ in 0..<excess {
                let range = nsString.lineRange(for: NSRange(location: lineStart, length: 0))
                deleteEnd = range.upperBound
                lineStart = range.upperBound
                if lineStart >= nsString.length { break }
            }

            guard deleteEnd > 0 else { return }
            storage.replaceCharacters(in: NSRange(location: 0, length: deleteEnd), with: "")
            currentLineCount = maxLines
        }
        



        private var appendQueue = [LogItem]()

        private var appendWorkItem: DispatchWorkItem?

        func appendMessages(_ newMessages: [LogItem]) {
            guard isVisible, !newMessages.isEmpty else { return }

            appendQueue.append(contentsOf: newMessages)

            // 延遲批量 append，避免每條都操作 UITextView
            if appendWorkItem == nil {
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self = self, let tv = self.textView, tv.window != nil else {
                        self?.appendWorkItem = nil
                        return
                    }

                    let pendingMessages = self.appendQueue
                    self.appendQueue.removeAll()

                    var appendedText = ""
                    for msg in pendingMessages {
                        self.currentLineCount += 1
                        appendedText += "\(self.currentLineCount): \(msg.message)\n"
                    }

                    guard !appendedText.isEmpty else {
                        self.appendWorkItem = nil
                        return
                    }

                    var attributes: [NSAttributedString.Key: Any] = [:]
                    if let font = tv.font {
                        attributes[.font] = font
                    }
                    if let textColor = tv.textColor {
                        attributes[.foregroundColor] = textColor
                    }
                    tv.textStorage.append(NSAttributedString(string: appendedText, attributes: attributes))
                    tv.layoutIfNeeded()

                    self.trimTextStorageIfNeeded(tv)

                    if self.shouldAutoScroll {
                        self.scrollToBottomUsingRange(animated: false)
                    }

                    self.appendWorkItem = nil
                }

                appendWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)

            }
        }


        private func canUpdateUI() -> Bool {
            guard
                let tv = textView,
                tv.window != nil,
                !userIsInteracting
            else {
                return false
            }
            return true
        }

        var shouldAutoScroll = true

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let visibleHeight =
                scrollView.bounds.height
                - scrollView.adjustedContentInset.top
                - scrollView.adjustedContentInset.bottom

            let offsetY = scrollView.contentOffset.y
            let contentHeight = scrollView.contentSize.height

            //logger.debug("offSET:\(offsetY) + \(visibleHeight) CH:\(contentHeight*0.75)")
            shouldAutoScroll =
            offsetY + visibleHeight >= contentHeight * 0.75


            if lastNearBottom != shouldAutoScroll {
                lastNearBottom = shouldAutoScroll
                onNearBottomChanged?(shouldAutoScroll)
            }
        }

        // 判斷是否滾動
            func scrollIfNeeded() {
                guard let tv = textView ,canUpdateUI() else { return }

                tv.layoutIfNeeded()

                if shouldAutoScroll {
                    scrollToBottomUsingRange()
                }

            }


        func scrollToBottomAfterCATransaction(animated: Bool = false) {
            guard textView != nil else { return }

            CATransaction.begin()
            CATransaction.setDisableActions(true)

            CATransaction.setCompletionBlock { [weak self] in
                guard let self = self else { return }
                self.scrollToBottomUsingRange(animated: animated)
            }


            CATransaction.commit()
        }

        func scrollToBottomUsingRange(animated: Bool = true) {
            guard let tv = textView, tv.window != nil else { return }

            // 確保 layout / contentSize 是最新的
            tv.layoutIfNeeded()

            let length = tv.textStorage.length
            guard length > 0 else { return }

            // 捲到最後一個字元
            let range = NSRange(location: length - 1, length: 1)
            tv.scrollRangeToVisible(range)

            if animated {
                // scrollRangeToVisible 本身不支援 animated
                // 這裡補一個平滑動畫（可選）
                UIView.animate(withDuration: 0.15) {
                    tv.layoutIfNeeded()
                }
            }
        }





        func cancelPendingWork() {
            appendWorkItem?.cancel()
            appendWorkItem = nil
            appendQueue.removeAll()
        }

        func clearText() {
            cancelPendingWork()
            currentLineCount = 0
            if let tv = textView {
                tv.text = ""
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {

            guard let range = textView.selectedTextRange else {
                userIsInteracting = false
                return
            }

            // 只有「有選取範圍」才算互動
            userIsInteracting = !range.isEmpty
        }








        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            logger.debug("Get change scroll")

            userIsInteracting = true

        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            logger.debug("Get change scrollend")

            if !decelerate {
                userIsInteracting = false
                //updateNearBottom()
            }
        }


    }


    func makeUIView(context: Context) -> UITextView {

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: .zero)

        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        let textView = UITextView(
            frame: .zero,
            textContainer: textContainer
        )

        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = UIColor.systemBackground
        textView.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = UIColor.label
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        textView.alwaysBounceVertical = true
        textView.isScrollEnabled = true
        textView.showsVerticalScrollIndicator = true

        textView.layoutManager.allowsNonContiguousLayout = true

        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        // 🔑 關鍵：把 nearBottom 回傳給 SwiftUI
        context.coordinator.onNearBottomChanged = { value in
                self.isNearBottom = value

        }

        // 🔑 關鍵：只綁定一次 coordinator

        if self.coordinatorHolder == nil {
            self.coordinatorHolder = context.coordinator
        }







        return textView
    }



    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.textView = uiView

        guard !context.coordinator.hasInitialLoad else { return }

        let messages = logModel.messages
        guard !messages.isEmpty else { return }

        // 🔹 先 append 現有訊息
        context.coordinator.appendMessages(messages)

        context.coordinator.hasInitialLoad = true
    }

}







struct LogView: View {
    @EnvironmentObject var logModel: LogModel
    @Environment(\.scenePhase) private var scenePhase


    @AppStorage("logMode",store:userDefaults) private var logMode = 1
    @State private var showLogSettings = false
    @State private var coordinator: LogTextView.Coordinator?


    @State private var isNearBottom = false


    var logC: LogMode {
        LogMode(rawValue: logMode) ?? .app
    }

    var body: some View {

        VStack {

            Text("日誌：\(logMode) \(logC.description)")
            Button("App日誌") {
                logMode = 1
                LPConfig.shared.logMode=logMode

                CFNotificationCenterPostNotification(cfCenter, CFNotificationName("logMode" as CFString), nil, nil, true)



            }
            Button("外部日誌") {
                logMode = 0
                LPConfig.shared.logMode=logMode

                CFNotificationCenterPostNotification(cfCenter, CFNotificationName("logMode" as CFString), nil, nil, true)


            }
            Button("App + 外部日誌") {
                logMode = 2
                LPConfig.shared.logMode=logMode
                CFNotificationCenterPostNotification(cfCenter, CFNotificationName("logMode" as CFString), nil, nil, true)

            }

            Text("目前訊息數：\(logModel.messages.count)")
                .font(.caption)
                .foregroundColor(.gray)


            VStack {
                Button("開啟日誌設定") {
                    showLogSettings = true
                }
                .padding()
                .background(Color.green)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .sheet(isPresented: $showLogSettings) {
                LogSettingsView()
            }

            Button("清除日誌") {
                logModel.clearLogs()
                coordinator?.clearText()
                AppLogPersister.shared.clear()
                if let containerURL =
                    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.nuclear.liveAPP") {
                    let logURL = containerURL.appendingPathComponent("log.txt")
                    do {
                        try "".write(to: logURL, atomically: true, encoding: .utf8)
                        sendlog(message: "✅ log.txt 已清空")
                    } catch {
                        sendlog(message: "❌ 無法清空 log.txt：\(error)")
                    }
                }
            }

            ZStack(alignment: .bottomTrailing) {


                LogTextView(
                    logModel: logModel,

                    isNearBottom: $isNearBottom, coordinatorHolder: $coordinator
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onReceive(logModel.newMessages) { newItems in
                    guard let coordinator = coordinator else { return }
                    // 交給 Coordinator 處理 append + 滾動
                    DispatchQueue.main.async {
                        coordinator.appendMessages(newItems)
                    }

                }
                .onAppear {
                    guard let coordinator = coordinator else { return }
                    coordinator.shouldAutoScroll = true
                    coordinator.isVisible = true

                }
                .onDisappear {
                    guard let coordinator = coordinator else { return }
                    coordinator.isVisible = false
                    coordinator.shouldAutoScroll = false
                    coordinator.cancelPendingWork()
                }
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .background {
                        logModel.clearLogs()
                        coordinator?.clearText()
                    }
                }






                if !isNearBottom {
                    Button {
                        coordinator?.scrollToBottomUsingRange()

                    } label: {
                        Text("↓ Jump to bottom")
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }
                    .padding(16)
                }
            }


        }
    }

}



struct AnimatedButton: View {
    var title: String
    var color: Color = .blue
    var action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: { action() }) {
            Text(title)
                .frame(maxWidth: .infinity)
                .padding()
                .background(isPressed ? color.opacity(0.6) : color)
                .foregroundColor(.white)
                .cornerRadius(8)
                .scaleEffect(isPressed ? 0.95 : 1.0)
        }
#if os(iOS)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
                        isPressed = true

                    }
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
                        isPressed = false
                        action()
                    }
                }
        )
#elseif os(macOS)
        .onHover { hovering in withAnimation { isPressed = hovering } }
        .onTapGesture { action() }
#endif
    }
}

struct FormView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var manager = StreamConfigManager()
    @AppStorage("rtmpURL",store: userDefaults) var rtmpURL: String = ""
    @AppStorage("rtmpKey",store: userDefaults) var rtmpKey: String=""


    @State var name:String = "自訂"
    @State var tip:String = ""

    @State private var selectedConfigID: UUID?


    var con: some View{
        List {
            Section(header: Text("選擇配置")) {

                if #available(iOS 17.0, *) {
                    Picker("配置", selection: $selectedConfigID) {
                        Text("未選擇任何配置").tag(UUID?.none) // 明確告訴 SwiftUI nil 代表這個選項

                        ForEach(manager.configs) { config in
                            Text(config.name).tag(config.id as UUID?)
                        }
                    }
                    .onChange(of: selectedConfigID) {
                        old,
                        newID in
                        if let id = newID,
                           let config = manager.configs.first(
                            where: { $0.id == id
                            }) {
                            // 切換當前配置
                            manager.setActiveConfig(config)
                            name = config.name
                            rtmpURL = config.rtmpURL
                            rtmpKey = config.streamKey
                        } else {
                            // 沒選中 → 清空
                            name = ""
                            rtmpURL = ""
                            rtmpKey = ""
                        }

                    }
                } else {
                    // Fallback on earlier versions
                    Picker("配置", selection: $selectedConfigID) {
                        ForEach(manager.configs) { config in
                            Text(config.name).tag(config.id as UUID?)
                        }
                    }
                    .onChange(of: selectedConfigID) {

                        newID in
                        if let id = newID,
                           let config = manager.configs.first(
                            where: { $0.id == id
                            }) {
                            // 切換當前配置
                            manager.setActiveConfig(config)
                            name = config.name
                            rtmpURL = config.rtmpURL
                            rtmpKey = config.streamKey
                        } else {
                            // 沒選中 → 清空
                            name = ""
                            rtmpURL = ""
                            rtmpKey = ""
                        }

                    }
                }
            }

            Section(header: Text("RTMP 設定")) {
                TextField("配置名稱", text: $name)
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
                    .autocorrectionDisabled(true)

                TextField("RTMP URL", text: $rtmpURL)
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
                    .autocorrectionDisabled(true)

                Menu("快速選擇樣本") {
                    Button("自訂SRS") { rtmpURL = "rtmp://192.168.0.102/live" }
                    Button("Twitch") { rtmpURL = "rtmp://live.twitch.tv/app" }

                }
                .padding(.top, 2)
                .foregroundColor(.blue)


                TextField("Stream Key", text: $rtmpKey)
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
                    .autocorrectionDisabled(true)
            }

            Section(header:Text("配置設定")){
                Text(tip)
                    .foregroundColor(.red)

                AnimatedButton(title:selectedConfigID == nil ? "新增一組配置" : "更新配置：\(name)") {
                    guard !name.isEmpty else {
                        tip="配置名稱 不可為空白"
                        // 可以顯示提示或直接 return
                        return
                    }
                    tip=""
                    if let id = selectedConfigID,
                       var config = manager.configs.first(where: { $0.id == id }) {
                        // 已選中 → 更新
                        config.name = name
                        config.rtmpURL = rtmpURL
                        config.streamKey = rtmpKey
                        manager.updateConfig(config)
                        manager.setActiveConfig(config)
                    } else {
                        // 未選中 → 新增
                        let newConfig = StreamConfig(name: name, rtmpURL: rtmpURL, streamKey: rtmpKey)
                        manager.addConfig(newConfig)
                        selectedConfigID = newConfig.id
                        manager.setActiveConfig(newConfig)
                    }
                }


                AnimatedButton(title:"新增空白配置") {
                    // 清空選中，準備新增
                    selectedConfigID = nil
                    name = "自訂"
                    rtmpURL = ""
                    rtmpKey = ""
                }





                if let selectedID = selectedConfigID,
                   let config = manager.configs.first(where: { $0.id == selectedID }) {

                    AnimatedButton(title: "複製當前配置 : \(config.name)") {
                        // 建立一個新的 StreamConfig，內容跟當前一樣，但 id 要新的
                        let copyConfig = StreamConfig(
                            name: config.name + " 複製",
                            rtmpURL: config.rtmpURL,
                            streamKey: config.streamKey
                        )

                        // 新增到 manager
                        manager.addConfig(copyConfig)

                        // 選中並設為激活
                        selectedConfigID = copyConfig.id
                        manager.setActiveConfig(copyConfig)

                        // 更新欄位顯示
                        name = copyConfig.name
                        rtmpURL = copyConfig.rtmpURL
                        rtmpKey = copyConfig.streamKey
                    }

                    AnimatedButton(title:"刪除配置：\(config.name)") {
                        if let index = manager.configs.firstIndex(where: { $0.id == selectedID }) {
                            manager.removeConfig(config)

                            if !manager.configs.isEmpty {
                                // 選下一個
                                let nextIndex = min(index, manager.configs.count - 1)
                                let nextConfig = manager.configs[nextIndex]

                                selectedConfigID = nextConfig.id
                                manager.setActiveConfig(nextConfig)

                                rtmpURL = nextConfig.rtmpURL
                                rtmpKey = nextConfig.streamKey
                                name = nextConfig.name
                            } else {
                                // 沒有任何配置
                                selectedConfigID = nil
                                manager.activeConfigID = nil
                                rtmpURL = ""
                                rtmpKey = ""
                                name = "自訂"
                            }
                        }
                    }


                } else {
                    AnimatedButton(title:"刪除配置") { }
                        .disabled(true)
                }
            }
        }
    }

    var body: some View {
#if os(macOS)
        con
            .frame(width: 500, height: 600)
#else

        NavigationView {
            con
                .navigationTitle("推流設定")
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Button("完成") {
                            if let id = manager.activeConfigID,
                               var config = manager.configs.first(
                                where: { $0.id == id
                                }) {

                                config.name = name
                                config.rtmpURL = rtmpURL
                                config.streamKey = rtmpKey

                                // 更新目前編輯的這組
                                rtmpURL = config.rtmpURL
                                rtmpKey = config.streamKey
                                manager.updateConfig(config)
                                manager.setActiveConfig(config)
                                logger.debug("Now active:\(rtmpURL) \(rtmpKey)")
                            }
                            dismiss()
                        }
                    }
                }
                .onAppear {
                    // 如果有 activeConfigID，優先使用
                    if let activeID = manager.activeConfigID {
                        selectedConfigID = activeID
                    } else if let firstID = manager.configs.first?.id {
                        // 沒有 activeConfig 時 fallback 為第一個
                        selectedConfigID = firstID
                        manager.setActiveConfig(manager.configs.first!)
                    } else {
                        // 完全沒有配置 → 清空
                        selectedConfigID = nil
                    }

                    // 同步欄位資料
                    if let id = selectedConfigID,
                       let config = manager.configs.first(where: { $0.id == id }) {
                        name = config.name
                        rtmpURL = config.rtmpURL
                        rtmpKey = config.streamKey
                    }
                }
                .onDisappear {
                    if let id = manager.activeConfigID,
                       var config = manager.configs.first(
                        where: { $0.id == id
                        }) {

                        config.name = name
                        config.rtmpURL = rtmpURL
                        config.streamKey = rtmpKey

                        // 更新目前編輯的這組
                        rtmpURL = config.rtmpURL
                        rtmpKey = config.streamKey
                        manager.updateConfig(config)
                        manager.setActiveConfig(config)
                        logger.debug("Disappear Now active:\(rtmpURL) \(rtmpKey)")
                    }
                }

        }
#endif
    }
}


enum H264Profile: String, CaseIterable, Identifiable {
    case baseline = "Baseline"
    case main = "Main"
    case high = "High"
    case AutoBaseline = "AutoBaseline"
    case AutoMain = "AutoMain"
    case AutoHigh = "AutoHigh"
    
    case constrainedBaseline = "ConstrainedBaseline"
    case constrainedHigh = "ConstrainedHigh"
    case extended = "Extended"


    var id: String { self.rawValue }
}

enum HEVCProfile: String, CaseIterable, Identifiable {
    case main = "Main"
    case main10 = "Main10"
    case main42210 = "Main42210"

    var id: String { self.rawValue }
}



struct homeView:View{
    @Environment(\.scenePhase) private var scenePhase

    @State private var showAlert = false
    @State private var showLocalAlert = false

    @State private var micStatus = "不知道"
    
    @AppStorage("logAppBackground",store:userDefaults) private var logAppBackground = false


    @AppStorage("h264level",store: userDefaults) var h264level: String = "AutoHigh"

    @AppStorage("videoCodec",store: userDefaults) var videoCodec: String = "H264"
    @AppStorage("hevcLevel",store: userDefaults) var hevcLevel: String = "Main"

    // 封裝成 Binding
    var selectedProfile: Binding<H264Profile> {
        Binding<H264Profile>(
            get: { H264Profile(rawValue: h264level) ?? .main },
            set: { h264level = $0.rawValue }
        )
    }

    var selectedHEVCProfile: Binding<HEVCProfile> {
        Binding<HEVCProfile>(
            get: { HEVCProfile(rawValue: hevcLevel) ?? .main },
            set: { hevcLevel = $0.rawValue }
        )
    }


    @AppStorage("rtmpURL",store: userDefaults) var rtmpURL: String = "rtmp://192.168.0.102/live"
    @AppStorage("rtmpKey",store: userDefaults) var rtmpKey: String = "stream1?vhost=live2"
    @AppStorage("broadcastExtension",store: userDefaults) var broadcastExtension: String = (Bundle.main.bundleIdentifier ?? "nuclear.liveAPP") + ".ReplyKIT"

    @StateObject var manager = BitrateManager()

    // iOS BroadcastButton
#if os(iOS)
    @State var StreamBtn = BroadcastButton(
        preferredExtension: userDefaults?.string(forKey: "broadcastExtension") ?? (Bundle.main.bundleIdentifier ?? "nuclear.liveAPP") + ".ReplyKIT",
        rtmpURL: "",
        rtmpKey: "",
        width: 50,
        height: 50
    )


#endif
    // macOS BroadcastButton
#if os(macOS)
    @StateObject private var StreamBtnMac = BroadcastButtonMac.Coordinator()

#endif





    init() {
        _ = userDefaults

        

        if rtmpURL.isEmpty && rtmpKey.isEmpty {
            rtmpURL="rtmp://192.168.0.102/live"
            rtmpKey="stream1?vhost=live2"
            // 如果沒有值就給預設值
        }



    }


#if os(iOS)
    private func checkMicrophonePermission() {
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
    private func checkMicrophonePermission() {
        print("notmake")
    }



#endif


    
    @State var lockDetect=false


    @State private var showForm = false
    @AppStorage("PauseStream",store: userDefaults) var PauseStream: Bool = false

    @StateObject private var permissionManager = LocalNetworkPermissionManager()




    var body:some View{

        ScrollView {
            VStack(spacing:20){

                ZStack(alignment: .topLeading) {
                    Color.clear // 或背景
                    Text("松鼠推流")
                        .font(.title)
                        .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack(alignment: .top, spacing: 16) {  // spacing 控制兩個區塊間距
                    VStack(spacing:10) {
                        Text("編碼配置")
                            .font(.headline)
                            .padding()

                        VStack {
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
                        }
                        .frame(maxWidth: .infinity) //

                        .fixedSize(horizontal: false, vertical: true) // 撐滿寬度，內容自適應高度
                        .padding()
#if os(iOS)
                        .background(Color(UIColor.secondarySystemGroupedBackground))
#elseif os(macOS)
                        .background(Color(NSColor.windowBackgroundColor))
#endif

                        .cornerRadius(8)


                        #if os(iOS)
                        Toggle("設備方向鎖定偵測",isOn:$lockDetect)
                            .onChange(of: lockDetect) { enabled in
                                if enabled {
                                    print("啟用")
                                    StableLockRotationDetector.shared.debugMode=true
                                    StableLockRotationDetector.shared.startMonitoring()
                                } else {
                                    StableLockRotationDetector.shared.stopMonitoring()
                                    print("停用偵測")
                                }
                            }
#endif
                        


                    }
                    .frame(maxWidth: .infinity)

                }
                .padding()

                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 10){
                        Text("基本配置")
                            .font(.headline)
                            .padding()

                        VStack {

                            Button("請求用於通信的本地網路") {
                                permissionManager.requestPermission {
                                    res in

                                    showLocalAlert = true
                                    
                                    if res {
                                        logTo("OK LocalNet")
                                    } else {
                                        logTo("Fail LocalNet")
                                    }
                                }


                            }.alert(
                                isPresented:$showLocalAlert
                            ) {
                                let resL = permissionManager.status
                                return Alert(
                                    title: Text("本地網路權限"),
                                      message: Text(resL),
                                      dismissButton: .default(Text("好")))

                            }

                            Button("請求麥克風") {
                                checkMicrophonePermission()
                            }.alert(isPresented: $showAlert) {
                                Alert(title: Text("麥克風權限"),
                                      message: Text(micStatus),
                                      dismissButton: .default(Text("好")))
                            }

                        }
                        .frame(maxWidth: .infinity) //
                        .fixedSize(horizontal: false, vertical: true) // 撐滿寬度，內容自適應高度
                        .padding()
                        #if os(iOS)
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        #elseif os(macOS)
                        .background(Color(NSColor.windowBackgroundColor))
                        #endif
                        .cornerRadius(8)

                    }
                    VStack(spacing: 10) {

                        VStack {

                            Toggle("暫停畫面",isOn: $PauseStream)
                                .onChange(of: PauseStream){ newVal in

                                    if newVal  == true {
                                        CFNotificationCenterPostNotification(
                                            cfCenter,
                                            CFNotificationName(
                                                "PauseStream" as CFString
                                            ),
                                            nil,
                                            nil,
                                            true
                                        )
                                    } else {
                                        CFNotificationCenterPostNotification(
                                            cfCenter,
                                            CFNotificationName(
                                                "ResumeStream" as CFString
                                            ),
                                            nil,
                                            nil,
                                            true
                                        )
                                    }

                                }

                        }
                        .onAppear{
                            if PauseStream == true {
                                CFNotificationCenterPostNotification(
                                    cfCenter,
                                    CFNotificationName(
                                        "PauseStream" as CFString
                                    ),
                                    nil,
                                    nil,
                                    true
                                )
                            }

                        }
                        .frame(maxWidth: .infinity) //

                        .fixedSize(horizontal: false, vertical: true) // 撐滿寬度，內容自適應高度

                        .padding()
#if os(iOS)
                        .background(Color(UIColor.secondarySystemGroupedBackground))
#elseif os(macOS)
                        .background(Color(NSColor.windowBackgroundColor))
#endif

                        .cornerRadius(8)

                    }
                    .frame(maxWidth: .infinity) // 撐滿右側空間


                }
                .padding()

                HStack (alignment: .center) {

                    Text("當前寬高：")
                    .padding()

                    HStack(spacing: 10) {
                        Button("橫向"){


                            CFNotificationCenterPostNotification(cfCenter,
                                                                 CFNotificationName("orientationV" as CFString),
                                                                 nil, nil, true)

                        }
                        Button("直向"){

                            CFNotificationCenterPostNotification(cfCenter,
                                                                 CFNotificationName("orientationH" as CFString),
                                                                 nil, nil, true)

                        }
                    }
                    .padding()
                    #if os(iOS)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    #elseif os(macOS)
                    .background(Color(NSColor.windowBackgroundColor))
                    #endif
                    .cornerRadius(8)

                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading) // ✅ 這裡讓 HStack 靠左


                HStack(alignment: .center , spacing: 16) {

                    HStack(spacing: 10) {
                        Button("輸入 RTMP 設定") {
                            showForm.toggle()
                        }
                        .padding()
                        .sheet(isPresented: $showForm) {
                            FormView()

                        }

                    }
                    .frame(maxWidth:.infinity,alignment: .center)

                    HStack(spacing: 10) {
                        // 測試顯示輸入的內容
                        if !rtmpURL.isEmpty && !rtmpKey.isEmpty {
                            Text("推流位址：\n\(rtmpURL)/")
                                .padding()
                                .multilineTextAlignment(.center)
                        }
                    }.frame(maxWidth:.infinity,alignment: .center)



                }.frame(maxWidth:.infinity,alignment: .leading)

                VStack(spacing: 10) {
                    Text("Bitrate: \(manager.bitrate / 1000 ) kbps 原始：\(manager.bitrate)")
                        .font(.headline)
                    
                    Text("Bitrate閘值：\(manager.multiplier) x \(manager.base)")

                    if #available(iOS 17.0, *) {
                        Slider(
                            value: Binding(
                                get: { Double(manager.multiplier) },
                                set: { manager.multiplier = Int($0) }
                            ),
                            in: 10...200,    // 10*100_000 = 1_000_000, 100*100_000 = 100_000_000
                            step: 1,
                            onEditingChanged : { editing in

                                if !editing {
                                    // ⚡ 這裡可以即時更新 bitrate

                                    let old = manager.multiplier * 100_000
                                    manager.bitrate = manager.multiplier * 100_000

                                    manager.updateStreamBitrate()

                                    sendlog(message:
                                        "Multiplier 改變: \(old) → 新的 bitrate: \(manager.bitrate)"
                                    )
                                }
                            }
                        )


                    }

                    HStack {
                        Text("1000 kbps")
                        Spacer()
                        Text("20000 kbps")
                    }
                }
                .padding()



                VStack {

#if os(iOS)
                    StreamBtn.frame(width: 0,height: 0)
                    Button(action: {



                        var g = rtmpKey
                        let replaceCount = min(5, g.count)
                        let endIndex = g.index(g.endIndex, offsetBy: -replaceCount)
                        let prefix = String(g[..<endIndex])

                        // 保留前 (replaceCount - 2) 個字，再補 "00"
                        if replaceCount > 2 {
                            let startOfReplace = g.index(g.endIndex, offsetBy: -replaceCount)
                            let midEnd = g.index(g.endIndex, offsetBy: -2)
                            let middle = g[startOfReplace..<midEnd]
                            g = prefix + middle + "00"
                        } else {
                            // 如果總長小於等於2，就全部換成0
                            g = String(repeating: "0", count: g.count)
                        }
                        
                        sendlog(message: "RTMP To:\(rtmpURL) \(g)")
                        StreamBtn.rtmpKey=rtmpKey
                        StreamBtn.rtmpURL=rtmpURL
                        StreamBtn.triggerButton()
                    }) {
                        Text("開始直播")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.blue)
                            .cornerRadius(8)
                    }
                    .padding(.horizontal)

#endif

#if os(macOS)
                    BroadcastButtonMac( coordinator: StreamBtnMac)


                    Button(action: {
                        StreamBtnMac.rtmpURL = rtmpURL
                        StreamBtnMac.rtmpKey = rtmpKey

                    }) {
                        Text("開始直播")
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
                .onChange(of: broadcastExtension) { newValue in
                    sendlog(title: "BroadcastButton", message: "broadcastExtension changed to: \(newValue)")
                    StreamBtn = BroadcastButton(
                        preferredExtension: newValue,
                        rtmpURL: StreamBtn.rtmpURL,
                        rtmpKey: StreamBtn.rtmpKey,
                        width: 50,
                        height: 50
                    )
                }

            }
        }
    }

}


enum AppPage {
    case home
    case settings
    case profile
    case about
    case log
    case testpage
    case fps
    case audio
    case PIPChat
    case tts
    case videoBitrate

}

final class PageState: ObservableObject {
    @Published var currentPage: AppPage = .home
    @Published var onAudioPage: Bool = false
    @Published var onlogPage: Bool = false
}

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
                .tabItem { Label("主頁", systemImage: "gear") }
                .tag(AppPage.home)



            DeviceView()
                .tabItem { Label("設備信息", systemImage: "cpu") }
                .tag(AppPage.testpage)

            LogView()
                .environmentObject(logModel)
                .tabItem { Label("日誌", systemImage: "apple.terminal") }
                .tag(AppPage.log)

            LiveVolumeView()
                .environmentObject(pageState)
                .tabItem { Label("音量", systemImage: "speaker.wave.2.circle.fill") }
                .tag(AppPage.audio)

            PIPView().tabItem { Label("聊天室", systemImage: "pip.enter") }
                .tag(AppPage.PIPChat)

            TTSSettingsView()
                .tabItem { Label("TTS", systemImage: "speaker.wave.2") }
                .tag(AppPage.tts)

            VideoBitrateView()
                .tabItem { Label("碼率", systemImage: "chart.bar.xaxis") }
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
                userDefaults?.synchronize()
                sendlog(message:"onAudioPage: \(onAudioPage)")
                CFNotificationCenterPostNotification(cfCenter, CFNotificationName("onAudioPage" as CFString), nil, nil, true)
            } else {
                pageState.onAudioPage = false
                onAudioPage = false
                userDefaults?.synchronize()
                sendlog(message:"onAudioPage: \(onAudioPage)")
                CFNotificationCenterPostNotification(cfCenter, CFNotificationName("onAudioPage" as CFString), nil, nil, true)
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
                        userDefaults?.synchronize()

                        CFNotificationCenterPostNotification(cfCenter,
                                                             CFNotificationName("onAudioPage" as CFString),
                                                             nil, nil, true)

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
                    userDefaults?.synchronize()

                    CFNotificationCenterPostNotification(cfCenter,
                                                         CFNotificationName("onAudioPage" as CFString),
                                                         nil, nil, true)

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
