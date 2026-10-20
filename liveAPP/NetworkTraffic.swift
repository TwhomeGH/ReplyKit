import Darwin
import Foundation
import SwiftUI

/// 實體介面流量差分；涵蓋裝置上其他 App，不代表本 App 或 RTMP 的吞吐量。
struct NetworkTrafficSampler {
    struct Reading: Identifiable {
        let id: String
        let upload: Double?
        let download: Double?

        var title: String { id.hasPrefix("pdp_ip") ? "行動網路（\(id)）" : "Wi-Fi／乙太網路（\(id)）" }
    }

    private struct Counter {
        let received: UInt64
        let sent: UInt64
    }

    private var previous: [String: Counter] = [:]
    private var previousTime: Double?
    private(set) var readings: [Reading] = []
    private(set) var error: String?

    /// 呼叫端每秒取樣，離頁／回前景時重建此值；不自行啟動計時器。
    /// AF_LINK 每個介面只取一次；排除虛擬通道以免與實體流量重複相加。
    mutating func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else {
            error = "無法讀取網路介面（errno=\(errno)）"
            previous = [:]
            previousTime = nil
            readings = []
            return
        }
        defer { freeifaddrs(head) }
        var counters: [String: Counter] = [:]
        var cursor = head
        while let pointer = cursor {
            let item = pointer.pointee
            cursor = item.ifa_next
            guard let address = item.ifa_addr, Int32(address.pointee.sa_family) == AF_LINK,
                  item.ifa_flags & UInt32(IFF_UP) != 0,
                  item.ifa_flags & UInt32(IFF_RUNNING) != 0,
                  item.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let data = item.ifa_data else { continue }
            let name = String(cString: item.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            counters[name] = Counter(received: UInt64(stats.ifi_ibytes), sent: UInt64(stats.ifi_obytes))
        }
        let elapsed = previousTime.map { now - $0 } ?? 0
        readings = counters.keys.sorted().map { name in
            Reading(id: name,
                    upload: DiagnosticCounterRate.value(current: counters[name]?.sent,
                        previous: previous[name]?.sent, elapsed: elapsed),
                    download: DiagnosticCounterRate.value(current: counters[name]?.received,
                        previous: previous[name]?.received, elapsed: elapsed))
        }
        previous = counters
        previousTime = now
        error = nil
    }
}

/// 網路卡片只顯示已觀測介面；第一筆或計數回繞時不誤報為零。
struct NetworkTrafficCard: View {
    let sampler: NetworkTrafficSampler

    var body: some View {
        SettingsDashboardCard(header: { Label("網路介面流量", systemImage: "network") }) {
            if let error = sampler.error { Text(error).foregroundStyle(.orange) }
            if sampler.readings.isEmpty && sampler.error == nil {
                Text("尚無可讀取的活動介面").foregroundStyle(.secondary)
            }
            ForEach(sampler.readings) { reading in
                VStack(alignment: .leading, spacing: 4) {
                    Text(reading.title).font(.subheadline)
                    Text("上行：\(rate(reading.upload))")
                    Text("下行：\(rate(reading.download))")
                }
            }
            Text("介面累計位元組的差分，包含其他 App；不是網速測試，也不表示 RTMP 成功送達。每秒更新，切回頁面先重新取樣。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func rate(_ value: Double?) -> String {
        guard let value else { return "等待相鄰取樣" }
        return String(format: "%.2f Mbps · ", value * 8 / 1_000_000)
            + MetricReportAnalysis.displayValue("\(value) B") + "/s"
    }
}
