//
//  Socket.swift
//  liveAPP
//
//  Created by user on 2025/11/4.
//

import Foundation
import Network
import ReplayKit


let CF_PORT_NAME = "group.nuclear.liveAPP.port" as CFString

//
//func sendMessage(_ dict: [String: Any]) -> [String: Any]? {
//    guard let remote = CFMessagePortCreateRemote(nil, CF_PORT_NAME) else {
//        test("❌ remote port not found")
//        return nil
//    }
//
//    // Encode JSON
//    guard let data = try? JSONSerialization.data(withJSONObject: dict) else {
//        return nil
//    }
//
//    var returnData: Unmanaged<CFData>?
//
//    // Send request & wait for response
//    let result = CFMessagePortSendRequest(
//        remote,
//        1,                       // message ID
//        data as CFData,          // payload
//        2,                       // send timeout
//        2,                       // receive timeout
//        CFRunLoopMode.defaultMode.rawValue,
//        &returnData              // receive buffer
//    )
//
//    guard result == kCFMessagePortSuccess else {
//        test("❌ CFMessagePortSendRequest failed: \(result)")
//        return nil
//    }
//
//    // Extract received data
//    guard let cfData = returnData?.takeRetainedValue() else {
//        test("❌ No response data")
//        return nil
//    }
//
//    let resp = cfData as Data
//
//    // Decode JSON
//    return (try? JSONSerialization.jsonObject(with: resp, options: [])) as? [String: Any]
//}

//class BroadcastSocketClient {
//    static let shared = BroadcastSocketClient()
//
//    private var connection: NWConnection?
//    private var completion: (([String: String]?) -> Void)?
//    private var timeoutWorkItem: DispatchWorkItem?
//
//    /// 連線並請求 rtmpURL 與 streamKey
//    func requestStreamSettings(completion: @escaping ([String: String]?) -> Void) {
//        // 如果已有連線，先取消
//        connection?.cancel()
//        self.completion = completion
//
//        let host = NWEndpoint.Host("localhost")
//        let port = NWEndpoint.Port(rawValue: 9322)!
//
//        connection = NWConnection(host: host, port: port, using: .tcp)
//
//        connection?.stateUpdateHandler = { [weak self] state in
//            guard let self = self else { return }
//            switch state {
//            case .ready:
//                test("Socket connected")
//                self.sendRequest()
//            case .failed(_), .cancelled:
//                self.complete(nil)
//            default: break
//            }
//        }
//
//        // 使用背景 queue，避免阻塞 UI
//        connection?.start(queue: DispatchQueue.global())
//
//        // 設置超時 5 秒
//        timeoutWorkItem?.cancel()
//        timeoutWorkItem = DispatchWorkItem { [weak self] in
//            guard let self = self else { return }
//            test("Socket timeout")
//            self.complete(nil)
//            self.connection?.cancel()
//        }
//        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeoutWorkItem!)
//    }
//
//    private func sendRequest() {
//        let payload: [String: Any] = ["type": "requestRTMP"]
//        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
//            complete(nil)
//            return
//        }
//
//        connection?.send(content: data, completion: .contentProcessed({ [weak self] error in
//            if let error = error {
//                test("Send error: \(error)")
//                self?.complete(nil)
//            } else {
//                self?.receiveResponse()
//            }
//        }))
//    }
//
//    private func receiveResponse() {
//        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
//            guard let self = self else { return }
//
//            if let error = error {
//                test("Receive error: \(error)")
//                self.complete(nil)
//                return
//            }
//
//            guard let data = data, data.count > 0 else {
//                if isComplete {
//                    self.complete(nil)
//                } else {
//                    // 沒收到完整資料，繼續接收
//                    self.receiveResponse()
//                }
//                return
//            }
//
//            do {
//                if let dict = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
//                   dict["type"] as? String == "RTMP",
//                   let rtmpURL = dict["rtmpURL"] as? String,
//                   let streamKey = dict["rtmpKey"] as? String
//                {
//                    self.complete(["rtmpURL": rtmpURL, "rtmpKey": streamKey])
//                    self.connection?.cancel()
//                } else {
//                    // 如果 JSON 不符合預期，繼續接收
//                    self.receiveResponse()
//                }
//            } catch {
//                test("JSON parse error: \(error)")
//                self.complete(nil)
//            }
//        }
//    }
//
//    private func complete(_ result: [String: String]?) {
//        DispatchQueue.main.async { [weak self] in
//            guard let self = self else { return }
//            self.completion?(result)
//            self.completion = nil
//            self.timeoutWorkItem?.cancel()
//            self.timeoutWorkItem = nil
//        }
//    }
//}
