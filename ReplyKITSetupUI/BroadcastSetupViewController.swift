//
//  BroadcastSetupViewController.swift
//  ReplyKITSetupUI
//
//  Created by user on 2025/8/24.
//

import ReplayKit

import os


let logger = Logger(subsystem: "nuclear.liveAPP.ReplyKitSetupUI", category: "extension")


let userDefaults = UserDefaults(suiteName: "group.nuclear.liveAPP")


#if os(iOS)

import UIKit


class BroadcastSetupViewController: UIViewController {

        // Call this method when the user has finished interacting with the view controller and a broadcast stream can start

     func userDidFinishSetup() {
         // URL of the resource where broadcast can be viewed that will be returned to the application

         // 優先使用 App Group UserDefaults（非側載），側載時使用 standard
         let ud = userDefaults ?? UserDefaults.standard
         let rtmpURL = ud.string(forKey: "rtmpURL") ?? "rtmp://192.168.0.102:1936/live"
         let rtmpKey = ud.string(forKey: "rtmpKey") ?? "stream1?vhost=live2"

         let broadcastURL = URL(string: rtmpURL)

//         Dictionary with setup information that will be provided to broadcast extension when broadcast is started


         let setupInfo: [String : NSCoding & NSObjectProtocol] = [
               "broadcastName": "ReplyKit" as NSCoding & NSObjectProtocol,
               "rtmpURL": rtmpURL as NSString,
               "rtmpKey": rtmpKey as NSString
            ]

         // Tell ReplayKit that the extension is finished setting up and can begin broadcasting
         self.extensionContext?.completeRequest(
            withBroadcast: broadcastURL!,
            setupInfo: setupInfo )

//

     }

    

    func userDidCancelSetup() {
        let error = NSError(domain: "com.liveApp.broadcast", code: -1, userInfo: nil)
        // Tell ReplayKit that the extension was cancelled by the user
        self.extensionContext?.cancelRequest(withError: error)
    }
}


#endif



#if os(macOS)
import AppKit

class BroadcastSetupViewController: NSViewController {

    // 用於 macOS 自己的處理
    func userDidFinishSetup() {
        let ud = UserDefaults.standard
        let rtmpURL = ud.string(forKey: "rtmpURL") ?? "rtmp://192.168.0.102/live"
        let rtmpKey = ud.string(forKey: "rtmpKey") ?? "stream1?vhost=live2"

        let broadcastURL = URL(string: rtmpURL)
        let setupInfo: [String: Any] = [
            "broadcastName": "ReplyKit",
            "rtmpURL": rtmpURL,
            "rtmpKey": rtmpKey
        ]

        delegate?.broadcastSetupDidFinish(url: broadcastURL, info: setupInfo)
    }

    func userDidCancelSetup() {
        delegate?.broadcastSetupDidCancel(error: NSError(domain: "YourAppDomain", code: -1))
    }

    weak var delegate: BroadcastSetupDelegate?
}

protocol BroadcastSetupDelegate: AnyObject {
    func broadcastSetupDidFinish(url: URL?, info: [String: Any])
    func broadcastSetupDidCancel(error: Error?)
}
#endif
