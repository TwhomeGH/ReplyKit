import SwiftUI
import Network
import Darwin
import UIKit

private struct LocalIPv4Address: Identifiable {
    let interface: String
    let address: String
    var id: String { "\(interface)/\(address)" }

    static func current() -> [LocalIPv4Address] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var result: [LocalIPv4Address] = []
        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0,
                  let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            // en interfaces cover Wi-Fi / Ethernet; exclude cellular and VPN addresses.
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.append(LocalIPv4Address(interface: name, address: String(cString: host)))
        }
        return result.sorted { $0.id < $1.id }
    }
}

struct SocketConnectionSettingsView: View {
    @ObservedObject private var socket = SocketServer.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var portText = String(SocketPortSettings.port)
    @State private var addresses: [LocalIPv4Address] = []
    @State private var monitor: NWPathMonitor?
    @State private var isCaptured = UIScreen.main.isCaptured
    @State private var copyMessage: String?

    private var validPort: UInt16? {
        let value = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let port = UInt16(value), port >= 1024 else { return nil }
        return port
    }

    var body: some View {
        Form {
            Section(header: Text("服務狀態")) {
                Text(socket.listenerStatus)
                if let port = socket.listeningPort {
                    Text("目前監聽端口：\(Int(port))")
                }
                Text("已儲存端口：\(Int(SocketPortSettings.port))")
                if socket.listeningPort == nil {
                    Button("重試啟動") { socket.ensureRunning() }
                        .disabled(socket.isApplyingPort)
                }
            }

            Section(header: Text("本機內網 IPv4")) {
                if addresses.isEmpty {
                    Text("目前沒有可用的內網 IPv4，請連接 Wi-Fi 或有線網路。")
                        .foregroundColor(.secondary)
                }
                ForEach(addresses) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.address).font(.headline)
                        Text("網路介面：\(item.interface)").font(.caption).foregroundColor(.secondary)
                        HStack {
                            Button("複製 IP") { copy(item.address) }
                            if let port = socket.listeningPort {
                                Button("複製 IP:端口") { copy("\(item.address):\(port)") }
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("重新整理位址") { refreshAddresses() }
                if let copyMessage { Text(copyMessage).font(.caption).foregroundColor(.secondary) }
                Text("其他設備請使用相同區域網路，連線至以上位址與目前監聽端口。")
                    .font(.footnote).foregroundColor(.secondary)
            }

            Section(header: Text("監聽端口")) {
                TextField("1024–65535", text: $portText)
                    .keyboardType(.numberPad)
                    .disabled(!SocketPortSettings.canCustomize || socket.isApplyingPort || isCaptured)
                if validPort == nil {
                    Text("請輸入 1024–65535 的整數。").foregroundColor(.red)
                }
                Button(socket.isApplyingPort ? "正在套用…" : "套用") {
                    if let port = validPort { socket.applyPort(port) }
                }
                .disabled(validPort == nil || !SocketPortSettings.canCustomize || socket.isApplyingPort || isCaptured)
                Button("恢復預設值 9322") { portText = String(SocketPortSettings.defaultPort) }
                    .disabled(!SocketPortSettings.canCustomize || socket.isApplyingPort || isCaptured)
                if !SocketPortSettings.canCustomize {
                    Text("此安裝模式暫不支援自訂端口，目前使用 9322。")
                        .font(.footnote).foregroundColor(.secondary)
                } else {
                    Text("停止直播後才能變更端口。套用成功會中斷現有 Socket 連線；其他設備需改用新端口重新連線。恢復預設值後仍需按「套用」。")
                        .font(.footnote).foregroundColor(.secondary)
                }
                if isCaptured {
                    Text("請先停止直播或螢幕錄製再變更端口。")
                        .foregroundColor(.secondary)
                }
                if let error = socket.portError { Text(error).foregroundColor(.red) }
            }
        }
        .navigationTitle("Socket 連線")
        .onAppear {
            refreshAddresses()
            let pathMonitor = NWPathMonitor()
            pathMonitor.pathUpdateHandler = { _ in
                DispatchQueue.main.async { refreshAddresses() }
            }
            monitor = pathMonitor
            pathMonitor.start(queue: DispatchQueue(label: "SocketAddressMonitor"))
        }
        .onDisappear {
            monitor?.pathUpdateHandler = nil
            monitor?.cancel()
            monitor = nil
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { refreshAddresses() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            isCaptured = UIScreen.main.isCaptured
        }
    }

    private func refreshAddresses() {
        addresses = LocalIPv4Address.current()
        isCaptured = UIScreen.main.isCaptured
    }

    private func copy(_ value: String) {
        UIPasteboard.general.string = value
        copyMessage = "已複製 \(value)"
    }
}
