//
//  Eventlisten.swift
//  liveAPP
//
//  Created by user on 2025/10/29.
//

import UIKit





class Eventlisten {

    static let shared  = Eventlisten()

    // MARK: 支援多事件的名稱列表
    let eventNames = [
        "micVolumeChanged", "appVolumeChanged","orientationChanged",
        "bitRateChange","fpsChange",
        "micAdd","appAdd","onAudioPage","logMode",
        "onlogPage","Enablelog","logURL",
        "DebugRotate","OutW","OutH","VideoSet",
        "PauseStream","ResumeStream",
        "ChangeBit","SocketRetry",
        "SocketLog"

    ]


}
