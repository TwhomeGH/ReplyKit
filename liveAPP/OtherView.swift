//
//  OtherView.swift
//  liveAPP
//
//  Created by user on 2026/2/16.
//


import SwiftUI
import MachO
import Metal

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
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(THREAD_INFO_MAX)

            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threadList[i],
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


    static let cpuCount = ProcessInfo.processInfo.processorCount
    static let ramMB = Double(ProcessInfo.processInfo.physicalMemory) / 1024 / 1024

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


struct DeviceView: View {

    let cpuInfo = SystemCPU()

    @State private var appMemoryMB: Double = 0

    @AppStorage("ReplyKitWidth",store: userDefaults) var ReplyKitW: Int = 0
    @AppStorage("ReplyKitHeight",store: userDefaults) var ReplyKitH: Int = 0


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
            }


            Section(
                header:
                    Label("CPU", systemImage: "cpu")
            ) {
                if let usage = cpuInfo.usage() {

                    Text("用戶 User: \(usage.user, specifier: "%.1f") %")
                    Text("系統 System: \(usage.system, specifier: "%.1f") %")
                    Text("閒置 Idle: \(usage.idle, specifier: "%.1f") %")
                }


                Text("App 使用率: \(DeviceInfo.cpuUsagePercent, specifier: "%.1f") %")

                Text("處理器/GPU名稱: \(DeviceInfo.cpuName)")

                Text(
                    "核心數: \(DeviceInfo.cpuCount)"
                )
                Text("裝置代號: \(DeviceInfo.deviceCode)")
            }

            Section(
                header:
                    Label("記憶體 Ram", systemImage: "memorychip")
            ) {
                Text("總 RAM: \(DeviceInfo.ramMB, specifier: "%.0f") MB")
                Text("App 使用中: \(appMemoryMB, specifier: "%.1f") MB")
            }
        }
        .onAppear {
            updateMemory()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            updateMemory()
        }
    }



    private func updateMemory() {
        appMemoryMB = DeviceInfo.appMemoryMB
    }
}
