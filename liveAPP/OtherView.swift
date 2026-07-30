//
//  OtherView.swift
//  liveAPP
//
//  Created by user on 2026/2/16.
//


import SwiftUI
import Charts
import Combine
import MachO
import Metal
import UIKit
import SystemConfiguration

struct DataPoint: Identifiable {
    let id: Int
    let time: Date
    let value: Double
}

struct DeviceInfo {

    // 屏幕寬高獲取本身寬高 剛好是反過來
    static let nativeWidth = UIScreen.main.nativeBounds.height
    static let nativeHeight = UIScreen.main.nativeBounds.width

    static var cpuUsagePercent: Double {
        var threads: thread_act_array_t?
        var threadCount = mach_msg_type_number_t()

        let task = mach_task_self_

        guard task_threads(task, &threads, &threadCount) == KERN_SUCCESS,
              let threadList = threads else {
            return 0
        }

        var totalUsage: Double = 0

        for i in 0..<Int(threadCount) {
            let thread = threadList[i]
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(THREAD_INFO_MAX)

            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(thread,
                                thread_flavor_t(THREAD_BASIC_INFO),
                                $0,
                                &infoCount)
                }
            }

            if kr == KERN_SUCCESS {
                if info.flags & TH_FLAGS_IDLE == 0 {
                    totalUsage += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
                }
            }

            mach_port_deallocate(mach_task_self_, thread)
        }

        vm_deallocate(
            mach_task_self_,
            vm_address_t(bitPattern: threadList),
            vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.stride)
        )

        return totalUsage
    }

    static let cpuName: String = {
        if let device = MTLCreateSystemDefaultDevice() {
            return device.name
        }
        return "No Metal"
    }()

    static var gpuVendor: String {
        guard let device = MTLCreateSystemDefaultDevice() else { return "N/A" }
        #if targetEnvironment(simulator)
        return "Simulator"
        #else
        switch device.registryID {
        case 0...: break
        default: break
        }
        if device.supportsFamily(.apple1) { return "Apple" }
        if device.name.contains("Intel") { return "Intel" }
        if device.name.contains("AMD") { return "AMD" }
        return "Unknown"
        #endif
    }

    static let cpuCount = ProcessInfo.processInfo.processorCount
    static let ramMB = Double(ProcessInfo.processInfo.physicalMemory) / 1024 / 1024
    static let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    static let systemUptime = ProcessInfo.processInfo.systemUptime

    static var deviceCode: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }

    static var appMemoryMB: Double {
        Double(memoryUsage()) / 1024 / 1024
    }

    private static func memoryUsage() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                          task_flavor_t(MACH_TASK_BASIC_INFO),
                          $0,
                          &count)
            }
        }

        return kerr == KERN_SUCCESS ? info.resident_size : 0
    }

    static var totalDiskMB: Double {
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let size = attrs[.systemSize] as? NSNumber {
            return Double(size.int64Value) / 1024 / 1024
        }
        return 0
    }

    /// 可用空間（含可清除快取），接近裝置設定顯示值
    static var availableDiskMB: Double {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage
        else { return 0 }
        return Double(capacity) / 1024 / 1024
    }

    /// 真正空閒空間（不含可清除快取）
    static var freeDiskMB: Double {
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attrs[.systemFreeSize] as? NSNumber {
            return Double(free.int64Value) / 1024 / 1024
        }
        return 0
    }

    static let networkInterface: String = {
        #if targetEnvironment(simulator)
        return "Simulator"
        #else
        guard let reachability = SCNetworkReachabilityCreateWithName(nil, "apple.com") else {
            return "No Connection"
        }
        var flags = SCNetworkReachabilityFlags()
        SCNetworkReachabilityGetFlags(reachability, &flags)
        if flags.contains(.isWWAN) { return "Cellular" }
        if flags.contains(.reachable) { return "WiFi" }
        return "No Connection"
        #endif
    }()

    static var batteryLevel: Int {
        UIDevice.current.isBatteryMonitoringEnabled = true
        return Int(UIDevice.current.batteryLevel * 100)
    }

    static var batteryState: String {
        UIDevice.current.isBatteryMonitoringEnabled = true
        switch UIDevice.current.batteryState {
        case .unplugged: return "Unplugged"
        case .charging: return "Charging"
        case .full: return "Full"
        default: return "Unknown"
        }
    }
}



class SystemCPU {

    private var prevUser: UInt32 = 0
    private var prevSystem: UInt32 = 0
    private var prevIdle: UInt32 = 0
    private var prevNice: UInt32 = 0

    func usage() -> (user: Double, system: Double, idle: Double)? {

        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var cpuInfo = host_cpu_load_info()

        let result = withUnsafeMutablePointer(to: &cpuInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(),
                                HOST_CPU_LOAD_INFO,
                                $0,
                                &size)
            }
        }

        guard result == KERN_SUCCESS else { return nil }

        let user = cpuInfo.cpu_ticks.0
        let system = cpuInfo.cpu_ticks.1
        let idle = cpuInfo.cpu_ticks.2
        let nice = cpuInfo.cpu_ticks.3

        let deltaUser = user - prevUser
        let deltaSystem = system - prevSystem
        let deltaIdle = idle - prevIdle
        let deltaNice = nice - prevNice

        let total = deltaUser + deltaSystem + deltaIdle + deltaNice

        prevUser = user
        prevSystem = system
        prevIdle = idle
        prevNice = nice

        guard total > 0 else { return nil }

        return (
            user: Double(deltaUser) / Double(total) * 100,
            system: Double(deltaSystem) / Double(total) * 100,
            idle: Double(deltaIdle) / Double(total) * 100
        )
    }
}


final class SystemDiskIO {
    private var prevPageIns: natural_t = 0
    private var prevPageOuts: natural_t = 0
    private var firstSample = true
    private let pageSizeKB: Double = {
        let pagesize = Int(sysconf(_SC_PAGESIZE))
        return pagesize > 0 ? Double(pagesize) / 1024.0 : 16.0
    }()

    func rates() -> (pageInKBps: Double, pageOutKBps: Double) {
        var stats = vm_statistics()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics_data_t>.size / MemoryLayout<integer_t>.size)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_VM_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }

        if firstSample {
            firstSample = false
            prevPageIns = stats.pageins
            prevPageOuts = stats.pageouts
            return (0, 0)
        }

        let deltaIn = stats.pageins - prevPageIns
        let deltaOut = stats.pageouts - prevPageOuts
        prevPageIns = stats.pageins
        prevPageOuts = stats.pageouts

        return (Double(deltaIn) * pageSizeKB, Double(deltaOut) * pageSizeKB)
    }
}

struct DeviceView: View {

    let cpuInfo = SystemCPU()
    let diskIO = SystemDiskIO()
    @ObservedObject private var laManager = StreamActivityManager.shared

    @State private var appMemoryMB: Double = 0
    @State private var cpuHistory: [DataPoint] = []
    @State private var memoryHistory: [DataPoint] = []
    @State private var pageInHistory: [DataPoint] = []
    @State private var pageOutHistory: [DataPoint] = []
    @State private var appWriteHistory: [DataPoint] = []
    @State private var prevAppWriteBytes: UInt64 = 0
    @State private var dataPointCounter = 0
    @State private var sampleTimer: Timer?

    @AppStorage("ReplyKitWidth",store: userDefaults) var ReplyKitW: Int = 0
    @AppStorage("ReplyKitHeight",store: userDefaults) var ReplyKitH: Int = 0

    private let maxHistory = 60

    var body: some View {
        List {

            Section(header:
                        Label("螢幕 Screen", systemImage: "ipad.landscape")
            ) {
                Text("寬: \(DeviceInfo.nativeWidth, specifier: "%.0f") pt")
                Text("高: \(DeviceInfo.nativeHeight, specifier: "%.0f") pt")
            }

            Section(header:
                        Label("ReplyKit 輸出",systemImage: "play.display")
            ) {
                Text("寬: \(ReplyKitW) px")
                Text("高: \(ReplyKitH) px")
                Text("開播後自動更新")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(
                header:
                    Label("CPU", systemImage: "cpu")
            ) {
                if let usage = cpuInfo.usage() {
                    Text("用戶: \(usage.user, specifier: "%.1f")%  系統: \(usage.system, specifier: "%.1f")%  閒置: \(usage.idle, specifier: "%.1f")%")
                        .font(.caption)

                    Chart {
                        ForEach(cpuHistory) { pt in
                            LineMark(
                                x: .value("Time", pt.time),
                                y: .value("CPU", pt.value)
                            )
                            .foregroundStyle(.orange)
                        }
                    }
                    .chartYAxisLabel("App CPU %")
                    .frame(height: 120)
                }

                Text("App 使用率: \(DeviceInfo.cpuUsagePercent, specifier: "%.1f") %")
                Text("處理器: \(DeviceInfo.cpuName)")
                Text("核心數: \(DeviceInfo.cpuCount)")
                Text("裝置代號: \(DeviceInfo.deviceCode)")
            }

            Section(
                header:
                    Label("記憶體 RAM", systemImage: "memorychip")
            ) {
                Text("總 RAM: \(DeviceInfo.ramMB, specifier: "%.0f") MB")
                Text("App 使用中: \(appMemoryMB, specifier: "%.1f") MB")
                    .foregroundColor(appMemoryMB > 300 ? .orange : .primary)

                Chart {
                    ForEach(memoryHistory) { pt in
                        LineMark(
                            x: .value("Time", pt.time),
                            y: .value("Memory", pt.value)
                        )
                        .foregroundStyle(.blue)
                    }
                }
                .chartYAxisLabel("MB")
                .frame(height: 120)
            }

            Section(
                header:
                    Label("儲存空間", systemImage: "externaldrive")
            ) {
                let total = DeviceInfo.totalDiskMB
                let available = DeviceInfo.availableDiskMB
                let free = DeviceInfo.freeDiskMB
                let used = total - available
                Text("總容量: \(total / 1024, specifier: "%.1f") GB")
                Text("已使用: \(used / 1024, specifier: "%.1f") GB")
                Text("可用（含可清除）: \(available / 1024, specifier: "%.1f") GB")
                    .foregroundColor(available < 1024 ? .orange : .primary)
                Text("空閒（真正）: \(free / 1024, specifier: "%.1f") GB")
                    .foregroundColor(free < 512 ? .orange : .secondary)
            }

            Section(
                header:
                    Label("磁碟 I/O", systemImage: "internaldrive")
            ) {
                Chart {
                    ForEach(pageInHistory) { pt in
                        LineMark(
                            x: .value("Time", pt.time),
                            y: .value("KB/s", pt.value),
                            series: .value("Series", "Page In")
                        )
                        .foregroundStyle(.blue)
                    }
                    ForEach(pageOutHistory) { pt in
                        LineMark(
                            x: .value("Time", pt.time),
                            y: .value("KB/s", pt.value),
                            series: .value("Series", "Page Out")
                        )
                        .foregroundStyle(.red)
                    }
                    ForEach(appWriteHistory) { pt in
                        LineMark(
                            x: .value("Time", pt.time),
                            y: .value("KB/s", pt.value),
                            series: .value("Series", "App Write")
                        )
                        .foregroundStyle(.green)
                    }
                }
                .chartYAxisLabel("KB/s")
                .frame(height: 120)

                let lastIn = pageInHistory.last?.value ?? 0
                let lastOut = pageOutHistory.last?.value ?? 0
                let lastWrite = appWriteHistory.last?.value ?? 0
                Text("Page In: \(lastIn, specifier: "%.1f") KB/s")
                    .foregroundColor(.blue)
                Text("Page Out: \(lastOut, specifier: "%.1f") KB/s")
                    .foregroundColor(.red)
                Text("App Write: \(lastWrite, specifier: "%.1f") KB/s")
                    .foregroundColor(.green)
            }

            Section(
                header:
                    Label("網路", systemImage: "network")
            ) {
                Text("介面: \(DeviceInfo.networkInterface)")
            }

            Section(
                header:
                    Label("系統", systemImage: "gearshape")
            ) {
                Text("iOS: \(DeviceInfo.osVersion)")
                Text("開機時間: \(uptimeString)")
                Text("電量: \(DeviceInfo.batteryLevel)% (\(DeviceInfo.batteryState))")
            }

            Section(
                header:
                    Label("GPU / Metal", systemImage: "cpu")
            ) {
                Text("GPU: \(DeviceInfo.cpuName)")
            }

            Section(
                header:
                    Label("即時動態 Live Activity", systemImage: "sparkles.tv")
            ) {
                HStack {
                    Label("狀態", systemImage: "circle.fill")
                        .foregroundColor(laManager.isActivityActive ? .green : .gray)
                    Text(laManager.isActivityActive ? "執行中" : "未啟動")
                        .foregroundColor(laManager.isActivityActive ? .green : .secondary)
                }

                if let err = laManager.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                }

                if laManager.isActivityActive {
                    Button("結束即時動態", role: .destructive) {
                        laManager.endStreamActivity()
                    }
                } else {
                    Button("啟動即時動態") {
                        laManager.startStreamActivity()
                    }
                }

                Text("Widget Extension 檔案已建立 (liveAPPWidget/)，需在 Xcode 新增 Widget Extension target 後編譯才能在鎖定畫面顯示")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .onAppear {
            sample()
            let t = Timer(timeInterval: 1.0, repeats: true) { [self] _ in
                sample()
            }
            RunLoop.main.add(t, forMode: .common)
            sampleTimer = t
        }
        .onDisappear {
            sampleTimer?.invalidate()
            sampleTimer = nil
            cpuHistory.removeAll()
            memoryHistory.removeAll()
            pageInHistory.removeAll()
            pageOutHistory.removeAll()
            appWriteHistory.removeAll()
            dataPointCounter = 0
            prevAppWriteBytes = 0
        }
    }

    private var uptimeString: String {
        let s = Int(ProcessInfo.processInfo.systemUptime)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return "\(h)h \(m)m \(sec)s"
    }

    private func sample() {
        dataPointCounter &+= 1
        let id = dataPointCounter
        appMemoryMB = DeviceInfo.appMemoryMB
        let now = Date()
        // EWMA 指數移動平均，α=0.4，不依賴歷史筆數
        let rawCPU = DeviceInfo.cpuUsagePercent
        let alpha = 0.4
        let smoothedCPU: Double
        if let last = cpuHistory.last?.value {
            smoothedCPU = alpha * rawCPU + (1 - alpha) * last
        } else {
            smoothedCPU = rawCPU
        }
        cpuHistory.append(DataPoint(id: id, time: now, value: smoothedCPU))
        memoryHistory.append(DataPoint(id: id, time: now, value: appMemoryMB))

        let (inKB, outKB) = diskIO.rates()
        pageInHistory.append(DataPoint(id: id, time: now, value: inKB))
        pageOutHistory.append(DataPoint(id: id, time: now, value: outKB))

        let currentBytes = AppLogPersister.shared.totalWrittenBytes
        appWriteHistory.append(DataPoint(id: id, time: now, value: Double(currentBytes - prevAppWriteBytes) / 1024.0))
        prevAppWriteBytes = currentBytes

        if cpuHistory.count > maxHistory { cpuHistory.removeFirst() }
        if memoryHistory.count > maxHistory { memoryHistory.removeFirst() }
        if pageInHistory.count > maxHistory { pageInHistory.removeFirst() }
        if pageOutHistory.count > maxHistory { pageOutHistory.removeFirst() }
        if appWriteHistory.count > maxHistory { appWriteHistory.removeFirst() }
    }
}
