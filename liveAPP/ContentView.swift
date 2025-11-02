//
//  ContentView.swift
//  liveAPP
//
//  Created by user on 2025/8/24.
//

import ReplayKit
import SwiftUI



import os
import Foundation

let logger = Logger(subsystem: "nuclear.liveAPP", category: "extension")

let cfCenter = CFNotificationCenterGetDarwinNotifyCenter()


#if os(iOS)
let userDefaults: UserDefaults? = UserDefaults(suiteName: "group.nuclear.liveAPP")
#else
let userDefaults: UserDefaults = .standard
#endif

func syncUserDefault() {
#if os(iOS)
    userDefaults?.synchronize()
#else
    userDefaults.synchronize()
#endif
}
func setUserDefault<T>(_ value: T, forKey key: String) {
#if os(iOS)
    userDefaults?.set(value, forKey: key)
#else
    userDefaults.set(value, forKey: key)
#endif
}

func getUserDefault<T>(forKey key: String) -> T? {
#if os(iOS)
    guard let userDefaults = userDefaults else { return nil }
#endif

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
}





// ObservableObject 管理碼率
class BitrateManager: ObservableObject {
    @Published var multiplier: Int = 39 {
        didSet {
            updateStreamBitrate()
        }
    }

    let base: Int = 100_000       // 每單位 100 kbps
    @Published var bitrate: Int = 3900000    // 實際 bps

    init() {
        // 嘗試讀取 UserDefaults 的保存值

        if let saved: Int = getUserDefault(forKey: "bitRate"), saved != 0 {
            bitrate = saved
        } else {
            bitrate = base * multiplier
            saveBitrate()
        }

    }

    func saveBitrate() {
        setUserDefault(bitrate, forKey: "bitRate")
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
    var preferredExtension: String  // 你的 Broadcast Upload Extension Bundle ID
    var rtmpURL: String              // 要推流的 RTMP 地址
    var rtmpKey: String
    var width: CGFloat
    var height: CGFloat
    var base:Int = 100_000
    var multiplier:Int = 34


    // 存內部 Coordinator
    private class CoordinatorWrapper {
        var coordinator: Coordinator?
    }
    private let wrapper = CoordinatorWrapper()


    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        //        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        let picker = RPSystemBroadcastPickerView(frame: .zero)
        picker.preferredExtension = preferredExtension
        picker.showsMicrophoneButton = true
        picker.isHidden=true


        //監聽按下事件
        for view in picker.subviews {
            if let button = view as? UIButton {
                button.addTarget(context.coordinator, action: #selector(Coordinator.buttonTapped), for: .touchUpInside)
                context.coordinator.button = button
            }
        }

        // 保存 Coordinator
        wrapper.coordinator = context.coordinator
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) { }

    func makeCoordinator() -> Coordinator {
        Coordinator(rtmpURL: rtmpURL, rtmpKey:rtmpKey)
    }

    // 新增：公開觸發方法
    func triggerButton() {
        wrapper.coordinator?.triggerButton()
    }

    class Coordinator: NSObject {
        let rtmpURL: String
        let rtmpKey: String
        var UR:UIDeviceOrientation = .unknown
        weak var button: UIButton?

        init(rtmpURL: String,rtmpKey:String) {
            self.rtmpURL = rtmpURL
            self.rtmpKey = rtmpKey
        }

        @objc func buttonTapped() {


            UR=UIDevice.current.orientation
            logger.info("ROTATE:\(String(describing:self.UR))")
            userDefaults?.set(self.UR.rawValue,forKey: "L3Rotate")
            userDefaults?.synchronize()

        }
        func triggerButton() {
            button?.sendActions(for: .touchUpInside)
        }
    }
}
#endif

struct CircleGridView: View {

    @State var isOn=false
    @State var mode="A"


    let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
    let items = Array(1...16) // 模擬表單格子數量

    var body: some View {

        //        LazyVGrid(columns: columns, spacing: 10) {
        //            ForEach(items, id: \.self) { item in
        //                ZStack {
        //                    Text("\(item)")
        //                        .foregroundColor(.white)
        //                        .bold()
        //                }
        //            }
        //        }
        //        .padding()
        //

        VStack {
            NavigationView {
                List {
                    NavigationLink(destination: Text("編輯頁面 1")) {
                        HStack {
                            Text("姓名")
                            Spacer()
                            Text("John")
                                .foregroundColor(.gray)
                        }
                    }
                    NavigationLink(destination: Text("編輯頁面 2")) {
                        HStack {
                            Text("電話")
                            Spacer()
                            Text("123-4567")
                                .foregroundColor(.gray)
                        }
                    }
                }
                .navigationTitle("表單")
            }

            Form {
                Section(header: Text("帳號設定")) {
                    Text("用戶名稱：小明")   // 純顯示
                    Toggle("通知", isOn: $isOn)  // 有選項
                    Picker("模式", selection: $mode) {
                        Text("A").tag("A")
                        Text("B").tag("B")
                    }
                }
            }
            List {
                Text("純文字顯示")
                HStack {
                    Image(systemName: "star")
                    Text("帶圖片的選項")
                }
            }.scrollDisabled(true)


        }
    }
}

import Combine

class LiveVolumeModel: ObservableObject {

    @Published var micVolumeLive: Float = 0.0
    @Published var appVolumeLive: Float = 0.0

    init() {
#if os(iOS)
        // 註冊 Darwin Notification


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

#else
        NotificationCenter.default.addObserver(
            forName: Notification.Name("LiveVolumeUpdated"),
            object: nil,
            queue: .main
        ) { _ in

            DispatchQueue.main.async {
                self.micVolume = getUserDefault(forKey: "micVolumeLive") ?? 0.0
                self.appVolume = getUserDefault(forKey: "appVolumeLive") ?? 0.0
            }

        }
#endif
    }


    deinit {
#if os(iOS)
        CFNotificationCenterRemoveEveryObserver(cfCenter, UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()))

#else
        NotificationCenter.default.removeObserver(self)
#endif
    }
}


/// UI 百分比 (0~1) → 真實音量 (0~1)，曲線控制低音量更細膩
func percentageToVolume(_ percentage: Double) -> Double {
    let clamped = max(0, min(1, percentage))

    // 指數曲線 exponent < 1 → 前段變化慢，後段變化快
    let exponent: Double = 2.5
    return pow(clamped, exponent)
}

/// 真實音量 (0~1) → UI 百分比 (0~1)
func volumeToPercentage(_ volume: Double) -> Double {
    let clamped = max(0, min(1, volume))
    let exponent: Double = 2.5
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


    @StateObject var model = LiveVolumeModel()

    @AppStorage("appVoulme",store: userDefaults)  var appVolume: Double = 1.0
    @AppStorage("micVoulme",store: userDefaults)  var micVolume: Double = 1.0

    @AppStorage("appAddVoulme",store: userDefaults)  var appAddVolume: Double = 1.0
    @AppStorage("micAddVoulme",store: userDefaults)  var micAddVolume: Double = 1.0



    init(){

    }

    var body: some View {


        VStack {
            VStack {
                Text("App增益: \(String(format: "%.1f", appAddVolume)) 倍")
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
                Text("App音量: \(String(format: "%.0f%%", volumeToPercentage(appVolume) * 100) )")
                    .font(.headline)



                Slider(
                    value:
                        Binding(
                    get: { volumeToPercentage(appVolume) },            // 從 appVolume 轉百分比
                    set: { newValue in
                        appVolume = percentageToVolume(newValue)      // 將百分比轉回 appVolume
                        }
                    )
                        , in: 0...1, step: 0.01,
                       onEditingChanged: { editing in

                    if !editing {
                        //let realVolume = percentageToVolume(APP_percentage)
                        setUserDefault( appVolume , forKey: "appVolume")



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
                            volumeToPercentage(appVolume),
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

                //Old自繪進度條
                //                #if os(iOS)
                //                ProgressView(value: percentageToVolume(APP_percentage))
                //                    .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                //                #endif

                // 自繪進度條 (取代 ProgressView)
                SafeProgressBar(value: appVolume, color: .blue)
                    .padding(.vertical, 4)




            }



            VStack {
                Text("Mic音量: \(String(format: "%.0f%%", volumeToPercentage(micVolume) * 100 ))")
                    .font(.headline)


                Slider(value:
                        Binding(
                    get: { volumeToPercentage(micVolume) },            // 從 micVolume 轉百分比
                    set: { newValue in
                        micVolume = percentageToVolume(newValue)      // 將百分比轉回 micVolume
                        }
                    )

                       , in: 0...1, step: 0.01,
                       onEditingChanged: { editing in

                    if !editing {
                        //let realVolume = percentageToVolume(Mic_percentage)
                        sendlog(message: String(
                            format: "麥克風音量更新: %.2f%% (真實值: %.5f)",
                            volumeToPercentage(micVolume),
                            micVolume
                        ))
                        setUserDefault(micVolume, forKey: "micVolume")


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

            Button("儲存音量") {
                setUserDefault(appVolume, forKey: "appVolume")
                setUserDefault(micVolume, forKey: "micVolume")


#if os(iOS)

                CFNotificationCenterPostNotification(cfCenter, CFNotificationName("micVolumeChanged" as CFString), nil, nil, true)
                CFNotificationCenterPostNotification(cfCenter, CFNotificationName("appVolumeChanged" as CFString), nil, nil, true)
#else
                NotificationCenter.default.post(name: Notification.Name("appVolumeChanged"), object: nil)
                NotificationCenter.default.post(name: Notification.Name("micVolumeChanged"), object: nil)
#endif


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











struct GPUOutputConfig: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var width: Int
    var height: Int

    init(id: UUID = UUID(), name: String, width: Int, height: Int) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
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
                UserDefaults.standard.removeObject(forKey: userDefaultsSelectKey)
                return
            }
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(config) {
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


    @StateObject private var gpuSettings = GPUSettingsViewModel()



    var body: some View {
        NavigationView {
            Form {
                
                LogSettingView()
                NavigationLink("GPU旋轉處理設置") {
                   GPURotateView(viewModel: gpuSettings)
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
                }


            }
            .navigationTitle("設定日誌服務器")
            .onAppear {
                tempEndpoint = logURL
            }
            .onDisappear {
                logURL = tempEndpoint.trimmingCharacters(in: .whitespaces)
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



// MARK: 高效能 Log 顯示 TextView（避免 SwiftUI ScrollView 卡頓）
struct LogTextView: UIViewRepresentable {
    let messages: [String]

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = UIColor.systemBackground
        textView.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = UIColor.label
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        textView.alwaysBounceVertical = true
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // 將 messages 轉成一整段文字（避免逐行 diff）
        uiView.text = messages.joined(separator: "\n")
        // 自動捲到底部
        let bottom = NSMakeRange(uiView.text.count - 1, 1)
        uiView.scrollRangeToVisible(bottom)
    }
}

struct logView: View {
    @EnvironmentObject var logModel: LogModel

    @AppStorage("logMode",store:userDefaults) private var logMode = 1
    @State private var showLogSettings = false


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
                // 清空 log.txt 檔案
                 if let containerURL =
                    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.nuclear.liveAPP") {
                     let logURL = containerURL.appendingPathComponent("log.txt")
                     do {
                         try "".write(to: logURL, atomically: true, encoding: .utf8)
                         sendlog(message: "✅ log.txt 已清空")
                     } catch {
                         sendlog(message: "❌ 無法清空 log.txt：\(error)")
                     }
                 } else {
                     sendlog(message: "❌ 無法取得 containerURL")
                 }
            }


            LogTextView(messages: logModel.messages.map(\.message))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        }
    }
}

class RTMPSetting {
    var rtmp:String
    init(){
        self.rtmp="test"
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
    @AppStorage("rtmpKey",store: userDefaults)  var rtmpKey: String=""
    //   @State var rtmpURL: String = ""
    //    @State var rtmpKey: String = ""
    //


    @State var name:String = "自訂"
    @State var tip:String = ""

    @State private var selectedConfigID: UUID?
    var con: some View{
        List {
            Section(header: Text("選擇配置")) {

                if #available(iOS 17.0, *) {
                    Picker("配置", selection: $selectedConfigID) {
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
                            if let id = selectedConfigID,
                               var config = manager.configs.first(where: { $0.id == id }) {
                                // 更新目前編輯的這組
                                config.rtmpURL = rtmpURL
                                config.streamKey = rtmpKey
                                manager.updateConfig(config)
                                manager.setActiveConfig(config)
                            }
                            dismiss()
                        }
                    }
                }
                .onAppear {
                    if let active = manager.activeConfig {

                        selectedConfigID = active.id
                        rtmpURL = active.rtmpURL
                        rtmpKey = active.streamKey
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
    case constrainedBaseline = "ConstrainedBaseline"
    case constrainedHigh = "ConstrainedHigh"
    case extended = "Extended"


    var id: String { self.rawValue }
}



struct homeView:View{
    @Environment(\.scenePhase) private var scenePhase

    @State private var showAlert = false
    @State private var micStatus = "不知道"
    @AppStorage("logAppBackground",store:userDefaults) private var logAppBackground = false


    @AppStorage("h264level",store: userDefaults) var h264level: String = "Main"

    // 封裝成 Binding
    var selectedProfile: Binding<H264Profile> {
        Binding<H264Profile>(
            get: { H264Profile(rawValue: h264level) ?? .main },
            set: { h264level = $0.rawValue }
        )
    }


    @AppStorage("rtmpURL",store: userDefaults) var rtmpURL: String = "rtmp://192.168.0.102/live"
    @AppStorage("rtmpKey",store: userDefaults) var rtmpKey: String = "stream1?vhost=live2"

    @StateObject var manager = BitrateManager()

    // iOS BroadcastButton
#if os(iOS)
    @State var StreamBtn = BroadcastButton(
        preferredExtension: "nuclear.liveAPP.ReplyKIT",
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


    @State var lockIN:Bool=getUserDefault(forKey:"LockIN") ?? true
    @State var lockDetect=false
    @State var videoRotate=true
    @State private var showForm = false
    @AppStorage("PauseStream",store: userDefaults) var PauseStream: Bool = false



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
                        Text("H264配置")
                            .font(.headline)
                            .padding()

                        VStack(){
                            Picker("H264配置", selection: selectedProfile) {
                                ForEach(H264Profile.allCases) { profile in
                                    Text(profile.rawValue).tag(profile)
                                }
                            }
                            .pickerStyle(.menu)

                            // 可以改成 MenuPickerStyle、WheelPickerStyle 等



                            Text("當前選擇:  \(selectedProfile.wrappedValue.rawValue)")

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


                    .frame(maxWidth: .infinity)




                    VStack(spacing:10){

                        Text("旋轉控制").font(.headline)
                            .padding()
                        VStack(alignment: .leading){

                            if #available(iOS 17.0, *) {
                                Toggle("停用自動偵測旋轉",isOn: $lockIN)
                                    .onChange(of: lockIN) {
                                        old,
                                        newValue in

                                        print("LockIN \(newValue)")

                                        setUserDefault(newValue,forKey:"LockIN")
                                        //syncUserDefault()


                                        CFNotificationCenterPostNotification(
                                            cfCenter,
                                            CFNotificationName(
                                                "orientationChanged" as CFString
                                            ),
                                            nil,
                                            nil,
                                            true
                                        )


                                    }
                            } else {
                                // Fallback on earlier versions
                                Toggle("停用自動偵測旋轉",isOn: $lockIN)
                                    .onChange(of: lockIN) {

                                        newValue in

                                        print("LockIN \(newValue)")

                                        setUserDefault(newValue,forKey:"LockIN")
                                        //syncUserDefault()



                                        CFNotificationCenterPostNotification(
                                            cfCenter,
                                            CFNotificationName(
                                                "orientationChanged" as CFString
                                            ),
                                            nil,
                                            nil,
                                            true
                                        )


                                    }
                            }

                            if #available(iOS 17.0, *) {
                                Toggle("自動旋轉視頻",isOn: $videoRotate)
                                    .onChange(of: videoRotate) {
                                        old,
                                        newValue in

                                        print("RotateVideo \(newValue)")

                                        setUserDefault(
                                            newValue,
                                            forKey:"VideoRotate"
                                        )
                                        //syncUserDefault()




                                        CFNotificationCenterPostNotification(
                                            cfCenter,
                                            CFNotificationName(
                                                "videoRotateChanged" as CFString
                                            ),
                                            nil,
                                            nil,
                                            true
                                        )


                                    }
                            } else {
                                // Fallback on earlier versions
                                Toggle("自動旋轉視頻",isOn: $videoRotate)
                                    .onChange(of: videoRotate) {

                                        newValue in

                                        print("RotateVideo \(newValue)")

                                        setUserDefault(
                                            newValue,
                                            forKey:"VideoRotate"
                                        )
                                        //syncUserDefault()




                                        CFNotificationCenterPostNotification(
                                            cfCenter,
                                            CFNotificationName(
                                                "videoRotateChanged" as CFString
                                            ),
                                            nil,
                                            nil,
                                            true
                                        )


                                    }
                            }


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
                .padding(.horizontal)

                VStack(spacing: 10) {

                    VStack(alignment: .leading) {

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
                .padding()
                
                HStack (alignment: .firstTextBaseline) {

                    


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
                    Text("當前寬高：")

                    VStack(alignment: .leading,spacing: 8) {
                        // 麥克風授權 + BroadcastButton
                        Button("請求麥克風") {
                            checkMicrophonePermission()
                        }.alert(isPresented: $showAlert) {
                            Alert(title: Text("麥克風權限"),
                                  message: Text(micStatus),
                                  dismissButton: .default(Text("好")))
                        }



                    }
                    .padding()

#if os(iOS)
                    .background(Color(UIColor.secondarySystemBackground))
#elseif os(macOS)
                    .background(Color(NSColor.windowBackgroundColor))

#endif
                    .cornerRadius(8)



                }
                .padding()


                VStack {
                    Button("輸入 RTMP 設定") {
                        showForm.toggle()
                    }
                    .padding()
                    .sheet(isPresented: $showForm) {
                        FormView()

                    }

                    // 測試顯示輸入的內容
                    if !rtmpURL.isEmpty && !rtmpKey.isEmpty {
                        Text("推流位址：\n\(rtmpURL)/")
                            .padding()
                            .multilineTextAlignment(.center)
                    }
                }


                VStack(spacing: 20) {
                    Text("Bitrate: \(manager.bitrate / 1000) kbps")
                        .font(.headline)

                    if #available(iOS 17.0, *) {
                        Slider(
                            value: Binding(
                                get: { Double(manager.multiplier) },
                                set: { manager.multiplier = Int($0) }
                            ),
                            in: 10...100,    // 10*100_000 = 1_000_000, 100*100_000 = 100_000_000
                            step: 1
                        )
                        .onChange(
                            of: manager.multiplier
                        ) {
                            oldValue,
                            newValue in
                            // ⚡ 這裡可以即時更新 bitrate
                            manager.bitrate = newValue * 100_000
                            logger.info(
                                "Multiplier 改變: \(oldValue) → \(newValue)，新的 bitrate: \(manager.bitrate)"
                            )
                        }
                    } else {
                        // Fallback on earlier versions
                    }


                    HStack {
                        Text("1000 kbps")
                        Spacer()
                        Text("10000 kbps")
                    }
                }
                .padding(

                )

                VStack {

#if os(iOS)
                    StreamBtn.frame(width: 0,height: 0)
                    Button(action: {


                        var g = rtmpKey
                        let endIndex = g.index(g.endIndex, offsetBy: -5)
                        g = String(g[..<endIndex]) + "00000"


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

}

final class PageState: ObservableObject {
    @Published var currentPage: AppPage = .home
    @Published var onAudioPage: Bool = false
    @Published var onlogPage: Bool = false



    // 當 currentPage 改變時自動更新 onAudioPage
    private var cancellables = Set<AnyCancellable>()

    init() {
        $currentPage
            .sink { [weak self] page in
                self?.onAudioPage = (page == .audio)
                self?.onlogPage = (page == .log)
            }
            .store(in: &cancellables)
    }
}

struct ContentView: View {

    @Environment(\.scenePhase) private var scenePhase

    
    @EnvironmentObject var logModel: LogModel

    @StateObject private var pageState = PageState()


    @AppStorage("onlogPage",store:userDefaults) private var onlogPage = false



    @AppStorage("onAudioPage",store:userDefaults) private var onAudioPage = false




    init(){
        onAudioPage=false
    }


    var body: some View {

        TabView(selection: $pageState.currentPage) {

            homeView()
                .tabItem { Label("主頁", systemImage: "gear") }
                .tag(AppPage.home)



            CircleGridView()
                .tabItem { Label("測試頁", systemImage: "testtube.2") }
                .tag(AppPage.testpage)

            logView()
                .environmentObject(logModel)
                .tabItem { Label("日誌", systemImage: "apple.terminal") }
                .tag(AppPage.log)

            LiveVolumeView()
                .environmentObject(pageState)
                .tabItem { Label("音量", systemImage: "speaker.wave.2.circle.fill") }
                .tag(AppPage.audio)

            PIPView().tabItem { Label("聊天室", systemImage: "pip.enter") }
                .tag(AppPage.PIPChat)

        }
        // ✅ 當選到音量分頁時啟用監聽
        .onChange(of: pageState.currentPage) { newValue in
            sendlog(message:"Page:\(newValue)")

            pageState.currentPage = newValue

            if newValue == .log {

                print("onlog:\(onlogPage)")

                onlogPage=true

                CFNotificationCenterPostNotification(cfCenter, CFNotificationName("onlogPage" as CFString), nil, nil, true)


            }else {

                onlogPage=false
                CFNotificationCenterPostNotification(cfCenter, CFNotificationName("onlogPage" as CFString), nil, nil, true)



            }
            if newValue == .audio {

                onAudioPage=true
                sendlog(message:"true page \(onAudioPage)")

                CFNotificationCenterPostNotification(cfCenter,
                                                     CFNotificationName("onAudioPage" as CFString),
                                                     nil, nil, true)
            } else {


                onAudioPage=false
                sendlog(message:"false page \(onAudioPage)")


                CFNotificationCenterPostNotification(cfCenter,
                                                     CFNotificationName("onAudioPage" as CFString),
                                                     nil, nil, true)
                }


        }


        .onChange(of: scenePhase ){
                newPhase in

            switch newPhase {
            case .active:

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

                        CFNotificationCenterPostNotification(cfCenter,
                                                             CFNotificationName("onAudioPage" as CFString),
                                                             nil, nil, true)

                        sendlog(message: "正在App AudioPage")
                    }
                }

            case .background:



                if onlogPage == true {
                    sendlog(message: "應用已進入後台App 停止更新logPage")
                    onlogPage=false
                    CFNotificationCenterPostNotification(cfCenter, CFNotificationName("onlogPage" as CFString), nil, nil, true)


                }
                if onAudioPage == true {
                    onAudioPage=false

                    CFNotificationCenterPostNotification(cfCenter,
                                                         CFNotificationName("onAudioPage" as CFString),
                                                         nil, nil, true)

                    sendlog(message: "應用已進入後台App 停止監聽AudioPage")

                }

            case .inactive:

                if onAudioPage == true {
                    onAudioPage=false

                    CFNotificationCenterPostNotification(cfCenter,
                                                         CFNotificationName("onAudioPage" as CFString),
                                                         nil, nil, true)

                    sendlog(message: "正在離開App 停止監聽AudioPage")
                }

            @unknown default:
                if onlogPage == true {
                    sendlog(message: "應用已進入後台App 停止更新logPage")
                    onlogPage=false

                }
                if onAudioPage == true {
                    onAudioPage=false


                    CFNotificationCenterPostNotification(cfCenter,
                                                         CFNotificationName("onAudioPage" as CFString),
                                                         nil, nil, true)
                }

            }
        }


    }
}

#Preview {
    ContentView()
}
