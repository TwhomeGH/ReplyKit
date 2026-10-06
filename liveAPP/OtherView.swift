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
import os

struct DataPoint: Identifiable {
    let id: Int
    let time: Date
    let value: Double
}

final class VideoHealthModel: ObservableObject {
    static let shared = VideoHealthModel()

    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var latestStatus: String = "waiting"
    @Published private(set) var inputHistory: [DataPoint] = []
    @Published private(set) var processedHistory: [DataPoint] = []
    @Published private(set) var droppedHistory: [DataPoint] = []
    @Published private(set) var timeoutHistory: [DataPoint] = []
    @Published private(set) var latencyHistory: [DataPoint] = []

    // 窗口彙總顯示（每 5s 一筆）
    @Published private(set) var lastInputRange: String = "-"
    @Published private(set) var lastProcessedRange: String = "-"
    @Published private(set) var lastLatencyText: String = "-"

    private var dataPointCounter = 0
    private let maxHistory = 120

    private init() {}

    func record(status: String,
                inputFPSAvg: Double, inputFPSMin: Double, inputFPSMax: Double,
                processedFPSAvg: Double, processedFPSMin: Double, processedFPSMax: Double,
                droppedFPSAvg: Double,
                latencyAvg: Double, latencyMax: Double, latencyP95: Double,
                timeoutDelta: Double) {
        DispatchQueue.main.async {
            self.appendOnMain(
                status: status,
                inputFPSAvg: inputFPSAvg,
                inputFPSMin: inputFPSMin,
                inputFPSMax: inputFPSMax,
                processedFPSAvg: processedFPSAvg,
                processedFPSMin: processedFPSMin,
                processedFPSMax: processedFPSMax,
                droppedFPSAvg: droppedFPSAvg,
                latencyAvg: latencyAvg, latencyMax: latencyMax, latencyP95: latencyP95,
                timeoutDelta: timeoutDelta
            )
        }
    }

    private func appendOnMain(status: String,
                              inputFPSAvg: Double, inputFPSMin: Double, inputFPSMax: Double,
                              processedFPSAvg: Double, processedFPSMin: Double, processedFPSMax: Double,
                              droppedFPSAvg: Double,
                              latencyAvg: Double, latencyMax: Double, latencyP95: Double,
                              timeoutDelta: Double) {
        dataPointCounter &+= 1
        let id = dataPointCounter
        let now = Date()

        lastUpdatedAt = now
        latestStatus = status
        inputHistory.append(DataPoint(id: id, time: now, value: inputFPSAvg))
        processedHistory.append(DataPoint(id: id, time: now, value: processedFPSAvg))
        droppedHistory.append(DataPoint(id: id, time: now, value: droppedFPSAvg))
        timeoutHistory.append(DataPoint(id: id, time: now, value: timeoutDelta))
        latencyHistory.append(DataPoint(id: id, time: now, value: latencyAvg))
        lastInputRange = String(format: "%.0f–%.0f", inputFPSMin, inputFPSMax)
        lastProcessedRange = String(format: "%.0f–%.0f", processedFPSMin, processedFPSMax)
        lastLatencyText = String(format: "avg:%.1f max:%.1f p95:%.1f ms", latencyAvg, latencyMax, latencyP95)

        trim()
    }

    private func trim() {
        if inputHistory.count > maxHistory { inputHistory.removeFirst(inputHistory.count - maxHistory) }
        if processedHistory.count > maxHistory { processedHistory.removeFirst(processedHistory.count - maxHistory) }
        if droppedHistory.count > maxHistory { droppedHistory.removeFirst(droppedHistory.count - maxHistory) }
        if timeoutHistory.count > maxHistory { timeoutHistory.removeFirst(timeoutHistory.count - maxHistory) }
        if latencyHistory.count > maxHistory { latencyHistory.removeFirst(latencyHistory.count - maxHistory) }
    }
}

final class AudioHealthModel: ObservableObject {
    static let shared = AudioHealthModel()

    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var latestStatus: String = "waiting"
    @Published private(set) var appFPSHistory: [DataPoint] = []
    @Published private(set) var micFPSHistory: [DataPoint] = []
    @Published private(set) var alignDropHistory: [DataPoint] = []
    @Published private(set) var skipHistory: [DataPoint] = []
    @Published private(set) var noDataHistory: [DataPoint] = []
    @Published private(set) var mixerOutHistory: [DataPoint] = []
    @Published private(set) var alignFireHistory: [DataPoint] = []
    @Published private(set) var outCh0History: [DataPoint] = []
    @Published private(set) var outCh1History: [DataPoint] = []

    @Published private(set) var lastAppRange: String = "-"
    @Published private(set) var lastMicRange: String = "-"
    @Published private(set) var lastGapText: String = "-"
    @Published private(set) var lastRMSText: String = "-"
    @Published private(set) var lastAlignInserted: Double = 0
    @Published private(set) var lastOverflowDropped: Double = 0
    @Published private(set) var lastAlignDiffSamples: Double = 0
    @Published private(set) var lastOutChText: String = "-"

    private var dataPointCounter = 0
    private let maxHistory = 120

    private init() {}

    func record(status: String,
                appInputFPSMin: Double, appInputFPSAvg: Double, appInputFPSMax: Double,
                micInputFPSMin: Double, micInputFPSAvg: Double, micInputFPSMax: Double,
                appGapMaxMs: Double,
                alignDroppedPerSec: Double, alignInsertedPerSec: Double,
                alignFirePerSec: Double, alignDiffMaxSamples: Double,
                skipInsertedPerSec: Double, overflowDroppedPerSec: Double,
                resampleNoDataPerSec: Double, mixerOutputFPS: Double,
                appRMS: Double, micRMS: Double,
                outChannels: Int, outCh0RMS: Double, outCh1RMS: Double) {
        DispatchQueue.main.async {
            self.appendOnMain(
                status: status,
                appInputFPSMin: appInputFPSMin, appInputFPSAvg: appInputFPSAvg, appInputFPSMax: appInputFPSMax,
                micInputFPSMin: micInputFPSMin, micInputFPSAvg: micInputFPSAvg, micInputFPSMax: micInputFPSMax,
                appGapMaxMs: appGapMaxMs,
                alignDroppedPerSec: alignDroppedPerSec, alignInsertedPerSec: alignInsertedPerSec,
                alignFirePerSec: alignFirePerSec, alignDiffMaxSamples: alignDiffMaxSamples,
                skipInsertedPerSec: skipInsertedPerSec, overflowDroppedPerSec: overflowDroppedPerSec,
                resampleNoDataPerSec: resampleNoDataPerSec, mixerOutputFPS: mixerOutputFPS,
                appRMS: appRMS, micRMS: micRMS,
                outChannels: outChannels, outCh0RMS: outCh0RMS, outCh1RMS: outCh1RMS
            )
        }
    }

    private func appendOnMain(status: String,
                              appInputFPSMin: Double, appInputFPSAvg: Double, appInputFPSMax: Double,
                              micInputFPSMin: Double, micInputFPSAvg: Double, micInputFPSMax: Double,
                              appGapMaxMs: Double,
                              alignDroppedPerSec: Double, alignInsertedPerSec: Double,
                              alignFirePerSec: Double, alignDiffMaxSamples: Double,
                              skipInsertedPerSec: Double, overflowDroppedPerSec: Double,
                              resampleNoDataPerSec: Double, mixerOutputFPS: Double,
                              appRMS: Double, micRMS: Double,
                              outChannels: Int, outCh0RMS: Double, outCh1RMS: Double) {
        dataPointCounter &+= 1
        let id = dataPointCounter
        let now = Date()

        lastUpdatedAt = now
        latestStatus = status
        appFPSHistory.append(DataPoint(id: id, time: now, value: appInputFPSAvg))
        micFPSHistory.append(DataPoint(id: id, time: now, value: micInputFPSAvg))
        alignDropHistory.append(DataPoint(id: id, time: now, value: alignDroppedPerSec))
        skipHistory.append(DataPoint(id: id, time: now, value: skipInsertedPerSec))
        noDataHistory.append(DataPoint(id: id, time: now, value: resampleNoDataPerSec))
        mixerOutHistory.append(DataPoint(id: id, time: now, value: mixerOutputFPS))
        alignFireHistory.append(DataPoint(id: id, time: now, value: alignFirePerSec))
        outCh0History.append(DataPoint(id: id, time: now, value: outCh0RMS))
        outCh1History.append(DataPoint(id: id, time: now, value: outCh1RMS))
        lastOutChText = "ch:\(outChannels) L:\(String(format: "%.3f", outCh0RMS)) R:\(String(format: "%.3f", outCh1RMS))"
        lastAppRange = String(format: "%.0f–%.0f", appInputFPSMin, appInputFPSMax)
        lastMicRange = String(format: "%.0f–%.0f", micInputFPSMin, micInputFPSMax)
        lastGapText = String(format: "%.0f ms", appGapMaxMs)
        lastRMSText = String(format: "app %.3f  mic %.3f", appRMS, micRMS)
        lastAlignInserted = alignInsertedPerSec
        lastOverflowDropped = overflowDroppedPerSec
        lastAlignDiffSamples = alignDiffMaxSamples

        trim()
    }

    private func trim() {
        if appFPSHistory.count > maxHistory { appFPSHistory.removeFirst(appFPSHistory.count - maxHistory) }
        if micFPSHistory.count > maxHistory { micFPSHistory.removeFirst(micFPSHistory.count - maxHistory) }
        if alignDropHistory.count > maxHistory { alignDropHistory.removeFirst(alignDropHistory.count - maxHistory) }
        if skipHistory.count > maxHistory { skipHistory.removeFirst(skipHistory.count - maxHistory) }
        if noDataHistory.count > maxHistory { noDataHistory.removeFirst(noDataHistory.count - maxHistory) }
        if mixerOutHistory.count > maxHistory { mixerOutHistory.removeFirst(mixerOutHistory.count - maxHistory) }
        if alignFireHistory.count > maxHistory { alignFireHistory.removeFirst(alignFireHistory.count - maxHistory) }
        if outCh0History.count > maxHistory { outCh0History.removeFirst(outCh0History.count - maxHistory) }
        if outCh1History.count > maxHistory { outCh1History.removeFirst(outCh1History.count - maxHistory) }
    }
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

    /// 系統 jetsam 真正採計的記憶體（phys_footprint）：不含可回收的檔案映射頁。
    /// 判斷記憶體壓力要看這個。
    static var appFootprintMB: Double {
        Double(footprintUsage()) / 1024 / 1024
    }

    /// resident_size：含執行檔/框架的可回收檔案映射頁，數字明顯偏高，
    /// 僅供對照，不可用來判斷實際佔用。
    static var appMemoryMB: Double {
        Double(residentUsage()) / 1024 / 1024
    }

    private static func footprintUsage() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4

        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_,
                          task_flavor_t(TASK_VM_INFO),
                          $0,
                          &count)
            }
        }

        return kerr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private static func residentUsage() -> UInt64 {
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

    /// 記憶體分類明細（單次 task_vm_info），用來判斷「誰吃走」。
    struct MemoryBreakdown {
        var footprintMB: Double      // 系統 jetsam 採計的實際佔用
        var internalMB: Double       // 自身配置（heap/stack/緩衝，dirty internal）
        var compressedMB: Double     // 已被壓縮的部分（含在 footprint）
        var externalMB: Double       // 檔案映射（框架/靜態庫，多可回收，不計入 footprint）
        var residentMB: Double       // 實體駐留（含可回收）
        var residentPeakMB: Double
        var reusableMB: Double       // 標記為可重用（可被系統直接回收）
        var purgeableVolatileMB: Double // 可清除（volatile purgeable resident）
        var availableMB: Double      // 距 jetsam 上限的可用量（os_proc_available_memory）
    }

    static var memoryBreakdown: MemoryBreakdown {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_,
                          task_flavor_t(TASK_VM_INFO),
                          $0,
                          &count)
            }
        }
        #if os(iOS)
        let availableMB = Double(os_proc_available_memory()) / 1024 / 1024
        #else
        let availableMB = 0.0
        #endif
        guard kerr == KERN_SUCCESS else {
            return MemoryBreakdown(footprintMB: 0, internalMB: 0, compressedMB: 0,
                                   externalMB: 0, residentMB: 0, residentPeakMB: 0,
                                   reusableMB: 0, purgeableVolatileMB: 0,
                                   availableMB: availableMB)
        }
        let mb: (mach_vm_size_t) -> Double = { Double($0) / 1024 / 1024 }
        return MemoryBreakdown(
            footprintMB: mb(info.phys_footprint),
            internalMB: mb(info.internal),
            compressedMB: mb(info.compressed),
            externalMB: mb(info.external),
            residentMB: mb(info.resident_size),
            residentPeakMB: mb(info.resident_size_peak),
            reusableMB: mb(info.reusable),
            purgeableVolatileMB: mb(info.purgeable_volatile_resident),
            availableMB: availableMB
        )
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
    @ObservedObject private var capture = CaptureCoordinator.shared
    @ObservedObject private var videoHealth = VideoHealthModel.shared
    @ObservedObject private var audioHealth = AudioHealthModel.shared

    @State private var appFootprintMB: Double = 0
    @State private var appResidentMB: Double = 0
    @State private var memInternalMB: Double = 0
    @State private var memCompressedMB: Double = 0
    @State private var memExternalMB: Double = 0
    @State private var memReusableMB: Double = 0
    @State private var memPurgeableMB: Double = 0
    @State private var memAvailableMB: Double = 0
    @State private var memPeakMB: Double = 0
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

    private var memAvailableText: String {
        memAvailableMB > 0
            ? "距 jetsam 上限: \(String(format: "%.0f", memAvailableMB)) MB"
            : "距 jetsam 上限: 未知（0 表示無回報）"
    }

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
                Text("App 實際佔用: \(appFootprintMB, specifier: "%.1f") MB")
                    .foregroundColor(appFootprintMB > 300 ? .orange : .primary)
                Text("其中自身內部 internal: \(memInternalMB, specifier: "%.1f") MB")
                    .font(.caption)
                Text("其中壓縮 compressed: \(memCompressedMB, specifier: "%.1f") MB")
                    .font(.caption)
                Text("外部映射 external（檔案映射、可 evict、非你的資料）: \(memExternalMB, specifier: "%.1f") MB")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("其中可回收 reusable: \(memReusableMB, specifier: "%.1f") MB · 可清除 purgeable: \(memPurgeableMB, specifier: "%.1f") MB")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("resident: \(appResidentMB, specifier: "%.1f") MB · 峰值: \(memPeakMB, specifier: "%.1f") MB")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(memAvailableText)
                    .font(.caption)
                    .foregroundColor(memAvailableMB > 0 && memAvailableMB < 100 ? .orange : .secondary)
                Text("PIP 輸出影像池（估）: \(PIPService.shared.estimatedPixelBufferPoolMB, specifier: "%.1f") MB")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("判斷壓力看「實際佔用」(footprint = internal + compressed)。external 是檔案映射(框架/靜態庫 code)，可被 evict 但「不在 footprint 內」，不可與 footprint 相減。")
                    .font(.caption2)
                    .foregroundColor(.secondary)

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

            StreamDiagnosticsSections()

            if capture.streamTelemetry.pipelineSampledAt != nil {
                Section("ScreenCaptureKit 本機管線") {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let age = max(0, context.date.timeIntervalSince(capture.streamTelemetry.pipelineSampledAt ?? .distantPast))
                        Text("來源：主 App · 距更新 \(Int(age)) 秒" + (age > 15 ? " · 資料已過期" : ""))
                            .foregroundStyle(age > 15 ? Color.orange : Color.secondary)
                    }
                    Text(capture.streamTelemetry.sourceQueues ?? "尚未取得來源佇列").font(.caption)
                    Text(capture.streamTelemetry.mixerAudio ?? "尚未取得混音資料").font(.caption)
                    Text("來源與混音計數不代表 RTMP 已送出；下方圖表來自 ReplayKit 擴展。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(
                header:
                    Label("Video Pipeline", systemImage: "waveform.path.ecg")
            ) {
                pipelineFreshness(videoHealth.lastUpdatedAt)
                Text("最後回報狀態: \(videoHealth.latestStatus)")
                    .foregroundColor(videoHealth.latestStatus == "healthy" ? .green : .orange)

                Chart {
                    ForEach(videoHealth.inputHistory) { pt in
                        LineMark(
                            x: .value("Time", pt.time),
                            y: .value("FPS", pt.value),
                            series: .value("Series", "Input")
                        )
                        .foregroundStyle(.blue)
                    }
                    ForEach(videoHealth.processedHistory) { pt in
                        LineMark(
                            x: .value("Time", pt.time),
                            y: .value("FPS", pt.value),
                            series: .value("Series", "Processed")
                        )
                        .foregroundStyle(.green)
                    }
                    ForEach(videoHealth.droppedHistory) { pt in
                        LineMark(
                            x: .value("Time", pt.time),
                            y: .value("FPS", pt.value),
                            series: .value("Series", "Dropped")
                        )
                        .foregroundStyle(.red)
                    }
                }
                .chartYAxisLabel("FPS")
                .chartYScale(domain: 0...70)
                .frame(height: 140)

                Chart {
                    ForEach(videoHealth.timeoutHistory) { pt in
                        BarMark(
                            x: .value("Time", pt.time),
                            y: .value("Timeout", pt.value)
                        )
                        .foregroundStyle(.purple)
                    }
                }
                .chartYAxisLabel("Timeout/s")
                .frame(height: 90)

                Chart {
                    ForEach(videoHealth.latencyHistory) { pt in
                        LineMark(
                            x: .value("Time", pt.time),
                            y: .value("Latency", pt.value),
                            series: .value("Series", "GPU Latency")
                        )
                        .foregroundStyle(.orange)
                    }
                }
                .chartYAxisLabel("completion ms")
                .frame(height: 90)

                let input = videoHealth.inputHistory.last?.value ?? 0
                let processed = videoHealth.processedHistory.last?.value ?? 0
                let dropped = videoHealth.droppedHistory.last?.value ?? 0
                let timeout = videoHealth.timeoutHistory.last?.value ?? 0
                Text("Input: \(input, specifier: "%.1f") fps  Processed: \(processed, specifier: "%.1f") fps")
                    .font(.caption)
                Text("Dropped: \(dropped, specifier: "%.1f") fps  Timeout: \(timeout, specifier: "%.0f")/s")
                    .font(.caption)
                    .foregroundColor(timeout > 0 || dropped > 0 ? .orange : .secondary)
                Text("Input range: \(videoHealth.lastInputRange)  Processed range: \(videoHealth.lastProcessedRange)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("GPU completion: \(videoHealth.lastLatencyText)")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }

            Section(
                header:
                    Label("Audio Pipeline", systemImage: "waveform")
            ) {
                pipelineFreshness(audioHealth.lastUpdatedAt)
                Text("最後回報狀態: \(audioHealth.latestStatus)")
                    .foregroundColor(audioHealth.latestStatus == "healthy" ? .green : .orange)

                Text("每秒音訊 buffer 數；每個 buffer 包含多個取樣。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Chart {
                    ForEach(audioHealth.appFPSHistory) { pt in
                        LineMark(
                            x: .value("Time", pt.time),
                            y: .value("buffers/s", pt.value),
                            series: .value("Series", "App")
                        )
                        .foregroundStyle(.blue)
                    }
                    ForEach(audioHealth.micFPSHistory) { pt in
                        LineMark(
                            x: .value("Time", pt.time),
                            y: .value("buffers/s", pt.value),
                            series: .value("Series", "Mic")
                        )
                        .foregroundStyle(.green)
                    }
                }
                .chartYAxisLabel("Input buffers/s")
                .frame(height: 140)

                Chart {
                    ForEach(audioHealth.alignDropHistory) { pt in
                        LineMark(
                            x: .value("Time", pt.time),
                            y: .value("Samples/s", pt.value),
                            series: .value("Series", "align drop")
                        )
                        .foregroundStyle(.red)
                    }
                    ForEach(audioHealth.skipHistory) { pt in
                        LineMark(
                            x: .value("Time", pt.time),
                            y: .value("Samples/s", pt.value),
                            series: .value("Series", "skip silence")
                        )
                        .foregroundStyle(.orange)
                    }
                    ForEach(audioHealth.noDataHistory) { pt in
                        LineMark(
                            x: .value("Time", pt.time),
                            y: .value("Samples/s", pt.value),
                            series: .value("Series", "underrun")
                        )
                        .foregroundStyle(.purple)
                    }
                    ForEach(audioHealth.alignFireHistory) { pt in
                        LineMark(
                            x: .value("Time", pt.time),
                            y: .value("Samples/s", pt.value),
                            series: .value("Series", "align fire")
                        )
                        .foregroundStyle(.pink)
                    }
                }
                .chartYAxisLabel("samples/s")
                .frame(height: 110)

                Chart {
                    ForEach(audioHealth.mixerOutHistory) { pt in
                        LineMark(
                            x: .value("Time", pt.time),
                            y: .value("buffers/s", pt.value),
                            series: .value("Series", "Mixer out")
                        )
                        .foregroundStyle(.teal)
                    }
                }
                .chartYAxisLabel("Mixer buffers/s")
                .frame(height: 90)

                Chart {
                    ForEach(audioHealth.outCh0History) { pt in
                        LineMark(
                            x: .value("Time", pt.time),
                            y: .value("RMS", pt.value),
                            series: .value("Series", "Out L")
                        )
                        .foregroundStyle(.blue)
                    }
                    ForEach(audioHealth.outCh1History) { pt in
                        LineMark(
                            x: .value("Time", pt.time),
                            y: .value("RMS", pt.value),
                            series: .value("Series", "Out R")
                        )
                        .foregroundStyle(.red)
                    }
                }
                .chartYAxisLabel("output ch RMS")
                .chartYScale(domain: 0...1)
                .frame(height: 90)

                let appFPS = audioHealth.appFPSHistory.last?.value ?? 0
                let micFPS = audioHealth.micFPSHistory.last?.value ?? 0
                let alignDrop = audioHealth.alignDropHistory.last?.value ?? 0
                let alignFire = audioHealth.alignFireHistory.last?.value ?? 0
                let skip = audioHealth.skipHistory.last?.value ?? 0
                let noData = audioHealth.noDataHistory.last?.value ?? 0
                Text("App: \(appFPS, specifier: "%.1f") buffers/s  Mic: \(micFPS, specifier: "%.1f") buffers/s")
                    .font(.caption)
                Text("align drop: \(alignDrop, specifier: "%.0f")/s  skip: \(skip, specifier: "%.0f")/s  underrun: \(noData, specifier: "%.0f")/s")
                    .font(.caption)
                    .foregroundColor(alignDrop > 0 || noData > 0 ? .orange : .secondary)
                Text("Range (buffers/s) App: \(audioHealth.lastAppRange)  Mic range: \(audioHealth.lastMicRange)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("PTS gap max: \(audioHealth.lastGapText)  RMS: \(audioHealth.lastRMSText)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("Output \(audioHealth.lastOutChText)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("align fire: \(alignFire, specifier: "%.1f")/s  diff: \(audioHealth.lastAlignDiffSamples, specifier: "%.0f") smp")
                    .font(.caption2)
                    .foregroundColor(alignFire > 0 ? .orange : .secondary)
                Text("align inserted: \(audioHealth.lastAlignInserted, specifier: "%.0f")/s  overflow drop: \(audioHealth.lastOverflowDropped, specifier: "%.0f")/s")
                    .font(.caption2)
                    .foregroundColor(.secondary)
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
            sampleTimer?.invalidate()
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

    /// 不把歷史 healthy 視為目前正常；兩張圖各自顯示最後收到資料的時間。
    private func pipelineFreshness(_ updatedAt: Date?) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let updatedAt {
                let age = max(0, context.date.timeIntervalSince(updatedAt))
                Text("來源：ReplayKit 擴展 · 距更新 \(Int(age)) 秒" + (age > 15 ? " · 資料已過期" : ""))
                    .font(.caption).foregroundStyle(age > 15 ? Color.orange : Color.secondary)
            } else {
                Text("來源：ReplayKit 擴展 · 尚未收到資料")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
        let mem = DeviceInfo.memoryBreakdown
        appFootprintMB = mem.footprintMB
        appResidentMB = mem.residentMB
        memInternalMB = mem.internalMB
        memCompressedMB = mem.compressedMB
        memExternalMB = mem.externalMB
        memReusableMB = mem.reusableMB
        memPurgeableMB = mem.purgeableVolatileMB
        memAvailableMB = mem.availableMB
        memPeakMB = mem.residentPeakMB
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
        memoryHistory.append(DataPoint(id: id, time: now, value: appFootprintMB))

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
