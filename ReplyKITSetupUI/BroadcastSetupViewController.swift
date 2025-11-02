//
//  BroadcastSetupViewController.swift
//  ReplyKITSetupUI
//
//  Created by user on 2025/8/24.
//

import ReplayKit

#if os(iOS)

import UIKit

class BroadcastSetupViewController: UIViewController {

    // Call this method when the user has finished interacting with the view controller and a broadcast stream can start
    func userDidFinishSetup() {
        // URL of the resource where broadcast can be viewed that will be returned to the application
        let broadcastURL = URL(string:"http://apple.com/broadcast/streamID")
        
        // Dictionary with setup information that will be provided to broadcast extension when broadcast is started
        let setupInfo: [String : NSCoding & NSObjectProtocol] = ["broadcastName": "example" as NSCoding & NSObjectProtocol]
        
        // Tell ReplayKit that the extension is finished setting up and can begin broadcasting
        self.extensionContext?.completeRequest(withBroadcast: broadcastURL!, setupInfo: setupInfo)
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
        let broadcastURL = URL(string:"http://apple.com/broadcast/streamID")
        let setupInfo: [String: Any] = ["broadcastName": "example"]

        // macOS 沒有 extensionContext，可以自行調用 delegate 或 closure 回傳資料
        delegate?.broadcastSetupDidFinish(url: broadcastURL, info: setupInfo)
    }

    func userDidCancelSetup() {
        // macOS 沒有 extensionContext，可以自行調用 delegate 或 closure
        delegate?.broadcastSetupDidCancel(error: NSError(domain: "YourAppDomain", code: -1))
    }

    weak var delegate: BroadcastSetupDelegate?
}

protocol BroadcastSetupDelegate: AnyObject {
    func broadcastSetupDidFinish(url: URL?, info: [String: Any])
    func broadcastSetupDidCancel(error: Error?)
}
#endif
