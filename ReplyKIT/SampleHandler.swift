//
//  SampleHandler.swift
//  ReplyKIT
//
//  Created by user on 2025/8/24.
//

import MediaPlayer
import VideoToolbox
import ReplayKit
import RTMPHaishinKit

import os

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

import HaishinKit
import AVFoundation    // 提供 AVAudioPCMBuffer, AVAudioFormat, AVAudioTime 等
import CoreAudio
import CoreMedia       // 提供 CMSampleBuffer, CMSampleBufferGetFormatDescription 等
import CoreImage


import os
import Foundation


let logger = Logger(subsystem: "nuclear.liveAPP.ReplyKit", category: "extension")

class SharedDefaults {
    static let group:UserDefaults? = UserDefaults(
        suiteName: "group.nuclear.liveAPP"
    ) ?? .standard
}


@available(iOS 10.0, *)
class SampleHandler: RPBroadcastSampleHandler , @unchecked Sendable{

   
    var DWidth = 0
    var DHeight = 0


    var rtmpURL:String?
    var rtmpKey:String?


    var audioProcessor: AudioProcessor?
    var videoProcessor: VideoFrameProcessor?

    var streamStataus:MyStreamBitRateStrategy?

    var volumeCheckTimer: Timer?

    var volumeNotifier : VolumeNotifier?




    

#if os(iOS)
    private var currentOrientation: UIDeviceOrientation = .portrait
    private var nowOrientation: UIDeviceOrientation = .landscapeLeft

#else
    private var currentOrientation: Int = 0
    private var nowOrientation:Int = 0

#endif


    // MARK: 用戶設置輸出寬高
    var ADWidth : Int = 0
    var ADHeight : Int = 0

    // MARK: 給畫布實際輸出寬高
    var ODWidth : Int = 0
    var ODHeight : Int = 0



    private var lastVideoOrientation: AVCaptureVideoOrientation?








    // MARK: 全局 MediaMixer
    let mediaMixer:MediaMixer = MediaMixer(captureSessionMode: .manual, multiTrackAudioMixingEnabled: true)



    private var lastTimestamp: CMTime = .zero



    private var needVideoConfiguration = false
    private var needAudioConfiguration = false

    private var isSessionReady = false
    private var appVolume: Float = 1.0
    private var micVolume: Float = 1.0
    private var appAddVolume: Float = 1.0
    private var micAddVolume: Float = 1.0

    // MARK: 推流物件 RTMP
    private var rtmpConnection :RTMPConnection?
    private var rtmpStream : RTMPStream!


    private var lastConfiguredSize: CGSize? = nil

    // MARK: 重連狀態（由 RTMPConnection 內建處理，此處僅保留回呼通知）
    private var isInitialSyncDone = false

    // AdaptiveVideoBufferManager 已停用（2025.06）
    // setVideoInputBufferCounts 僅為 stored property setter，HaishinKit 的 buffering policy
    // 在 stream 啟動時就已固定，runtime 呼叫無效。初始化時設定一次即可。
    private var adaptiveBufferManager: AdaptiveVideoBufferManager?

    private func reloadVolumes(type:Int = -1,volume:Float = 1.0) {

        switch type {
        case 0:
            appVolume = volume
            //sendlog(message:"app audio update\(appVolume)")
            break;
        case 1:
            micVolume = volume
            //sendlog(message:"mic audio update\(micVolume)")
            break;

        default:

           

            Task {
                appVolume = Float(RPConfig.shared.state.AppVolume)
                micVolume = Float(RPConfig.shared.state.MicVolume)

                sendlog(message:"Audio 音量更新 App:\(appVolume) Mic:\(micVolume)")
                await updateAppAudioVolume(appVolume)
                await updateMicAudioVolume(micVolume)
            }

        }

    }

    //

    
    

    // MARK: 註冊所有事件
    func registerObservers() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for event in Eventlisten.shared.eventNames {
            CFNotificationCenterAddObserver(center,
                                            UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                                            { (_, observer, name, _, _) in
                guard let observer = observer,
                      let cfName = name else { return }
                let handler = Unmanaged<SampleHandler>.fromOpaque(observer).takeUnretainedValue()
                let eventName = cfName.rawValue as String
                handler.handleEvent(eventName: eventName)
            },
                                            event as CFString,
                                            nil,
                                            .deliverImmediately)
        }
    }


    // MARK: 移除所有觀察者
    private func removeObservers() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for event in Eventlisten.shared.eventNames {
            CFNotificationCenterRemoveObserver(center,
                                               UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                                               CFNotificationName(event as CFString),
                                               nil)
        }
    }

    actor FrameState {
        var frameRate: Double = 30.0

        init(frameRate:Double = 30.0){
            self.frameRate = frameRate
        }
        func set(frame:Double){
            self.frameRate = frame
        }
        func get() -> Double {
            return self.frameRate
        }
    }

    // MARK: 統一處理事件
    func handleEvent(eventName: String) {
        switch eventName {

        case "micAdd":

            Task {

                var newVolume = SharedDefaults.group?.double(forKey: "micAddVolume") ?? 1.0

                if RPConfig.shared.enableSocketLog {
                    if let raw = try await SocketClient.shared.requestSet(for: "micAddVolume", type: "Double") {

                        if let av = raw as? Double {
                            let oldV = newVolume
                            newVolume = av

                            logger.debug("MicAddVol \(av)")
                            sendlog(message: "Socket原始MicAddVolume數據包:\(av) -> \(oldV)")
                        } else {
                            logger.error("MicAddVolume 型別錯誤: \(type(of: raw))")
                        }

                    }
                }

                micAddVolume=Float(newVolume)

                guard let audioProcessor else {
                    sendlog(message:"[Audio] micAdd 跳過: audioProcessor nil init:\(processorsInitialized)")
                    return
                }
                audioProcessor.updateVolumes(micAdd: micAddVolume)

                sendlog(message: String(
                format: "麥克風音量放大: %.5f%%",
                newVolume
            ))

            }

            break

        case "appAdd":

            

            Task {

                var newVolume = SharedDefaults.group?.double(forKey: "appAddVolume") ?? 1.0

                if RPConfig.shared.enableSocketLog {
                    if let raw = try await SocketClient.shared.requestSet(for: "appAddVolume", type: "Double") {

                        if let av = raw as? Double {
                            let oldV = newVolume
                            newVolume = av

                            logger.debug("AppAddVol \(av)")
                            sendlog(message: "Socket原始AppAddVolume數據包:\(av) -> \(oldV)")
                        } else {
                            logger.error("AppAddVolume 型別錯誤: \(type(of: raw))")
                        }

                    }
                }

                appAddVolume=Float(newVolume)

                guard let audioProcessor else {
                    sendlog(message:"[Audio] appAdd 跳過: audioProcessor nil init:\(processorsInitialized)")
                    return
                }
                audioProcessor.updateVolumes(appAdd: appAddVolume)

                sendlog(message: String(
                format: "App音量放大: %.5f%%",
                newVolume
            ))


            }

            break 


        case "micVolumeChanged":
            

            Task {
                var newVolume = SharedDefaults.group?.double(forKey: "micVolume") ?? 1.0

                if RPConfig.shared.enableSocketLog {
                    if let raw = try await SocketClient.shared.requestSet(for: "micVolume", type: "Double") {

                        if let av = raw as? Double {
                            let oldV = newVolume
                            newVolume = av

                            logger.debug("MicVol \(av)")
                            sendlog(message: "Socket原始MicVolume數據包:\(av) -> \(oldV)")
                        } else {
                            logger.error("MicVolume 型別錯誤: \(type(of: raw))")
                        }

                    }
                }

                sendlog(message: String(
                    format: "RE:麥克風音量更新: %.2f%% (原始值: %.5f)",
                    volumeToPercentage(newVolume) * 100,
                    newVolume
                ))

                micVolume=Float(newVolume)

                guard let audioProcessor else {
                    sendlog(message:"[Audio] micVolume 跳過: audioProcessor nil init:\(processorsInitialized)")
                    return
                }
                audioProcessor.updateVolumes(mic: micVolume)


                await updateMicAudioVolume(micVolume)
            }

            break

        case "appVolumeChanged":


            Task {

                var newVolume = SharedDefaults.group?.double(forKey: "appVolume") ?? 1.0

                if RPConfig.shared.enableSocketLog {
                    if let raw = try await SocketClient.shared.requestSet(for: "appVolume", type: "Double") {

                        if let av = raw as? Double {
                            let oldV = newVolume
                            newVolume = av

                            logger.debug("AppVol \(av)")
                            sendlog(message: "Socket原始AppVolume數據包:\(av) -> \(oldV)")
                        } else {
                            logger.error("appVolume 型別錯誤: \(type(of: raw))")
                        }

                    }
                }

                    sendlog(message: String(
                        format: "!!應用音量更新: %.2f%% (原始值: %.5f)",
                        volumeToPercentage(newVolume) * 100,
                        newVolume
                    ))


                    appVolume=Float(newVolume)

                    guard let audioProcessor else {
                        sendlog(message:"[Audio] appVolume 跳過: audioProcessor nil init:\(processorsInitialized)")
                        return
                    }
                    audioProcessor.updateVolumes(app: appVolume)

                    await updateAppAudioVolume(appVolume)


            }

            break

        case "orientationChanged":

            print("棄用組件方法")

            break
            

        case "SocketRetry":
            sendlog(message: "收到 SocketRetry，觸發重連")
            SocketClient.shared.retry()

            break



        case "DebugRotate":


            Task {
                var Rlog=SharedDefaults.group?.bool(forKey: "EnableRotatelog") ?? false
                if RPConfig.shared.enableSocketLog {
                    if let raw = try await SocketClient.shared.requestSet(for: "EnableRotatelog", type: "Bool") {

                        if let av = raw as? Bool {
                            let oldV = Rlog
                            Rlog = av

                            logger.debug("EnableRotate \(av)")
                            sendlog(message: "Socket原始EnableRotate數據包:\(av) -> \(oldV)")
                        } else {
                            logger.error("EnableRotate 型別錯誤: \(type(of: raw))")
                        }

                    }
                }
                
                await videoProcessor?.setRotatorDebug(Rlog)
                sendlog(message:"[旋轉日誌變化] VideoRotate \(Rlog)")

            }

            break



        case "DebugTime":
            

            Task {

                var Rlog=SharedDefaults.group?.bool(forKey: "EnableTimeDebug") ?? false
                if RPConfig.shared.enableSocketLog {
                    if let raw = try await SocketClient.shared.requestSet(for: "EnableTimeDebug", type: "Bool") {

                        if let av = raw as? Bool {
                            let oldV = Rlog
                            Rlog = av

                            logger.debug("EnableTimeDebug \(av)")
                            sendlog(message: "Socket原始EnableTimeDebug數據包:\(av) -> \(oldV)")
                        } else {
                            logger.error("EnableTimeDebug 型別錯誤: \(type(of: raw))")
                        }

                    }
                }

                await videoProcessor?.setRotatorTsDebug(Rlog)
                sendlog(message:"[旋轉日誌時間軸檢查] VideoTime \(Rlog)")

            }

            break

        case "DebugPipeline":

            Task {
                var Plog=SharedDefaults.group?.bool(forKey: "EnablePipelineLog") ?? false
                if RPConfig.shared.enableSocketLog {
                    if let raw = try await SocketClient.shared.requestSet(for: "EnablePipelineLog", type: "Bool") {

                        if let av = raw as? Bool {
                            let oldV = Plog
                            Plog = av

                            logger.debug("EnablePipelineLog \(av)")
                            sendlog(message: "Socket原始EnablePipelineLog數據包:\(av) -> \(oldV)")
                        } else {
                            logger.error("EnablePipelineLog 型別錯誤: \(type(of: raw))")
                        }

                    }
                }

                RPConfig.shared.enablePipelineLog = Plog
                sendlog(message:"[管線調試日誌] enablePipelineLog \(Plog)")

            }

            break



        case "RotateOriginal":
            
            

            Task {
                
                var Rlog=SharedDefaults.group?.bool(
                forKey: "RotateOriginal"
            ) ?? false

                if RPConfig.shared.enableSocketLog {
                    if let raw = try await SocketClient.shared.requestSet(for: "RotateOriginal", type: "Bool") {

                        if let av = raw as? Bool {
                            let oldV = Rlog
                            Rlog = av

                            logger.debug("RotateOriginal \(av)")
                            sendlog(message: "Socket原始RotateOriginal數據包:\(av) -> \(oldV)")
                        } else {
                            logger.error("RotateOriginal 型別錯誤: \(type(of: raw))")
                        }

                    }
                }

                RPConfig.shared.updateState(RotateOriginal:Rlog)

                sendlog(message:"[RotateOriginal 變換]  \(Rlog)")


            }

            break



        case "VideoReconfig":
            sendlog(message: "[VideoReconfig] 重置視訊設定")
            needVideoConfiguration = true
            break



        case "Rotate":

            Task {
                var Rlog=SharedDefaults.group?.integer(forKey: "Rotate") ?? 90

                if RPConfig.shared.enableSocketLog {
                    if let raw = try await SocketClient.shared.requestSet(for: "Rotate", type: "Int") {

                        if let av = raw as? Int {
                            let oldV = Rlog
                            Rlog = av

                            logger.debug("Rotate \(av)")
                            sendlog(message: "Socket原始Rotate數據包:\(av) -> \(oldV)")
                        } else {
                            logger.error("Rotate 型別錯誤: \(type(of: raw))")
                        }

                    }
                }

                var vset = await rtmpStream.videoSettings
                var NewVW = DWidth
                var NewVH = DHeight

                if ODWidth > 0 && ODHeight > 0 {
                    NewVW = ODWidth
                    NewVH = ODHeight
                } else if ADWidth > 0 && ADHeight > 0 {
                    NewVW = ADWidth
                    NewVH = ADHeight
                }


                let Rotate = RotationAngle(rawValue: UInt32(Rlog))

                switch Rotate {
                case .landscapeLeft,.landscapeRight:
                        vset.videoSize.width = CGFloat(NewVW)
                        vset.videoSize.height = CGFloat(NewVH)

                case .portrait,.portraitUpsideDown:
                        vset.videoSize.width = CGFloat(NewVH)
                        vset.videoSize.height = CGFloat(NewVW)

                    default:
                        vset.videoSize.width = CGFloat(NewVH)
                        vset.videoSize.height = CGFloat(NewVW)

                        break

                }


                sendlog(message: "RVideoSET:\(vset)")

                try await rtmpStream.setVideoSettings(vset)


                RPConfig.shared.updateState(Rotate:Rlog)

                sendlog(message:"[Rotate變換]  \(Rlog)")


            }

            break


        case "SocketLog":
            

            Task {
                var Rlog=SharedDefaults.group?.bool(forKey: "EnableSocketlog") ?? false

                
                    if let raw = try await SocketClient.shared.requestSet(for: "EnableSocketlog", type: "Bool") {

                        if let av = raw as? Bool {
                            let oldV = Rlog
                            Rlog = av

                            logger.debug("EnableSocket \(av)")
                            sendlog(message: "Socket原始EnableSocketLog數據包:\(av) -> \(oldV)")
                        } else {
                            logger.error("EnableSocketLog 型別錯誤: \(type(of: raw))")
                        }

                    }

                RPConfig.shared.enableSocketLog = Rlog
                sendlog(message:"[Socket日誌開關]  \(Rlog)")

            }

            break


        case "ChangeBit":
            
            Task {

                var Rlog=SharedDefaults.group?.bool(forKey: "ChangeBit") ?? false

                if RPConfig.shared.enableSocketLog {
                    if let raw = try await SocketClient.shared.requestSet(for: "ChangeBit", type: "Bool") {

                        if let av = raw as? Bool {
                            let oldV = Rlog
                            Rlog = av

                            logger.debug("ChangeBit \(av)")
                            sendlog(message: "Socket原始ChangeBit數據包:\(av) -> \(oldV)")
                        } else {
                            logger.error("ChangeBit 型別錯誤: \(type(of: raw))")
                        }

                    }
                }

                await streamStataus?.isChangBit(Rlog)
                sendlog(message:"[網路]碼率控制: \(Rlog)")



            }

            break

        case "bitRateChange":

            Task {

                var newBitRate = SharedDefaults.group?.integer(forKey: "bitRate") ?? 6_000_000

                if RPConfig.shared.enableSocketLog {
                    if let raw = try await SocketClient.shared.requestSet(for: "bitRate", type: "Int") {
                        if let av = raw as? Int {
                            let oldV = newBitRate
                            newBitRate = av
                            logger.debug("bitRateChange \(av)")
                            sendlog(message: "Socket原始bitRate數據包:\(av) -> \(oldV)")
                        } else {
                            logger.error("bitRateChange 型別錯誤: \(type(of: raw))")
                        }
                    }
                }

                guard newBitRate > 0 else { return }
                RPConfig.shared.state.BitRate = newBitRate

                var settings = await rtmpStream.videoSettings
                settings.bitRate = newBitRate
                try? await rtmpStream.setVideoSettings(settings)
                await streamStataus?.updateVideoBitRate(to: newBitRate)

                sendlog(message: "bitRateChange: 更新 bitrate=\(newBitRate/1000)kbps")
            }

            break





        case "logURL":

            Task {

                var logM=SharedDefaults.group?.string(
                    forKey: "logURL"
                ) ?? "http://192.168.0.242/post"

                if RPConfig.shared.enableSocketLog {
                    if let raw = try await SocketClient.shared.requestSet(for: "logURL", type: "String") {

                        if let av = raw as? String {
                            let oldV = logM
                            logM = av

                            logger.debug("logURL \(av)")
                            sendlog(message: "Socket原始logURL數據包:\(av) -> \(oldV)")
                        } else {
                            logger.error("logURL 型別錯誤: \(type(of: raw))")
                        }

                    }
                }

                RPConfig.shared.logURL = logM
                sendlog(message: "LOG URL: \(logM)")

            }

            break



        case "logMode":
            
            Task {

                var logM=SharedDefaults.group?.integer(forKey: "logMode") ?? 0
                if RPConfig.shared.enableSocketLog {
                    if let raw = try await SocketClient.shared.requestSet(for: "logMode", type: "Int") {

                        if let av = raw as? Int {
                            let oldV = logM
                            logM = av

                            logger.debug("logMode \(av)")
                            sendlog(message: "Socket原始logMode數據包:\(av) -> \(oldV)")
                        } else {
                            logger.error("logMode 型別錯誤: \(type(of: raw))")
                        }

                    }
                }

                sendlog(message: "LOG Mode \(logM)")

                RPConfig.shared.logMode=logM
                RPConfig.shared.applyLogMode()

            }

            break




        case "onlogPage":
            

            Task {

                var logPage=SharedDefaults.group?.bool(forKey: "onlogPage") ?? false

                if RPConfig.shared.enableSocketLog {
                    if let raw = try await SocketClient.shared.requestSet(for: "onlogPage", type: "Bool") {

                        if let av = raw as? Bool {
                            let oldV = logPage
                            logPage = av

                            logger.debug("logPage \(av)")
                            sendlog(message: "Socket原始logPage數據包:\(av) -> \(oldV)")
                        } else {
                            logger.error("logPage 型別錯誤: \(type(of: raw))")
                        }

                    }

                    SocketClient.shared
                        .sendSettings(
                            key: "ReplyKitWidth",
                            value: ReplyKitW
                        )
                    SocketClient.shared
                        .sendSettings(
                            key: "ReplyKitHeight",
                            value: ReplyKitH
                        )
                    
                }

                RPConfig.shared.onLogPage=logPage
                updateONLogFixState()


                if logPage {

                    LogManager.shared.forceFlush()
                    LogManager.shared.setupFlushTimer()



                    sendlog(message: "正在LOG")

                } else {
                    LogManager.shared.forceFlush()

                    sendlog(message: "非LOG")
                }

            }

            break



        case "VideoSet":
            Task {
                let mediaSet = await mediaMixer.videoInputFormats


                let fps = await mediaMixer.frameRate

                let videoSet = await rtmpStream.videoSettings

                let track = await mediaMixer.videoMixerSettings.mainTrack

                sendlog(message: "FrameRate:\(fps) \nmediaSet:\(mediaSet) \nVTrack:\(track)\nVideoSet:\(videoSet)")

                ExtensionMessagePort.shared.send(toApp: [
                    "FPS": "\(fps)",
                    "VideoSet":"\(videoSet)"
                                                        ]
                )


            }

            break

        case "OutW":
            var dstRW=SharedDefaults.group?.integer(forKey: "dstW") ?? 0

            Task {
                if RPConfig.shared.enableSocketLog {
                    if let raw = try await SocketClient.shared.requestSet(
                        for: "dstW",
                        type: "Int"
                    ) {

                        if let av = raw as? Int {
                            let oldV = dstRW
                            dstRW = av

                            logger.debug("OutW \(av)")
                            sendlog(message: "Socket原始OutW數據包:\(av) -> \(oldV)")
                        } else {
                            logger.error("OutW 型別錯誤: \(type(of: raw))")
                        }

                    }
                }

                guard dstRW > 0 else {
                    sendlog(message: "OutW 跳過: dstW=\(dstRW) 無效")
                    return
                }

                let dstRH = SharedDefaults.group?.integer(forKey: "dstH") ?? 0
                guard dstRH > 0 else {
                    sendlog(message: "OutW 跳過: dstH=\(dstRH) 無效(尚未收到 OutH)")
                    return
                }

                var VSET = await rtmpStream.videoSettings
                VSET.videoSize = CGSize(width: CGFloat(dstRW), height: CGFloat(dstRH))

                try await rtmpStream.setVideoSettings(VSET)

                ADWidth = dstRW
                ADHeight = dstRH
                await videoProcessor?.setRotatorDestination(width: dstRW, height: dstRH)
                sendlog(message: "OutW:\(dstRW)x\(dstRH)")

            }
            
            break



        case "OutH":
            var dstRH=SharedDefaults.group?.integer(forKey: "dstH") ?? 0

            Task {
                if RPConfig.shared.enableSocketLog {
                    if let raw = try await SocketClient.shared.requestSet(for: "dstH", type: "Int") {

                        if let av = raw as? Int {
                            let oldV = dstRH
                            dstRH = av

                            logger.debug("OutH \(av)")
                            sendlog(message: "Socket原始OutH數據包:\(av) -> \(oldV)")
                        } else {
                            logger.error("OutH 型別錯誤: \(type(of: raw))")
                        }

                    }
                }

                guard dstRH > 0 else {
                    sendlog(message: "OutH 跳過: dstH=\(dstRH) 無效")
                    return
                }

                let dstRW = SharedDefaults.group?.integer(forKey: "dstW") ?? 0
                guard dstRW > 0 else {
                    sendlog(message: "OutH 跳過: dstW=\(dstRW) 無效(尚未收到 OutW)")
                    return
                }

                var VSET = await rtmpStream.videoSettings
                VSET.videoSize = CGSize(width: CGFloat(dstRW), height: CGFloat(dstRH))

                try await rtmpStream.setVideoSettings(VSET)

                ADWidth = dstRW
                ADHeight = dstRH
                await videoProcessor?.setRotatorDestination(width: dstRW, height: dstRH)

                sendlog(message: "OutH:\(dstRW)x\(dstRH)")


            }

            break





        case "Enablelog":
            var Enablelog=SharedDefaults.group?.bool(forKey: "Enablelog") ?? false

            Task {
                if RPConfig.shared.enableSocketLog {
                    if let raw = try await SocketClient.shared.requestSet(for: "Enablelog", type: "Bool") {

                        if let av = raw as? Bool {
                            let oldV = Enablelog
                            Enablelog = av

                            logger.debug("EnableLog \(av)")
                            sendlog(message: "Socket原始EnableLog數據包:\(av) -> \(oldV)")
                        } else {
                            logger.error("EnableLog 型別錯誤: \(type(of: raw))")
                        }

                    }
                }

                sendlog(message: "開關日誌log \(Enablelog)")
                RPConfig.shared.enableLog=Enablelog


            }


            break

            


        case "onAudioPage":
            
            Task {
                var APage=SharedDefaults.group?.bool(forKey: "onAudioPage") ?? false

                if RPConfig.shared.enableSocketLog {
                    if let raw = try await SocketClient.shared.requestSet(for: "onAudioPage", type: "Bool") {

                        if let av = raw as? Bool {
                            let oldV = APage
                            APage = av

                            logger.debug("onAudioPage \(av)")
                            sendlog(message: "Socket原始onAudioPage數據包:\(av) -> \(oldV)")
                        } else {
                            logger.error("onAudioPage 型別錯誤: \(type(of: raw))")
                        }

                    }
                }

                RPConfig.shared.onAudioPage = APage
                sendlog(message: "AudioPage:\(String(describing: RPConfig.shared.onAudioPage)) processorInit:\(processorsInitialized)")

                if audioProcessor != nil {

                    audioProcessor?.updatePage(status: RPConfig.shared.onAudioPage)
                    sendlog(
                        message:"[Audio] Page \(String(describing: RPConfig.shared.onAudioPage))"
                    )

                } else if processorsInitialized {

                    sendlog(message:"[Audio] ⚠️ audioProcessor 為 nil 但 processorsInitialized=true，呼叫 rebuildAudio")
                    rebuildAudio()
                    audioProcessor?.updatePage(status: RPConfig.shared.onAudioPage)

                } else {

                    sendlog(message:"[Audio] ⚠️ audioProcessor 為 nil，processorsInitialized=false，排程延遲重試")
                    Task.detached { [weak self] in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        guard let self else { return }
                        let isInit = await MainActor.run { self.processorsInitialized }
                        guard isInit else {
                            await MainActor.run { sendlog(message:"[Audio] ⚠️ 延遲重試逾時或已停止，跳過") }
                            return
                        }
                        await MainActor.run {
                            sendlog(message:"[Audio] 延遲重試: processors 已就緒，套用 onAudioPage=\(RPConfig.shared.onAudioPage)")
                            if self.audioProcessor != nil {
                                self.audioProcessor?.updatePage(status: RPConfig.shared.onAudioPage)
                            } else {
                                self.rebuildAudio()
                                self.audioProcessor?.updatePage(status: RPConfig.shared.onAudioPage)
                            }
                        }
                    }

                }

            }

            break





        case "PauseStream":
            // TODO: 這裡不應該調用系統用函數
            //self.broadcastPaused()
            sendlog(message: "你暫停直播畫面！")

            break

        case "ResumeStream":
            // TODO: 這裡不應該調用系統用函數
            //self.broadcastResumed()
            sendlog(message: "你恢復了直播畫面！")

            break


            
        default:
            break
        }
    }



    // MARK: 初始化
    override init() {

        ADWidth = RPConfig.shared.state.ADWidth
        ADHeight = RPConfig.shared.state.ADHeight

        ODWidth = RPConfig.shared.state.ODWidth
        ODHeight = RPConfig.shared.state.ODHeight

        super.init()

        registerObservers()
        logger.info("ReplyKit Debug")

    }

    deinit {
        logger.info("ReplyKit Debug deinit")

    }







    func updateAppAudioVolume(_ volume: Float) async {
        var settings = await mediaMixer.audioMixerSettings

            if var track = settings.tracks[0] {
                // 0 是 app 音頻 track
                if volume >= 1.0 {
                    
                    track = .default

                } else {
                    
                
                    track.volume = volume  
                
                }   // volume 值 0.0 ~ 1.0

                settings.tracks[0] = track
                
            }
        
        await mediaMixer.setAudioMixerSettings(settings)
    }

    func updateMicAudioVolume(_ volume: Float) async {
        var settings = await mediaMixer.audioMixerSettings


            if var track = settings.tracks[1] {
                // 1 是 麥克風 track
                if volume >= 1.0 {
                    
                    track = .default

                } else {
                    
                
                    track.volume = volume  
                
                }   // volume 值 0.0 ~ 1.0
                
                settings.tracks[1] = track
        
            }

        await mediaMixer.setAudioMixerSettings(settings)
    }

#if os(iOS)
    // --- 將原來的 updateVideoOrientation 改成下面這個 ---
    func avOrientation(from deviceOrientation: UIDeviceOrientation) -> AVCaptureVideoOrientation? {
        switch deviceOrientation {
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscapeLeft:
            // 注意：UIDevice.landscapeLeft 表示裝置左邊朝下，對 camera 方向可能要反向映射視鏡頭而定

            return .landscapeLeft
        case .landscapeRight:
            return .landscapeRight
        default:
            return .landscapeLeft
        }
    }

    func isLandscape(_ orientation: AVCaptureVideoOrientation) -> Bool {
        switch orientation {
        case .landscapeLeft, .landscapeRight:
            return true
        default:
            return false
        }
    }

    func updateVideoOrientation(from orientation: UIDeviceOrientation) async {
        // 轉成 AVFoundation 的方向

        guard let avOrientation = avOrientation(from: orientation) else { return }

        sendlog(message: "[旋轉時間軸] updateVideoOrientation device:\(orientation.rawValue) av:\(avOrientation.rawValue)")

        var videoSettings = await rtmpStream.videoSettings
        var size = videoSettings.videoSize


        let newSize:CGSize

        if ODWidth > 0 && ODHeight > 0 {
            sendlog(message: "[旋轉時間軸] 畫布設定寬高：\(ODWidth) x \(ODHeight)")
            size.width = CGFloat(ODHeight)
            size.height = CGFloat(ODWidth)
        }else if ADWidth > 0 && ADHeight > 0 {
            sendlog(message: "[旋轉時間軸] 用戶設定目標寬高：\(ADWidth) x \(ADHeight)")
            size.width = CGFloat(ADHeight)
            size.height = CGFloat(ADWidth)
        }

        switch avOrientation {
        case .portrait, .portraitUpsideDown:
            newSize = CGSize(width: size.height, height: size.width)
            sendlog(message: "[旋轉時間軸] 直向:\(size) → \(videoSettings)")

        default:
            newSize = CGSize(width: size.height, height: size.width)
            sendlog(message: "[旋轉時間軸] 橫向:\(size) → \(videoSettings)")


            break;
        }

        // 如果上次已經設過這個 avOrientation，就不用再設

        if avOrientation != lastVideoOrientation {
            lastVideoOrientation = avOrientation
            await mediaMixer.setVideoOrientation(avOrientation)
            sendlog(message: "更新方向: \(orientation) -> \(avOrientation)")

        }

        if videoSettings.videoSize != newSize {

            sendlog(message: "NewSize:\(newSize) - Old:\(videoSettings)")

            videoSettings.videoSize = newSize
            try? await rtmpStream.setVideoSettings(videoSettings)

        }

    }

#endif




    // MARK: 設定方向偵測 已棄用
    // func configureOrientation() {
    //     let manager = DeviceOrientationManager.shared   // 使用單例
    //     let lockedValue = SharedDefaults.group?.bool(forKey: "LockIN") ?? false
    //     if  lockedValue {
    //         sendlog(message:"\(lockedValue)不偵測 初始化一次")
    //         manager.isEnabled = false
    //         manager.stopUpdates()
    //     } else {
    //         // 解鎖方向 → 啟動 Motion 偵測
    //         manager.isEnabled = true
    //         sendlog(message:"偵測開啟")
    //         manager.startUpdates()
    //         manager.orientationChanged = { [weak self] deviceOrientation in

    //             sendlog(message: "方向Free中")
    //             #if os(iOS)
    //             guard let self else { return }
    //             Task {
    //                 await self.updateVideoOrientation(from: deviceOrientation)
    //             }
    //             #endif

    //         }
    //     }
    // }

    var isStopping = false
    private var processorsInitialized = false

    func stopBroadcastWithError(_ message: String) {

        guard !isStopping else { return }
        isStopping = true

        let error = NSError(domain: "com.liveApp.broadcast",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: message])
        // 如果 broadcastEnd 是 async
           Task {
               sendlog(message: message)
               broadcastEnd(message: message)  // 等待清理完成
               await MainActor.run {
                   finishBroadcastWithError(error)

               }
           }

    }





    private var disconnectMonitorTask: Task<Void, Never>?

    // MARK: 斷線檢測
    func startDisconnectMonitor() {
        disconnectMonitorTask = Task { [weak self, weak streamStataus] in
            while !(self?.isStopping ?? true) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await streamStataus?.checkDisconnect(timeout: 5)
            }
        }
    }


    func prepareCompressionSession(){
        var compressionSession: VTCompressionSession?

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: 1920,
            height: 1080,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &compressionSession
        )

        if status == noErr {
            logger.info("✅ 建立成功: \(String(describing: compressionSession))")
        } else {
            logger.info("❌ 建立失敗: \(status)")
        }
        if let session = compressionSession {
            var supportedProps: CFDictionary?
            if VTSessionCopySupportedPropertyDictionary(session, supportedPropertyDictionaryOut: &supportedProps) == noErr {

                if let props = supportedProps as? [String: Any] {
                            logger.debug("✅ Supported properties: \(props)")
                        } else {
                            logger.debug("⚠️ 無法轉換 CFDictionary")
                        }


            } else {
                logger.debug("❌ 無法取得 SupportedPropertyDictionary")
            }


        }
        compressionSession = nil

    }

    
    func setUserDefalutConfig(urlString:String = "rtmp://192.168.0.106/live" ,streamKey:String = "test")  {


        // MARK: Video dimensions
        ADWidth = RPConfig.shared.state.ADWidth
        ADHeight = RPConfig.shared.state.ADHeight

        // MARK: Out Video 寬高

        ODWidth = RPConfig.shared.state.ODWidth
        ODHeight = RPConfig.shared.state.ODHeight

        if ODWidth > 0 && ODHeight > 0 {
            DWidth = ODWidth
            DHeight = ODHeight

        } else if ADWidth > 0 && ADHeight > 0 {
            DWidth = ADWidth
            DHeight = ADHeight
        }


        sendlog(message:"ADWH:\(ADWidth)x\(ADHeight) ODWH:\(ODWidth)x\(ODHeight)")


        // MARK: Volume
        let newMicAddVolume = RPConfig.shared.state.MicVolumeAdd
        let newAppAddVolume = RPConfig.shared.state.AppVolumeAdd

        micAddVolume=Float(newMicAddVolume)
        appAddVolume=Float(newAppAddVolume)

        appVolume=Float(RPConfig.shared.state.AppVolume)
        micVolume=Float(RPConfig.shared.state.MicVolume)



        let safelogKey = fixlogSafeKey(streamKey)
        // 組成完整 RTMP URL
        let fullURLString = "\(urlString)/\(safelogKey)"


        // MARK: 是否在日誌Log mode由Socket內部處理


        sendlog(message: "🔹 推流 URL:\(fullURLString)\nApp:\(appVolume)  Mic:\(micVolume) AppAdd:\(appAddVolume) MicAdd:\(micAddVolume)")


    }


    func h264ProfileLevelString(width: Int, height: Int) -> String {
        switch RPConfig.shared.state.h264level {
        case "Baseline":
            return h264ProfileLevel(forWidth: width, height: height, fps: 60, profile: .baseline)
        case "Main":
            return h264ProfileLevel(forWidth: width, height: height, fps: 60, profile: .main)
        case "High":
            return h264ProfileLevel(forWidth: width, height: height, fps: 60, profile: .high)
        case "AutoBaseline":
            return kVTProfileLevel_H264_Baseline_AutoLevel as String
        case "AutoMain":
            return kVTProfileLevel_H264_Main_AutoLevel as String
        case "AutoHigh":
            return kVTProfileLevel_H264_High_AutoLevel as String
        case "ConstrainedBaseline":
            return kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel as String
        case "ConstrainedHigh":
            return kVTProfileLevel_H264_ConstrainedHigh_AutoLevel as String
        case "Extended":
            return kVTProfileLevel_H264_Extended_AutoLevel as String
        default:
            return kVTProfileLevel_H264_High_AutoLevel as String
        }
    }

    func applyAllVideoSettings(width: Int, height: Int, stream: RTMPStream? = nil, setSize: Bool = true) async {
        guard let target = stream ?? rtmpStream else { return }
        var videoSettings = await target.videoSettings

        let profilelvl = h264ProfileLevelString(width: width, height: height)
        videoSettings.profileLevel = profilelvl
        videoSettings.scalingMode = .letterbox

        if setSize {
            let rotate = RPConfig.shared.state.Rotate
            if rotate == 0 || rotate == 180 {
                videoSettings.videoSize = CGSize(width: CGFloat(height), height: CGFloat(width))
            } else {
                videoSettings.videoSize = CGSize(width: CGFloat(width), height: CGFloat(height))
            }
        }

        // 此參數基準以修改後 https://github.com/TwhomeGH/HaishinKitFixSwfit 的版本內部設計為主，
        // 實測在 30fps 以下的幀率下，設置過高的 expectedFrameRate 反而會導致實際幀率下降，甚至出現卡頓。因此建議根據實際情況設置一個合理的幀率上限，例如 60fps。

        let expectedFrameRate = 60.0
        videoSettings.expectedFrameRate = expectedFrameRate
        //不改預設值 videoSettings.frameInterval = 1.0 / expectedFrameRate

        switch RPConfig.shared.state.BitRateMode {
        case 0:
            videoSettings.bitRateMode = .average
        case 1:
            videoSettings.bitRateMode = .constant
        case 2:
            videoSettings.bitRateMode = .variable
        case 3:
            videoSettings.bitRateMode = .quality
        default:
            videoSettings.bitRateMode = .average
        }

        let kv = RPConfig.shared.state.KeyFrameInterval
        videoSettings.maxKeyFrameIntervalDuration = Int32(kv)

        videoSettings.allowFrameReordering = true
        videoSettings.isLowLatencyRateControlEnabled = RPConfig.shared.state.isLowLatencyRateControlEnabled
        videoSettings.bitRate = RPConfig.shared.state.BitRate

        try? await target.setVideoSettings(videoSettings)
        await streamStataus?.updateVideoBitRate(to: RPConfig.shared.state.BitRate)
        sendlog(message: "套用完整 video settings: \(width)x\(height) profile=\(profilelvl) keyframe=\(kv)s bitrate=\(RPConfig.shared.state.BitRate/1000)kbps")
    }

    func configureVideo_init() async {
        // Video settings

        

        await mediaMixer.setSessionPreset(.inputPriority)

        
        // Video mixer passthrough
        var videoMixerSettings = await mediaMixer.videoMixerSettings
        videoMixerSettings.mode = .passthrough

        let track = videoMixerSettings.mainTrack

        sendlog(message:"VTrack:\(track)")


        
        
        await mediaMixer.setVideoMixerSettings(videoMixerSettings)

        let BCount = max(RPConfig.shared.state.BufferCount,3)
        // ReplayKit is sensitive to memory, so we limit the queue to a maximum of five items.
        await rtmpStream.setVideoInputBufferCounts(BCount)

        sendlog(message: "Video Buffer -> \(BCount)")

        // 在 frame 到來前先用 socket 配置設定 video size
        var dstW: Int
        var dstH: Int
        if RPConfig.shared.state.ODWidth > 0 && RPConfig.shared.state.ODHeight > 0 {
            dstW = RPConfig.shared.state.ODWidth
            dstH = RPConfig.shared.state.ODHeight
        } else if RPConfig.shared.state.ADWidth > 0 && RPConfig.shared.state.ADHeight > 0 {
            dstW = RPConfig.shared.state.ADWidth
            dstH = RPConfig.shared.state.ADHeight
        } else {
            // fallback: 讀取 App Group 中上次設定的值
            dstW = SharedDefaults.group?.integer(forKey: "dstW") ?? 0
            dstH = SharedDefaults.group?.integer(forKey: "dstH") ?? 0
            if dstW > 0 && dstH > 0 {
                sendlog(message: "使用 UserDefaults fallback: \(dstW)x\(dstH)")
            }
        }

        if dstW > 0 && dstH > 0 {
            await applyAllVideoSettings(width: dstW, height: dstH)
            sendlog(message: "預設影片尺寸: \(dstW)x\(dstH)")
        } else {
            sendlog(message: "⚠️ 警告：未指定影片尺寸，將沿用ReplyKIT的寬高 Auto自動設置")
        }

    }
    func configureAudio() async {
        // Audio settings
        var audioSettings = await mediaMixer.audioMixerSettings
        audioSettings.tracks[0] = .default
        audioSettings.tracks[1] = .default

        await mediaMixer.setAudioMixerSettings(audioSettings)

        reloadVolumes()



    }
    // MARK: Video Setting
    func configureMediaMixer() async {

        // AdaptiveVideoBufferManager 已停用：setVideoInputBufferCounts 在 runtime 無效
        // adaptiveBufferManager = AdaptiveVideoBufferManager()

        streamStataus = MyStreamBitRateStrategy(
            videoBitRate: RPConfig.shared.state.BitRate
        )

        await streamStataus?.refreshStatusTimestamp()
        await streamStataus?.resetDisconnectCheck()

        await streamStataus?.setOnDisconnect { 
            Task { @MainActor in
                sendlog(message: "斷線監控觸發，由 RTMPConnection 處理重連")
            }
        }


        let Rlog=RPConfig.shared.state.ChangeBit
        
        await streamStataus?.isChangBit(Rlog)


        await rtmpStream.setBitRateStrategy(streamStataus)

        //var audioSet = await rtmpStream.audioSettings
        //audioSet.format = .opus
        
        //try? await rtmpStream.setAudioSettings(audioSet)


        

        
        await mediaMixer.addOutput(rtmpStream)

        didConfigureAudio = false



    }


   // MARK: Process

    func initProcessors() {

        Task { [weak self] in
            await self?.streamStataus?.updateVideoBitRate(to: RPConfig.shared.state.BitRate)
        }

        volumeNotifier = VolumeNotifier()
        sendlog(message: "[Init] volumeNotifier created")


        audioProcessor = AudioProcessor(
                mediaMixer: mediaMixer,
                volumeNotifier: volumeNotifier!,
                appAddVolume: appAddVolume,
                micAddVolume: micAddVolume,
                appVolume: appVolume,
                micVolume: micVolume,
                onAudioPage: RPConfig.shared.onAudioPage
            )
        sendlog(message: "[Init] audioProcessor created \(audioProcessor != nil)")
        
            videoProcessor = VideoFrameProcessor(
                mediaMixer: mediaMixer,
                sendlog: { message in
                    sendlog(message: message)
                }
            )
        sendlog(message: "[Init] videoProcessor created \(videoProcessor != nil)")


            




    }



    func rebuildAudio() {
        guard let notifier = volumeNotifier else {
            sendlog(message: "⚠️ rebuildAudio: volumeNotifier 為 nil，跳過重建")
            return
        }
        audioProcessor?.cleanup()
        audioProcessor = nil

        audioProcessor = AudioProcessor(
            mediaMixer: mediaMixer,
            volumeNotifier: notifier,
            appAddVolume: appAddVolume,
            micAddVolume: micAddVolume,
            appVolume: appVolume,
            micVolume: micVolume,
            onAudioPage: RPConfig.shared.onAudioPage
        )
        sendlog(message: "[Rebuild] audioProcessor 重建 \(audioProcessor != nil)")

    }
    func rebuildVideo() {
        videoProcessor?.cleanup()
        videoProcessor = nil

        videoProcessor = VideoFrameProcessor(
            mediaMixer: mediaMixer,
            sendlog: { message in
                sendlog(message: message)
            }
        )
        sendlog(message: "[Rebuild] videoProcessor 重建 \(videoProcessor != nil)")

    }

    func startRTMP(url:String?,key:String?) async {

        // 設定重連回呼（取代 attemptReconnect）
        await rtmpConnection?.setReconnectEnabled(true)
        await rtmpConnection?.setOnReconnectStateChanged { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .started(let attempt, let maxAttempts):
                sendlog(message: "🔄 RTMP 正在重連 (第 \(attempt)/\(maxAttempts) 次)...")
                self.notifyReconnectStatus(.attempting, attempt: attempt)
                // 重連期間保持 MediaMixer 運行，讓音視頻管線持續處理數據
                self.disconnectMonitorTask?.cancel()
                self.disconnectMonitorTask = nil
            case .succeeded:
                sendlog(message: "🎉 RTMP 重連成功")
                self.isSessionReady = true
                self.notifyReconnectStatus(.success)
                await streamStataus?.resetDisconnectCheck()
                // 重連後需重新 publish stream，否則音影數據無法送出
                if let key = self.rtmpKey {
                    do {
                        _ = try await self.rtmpStream.publish(key)
                        sendlog(message: "🎉 RTMP 重連後重新推流成功")
                    } catch {
                        sendlog(message: "⚠️ RTMP 重連後推流失敗: \(error)")
                    }
                }
                await self.mediaMixer.startRunning()

                self.startDisconnectMonitor()
            case .failed(let error):
                sendlog(message: "RTMP 重連失敗 \(error)")
                self.notifyReconnectStatus(.failed)
            case .exhausted:
                sendlog(message: "⚠️ RTMP 重連次數已達上限，停止直播")
                self.notifyReconnectStatus(.exhausted)
                self.stopBroadcastWithError("RTMP 重連次數已達上限")
            }
        }

        do {

            guard let url = url ,let key = key else {
                stopBroadcastWithError("RTMP配置取得異常!")
                return
            }

            sendlog(message: "🔄 RTMP connect \(url)")
            let connectResult = try await rtmpConnection?.connect(url)
            sendlog(message: "🔄 RTMP connect 完成: \(connectResult?.description ?? "nil")")
            sendlog(message: "🔄 RTMP publish \(fixlogSafeKey(key))")
            _ = try await rtmpStream.publish(key)

            sendlog(message:"🎉 RTMP:\(url)/ KEY:\(fixlogSafeKey(key)) 連線成功",flush: true)
            // step 4: 標記 session ready
            await MainActor.run {
                // Add output
                self.isSessionReady = true

                sendlog(message:"🎉 RTMP 推流成功",flush: true)
                logger.info("🎉 RTMP 推流成功")

                // 恢復斷線監控
                self.startDisconnectMonitor()

                self.notifyReconnectStatus(.success)

            }

        }  catch RTMPConnection.Error.requestFailed(let response) {
            sendlog(message: "RTMP 服務器連線失敗 \(response)，由 RTMPConnection 自動重連")

    }  catch RTMPStream.Error.requestFailed(let response) {
            sendlog(message: "RTMP 推流失敗 \(response)，由 RTMPConnection 自動重連")


        } catch {
            sendlog(message: "RTMP 其他錯誤 \(error)，由 RTMPConnection 自動重連")

    }


    }

    func notifyReconnectStatus(_ status: ReconnectStatus, attempt: Int = 0) {
        let payload: [String: Any] = [
            "type": "reconnectStatus",
            "status": status.rawValue,
            "attempt": attempt
        ]
        SocketClient.shared.sendPayload(payload)
    }

    enum ReconnectStatus: String {
        case attempting
        case success
        case failed
        case exhausted
    }

    // MARK: Socket 重連後自動同步配置
    func handleSocketReconnected() {
        guard isInitialSyncDone, !isStopping else { return }

        sendlog(message: "Socket 已重連，開始同步配置...")

        Task {
            let oldRTMPURL = self.rtmpURL
            let oldRTMPKey = self.rtmpKey

            let success = await SocketClient.shared.requestRTMPKEYAndLog()

            if success {
                let newRTMPURL = RPConfig.shared.state.RTMPURL
                let newRTMPKey = RPConfig.shared.state.RTMPKey

                let configChanged = (oldRTMPURL != newRTMPURL) || (oldRTMPKey != newRTMPKey)

                sendlog(message: "RTMP 配置同步完成，URL 變更: \(configChanged ? "是" : "否")")

                if configChanged {
                    self.rtmpURL = newRTMPURL
                    self.rtmpKey = newRTMPKey

                    self.setUserDefalutConfig(
                        urlString: self.rtmpURL ?? "rtmp://192.168.0.242/live",
                        streamKey: self.rtmpKey ?? "test"
                    )

                    await startRTMP(url: self.rtmpURL, key: self.rtmpKey)
                    sendlog(message: "RTMP 配置已變更，觸發重連")
                } else {
                    await self.streamStataus?.checkDisconnect(timeout: 3)
                    sendlog(message: "RTMP 配置未變更，僅檢查連線健康度")
                }
            } else {
                sendlog(message: "RTMP 配置同步失敗，1 秒後重試")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let retry = await SocketClient.shared.requestRTMPKEYAndLog()
                if retry {
                    self.rtmpURL = RPConfig.shared.state.RTMPURL
                    self.rtmpKey = RPConfig.shared.state.RTMPKey
                    sendlog(message: "重試成功，RTMP 配置已同步")
                } else {
                    sendlog(message: "RTMP 配置同步最終失敗")
                }
            }
        }
    }

    // MARK: 直播開始
    override func broadcastStarted(
        withSetupInfo setupInfo: [String : NSObject]?
    ) {
        // User has requested to start the broadcast. Setup info from the UI extension can be suppdlied but optional.
        // Task已更命 priority default已棄用 -> 更名為 medium，避免在高優先級下阻塞其他任務

        Task(priority: .medium) {

            //進行Socket初始化
            SocketClient.shared.setupConnection()
            SocketClient.shared.sendLog(message: "直播開始，初始化Socket連線")

            logger.info("運行通知")

            // 先關閉，等 socket 配置套用後再開啟
            self.needVideoConfiguration = false
            self.needAudioConfiguration = true
            self.isBroadcasting = true
            self.isStopping = false


            //self.prepareCompressionSession()


            // 同時發出兩個請求 (最多重試 3 次，不 sleep 避免 extension 超時)
            var result = await SocketClient.shared.requestRTMPKEYAndLog()
            for _ in 0..<2 where !result {
                sendlog(message: "Socket 請求失敗，立即重試...")
                result = await SocketClient.shared.requestRTMPKEYAndLog()
            }

            logger.debug("Final result -> RTMP & LogConfig: \(result)")

            sendlog(
                message:"Final result -> RTMP & LogConfig: \(result)",
            )

            guard result else {
                let msg = "Socket 請求失敗，無法取得推流設定"
                sendlog(message: msg)
                self.stopBroadcastWithError(msg)
                return
            }

            // 🔹 從 Socket 拿 RTMP 設定
            self.rtmpURL = RPConfig.shared.state.RTMPURL
            self.rtmpKey = RPConfig.shared.state.RTMPKey
            sendlog(message: "使用 RTMP \(self.rtmpURL ?? "nil") key:\(fixlogSafeKey(self.rtmpKey ?? "nil"))")

            self.setUserDefalutConfig(
                urlString: self.rtmpURL ?? "rtmp://192.168.0.242/live",
                streamKey: self.rtmpKey ?? "test"
            )


                logger.debug("✅ RTMP設定: \(String(describing: self.rtmpURL)) \(String(describing: self.rtmpKey))")

                sendlog(message:"✅App:\(self.appVolume)  Mic:\(self.micVolume) AppAdd:\(self.appAddVolume) MicAdd:\(self.micAddVolume)")

                // socket 收完所有參數後才建立連線
                let enh = RPConfig.shared.state.useEnhancedRTMP
                self.rtmpConnection = RTMPConnection(useEnhancedRTMP: enh)
                self.rtmpStream = RTMPStream(connection: self.rtmpConnection!)

                await self.rtmpConnection?.setOnLog { event in
                    guard RPConfig.shared.state.enableRTMPLog else { return }
                    sendlog(message: "[RTMP] \(event.level) \(event.message) \(event.detail ?? "")")
                }

                self.lastConfiguredSize = nil

                self.needVideoConfiguration = true

                await self.configureVideo_init()
                await self.configureAudio()
                await self.configureMediaMixer()
                await Task.yield()

                sendlog(message:"✅ MediaMixer 配置完成")

                logger.info("✅ MediaMixer 配置完成")

                
                // configureVideo_init() 已套用完整 videoSettings，此處僅 log 確認
                let publishSize = await self.rtmpStream.videoSettings.videoSize
                sendlog(message: "RTMP Publish 前 videoSize: \(Int(publishSize.width))x\(Int(publishSize.height))")

                // 先初始化 Processor，確保音視頻管線在 RTMP 連線前準備就緒
                self.initProcessors()
                self.processorsInitialized = true
                sendlog(message:"✅ Processor 初始化完成 audio:\(self.audioProcessor != nil) video:\(self.videoProcessor != nil)")
                logger.info("✅ Processor 初始化完成")

                // 先啟動 MediaMixer，避免連線失敗時整條管線停擺
                // 隔離 HaishinKit 內部 Task 的 stack 壓力
                let mixer = self.mediaMixer
                await Task.detached(priority: .medium) {
                    await mixer.startRunning()
                }.value
                sendlog(message:"✅ MediaMixer 已啟動，開始接收音視頻數據")

                let url = self.rtmpURL
                let key = self.rtmpKey
                await Task.detached(priority: .medium) { [self] in
                    await self.startRTMP(url: url, key: key)
                }.value

                self.isInitialSyncDone = true
                SocketClient.shared.onSocketReady = { [weak self] in
                    Task { [weak self] in
                        self?.handleSocketReconnected()
                    }
                }
                sendlog(message: "已註冊 Socket 重連自動同步")


                
            }



    }


    // MARK: 直播暫停
    override func broadcastPaused() {
        isBroadcastPaused = true
        sendlog(message: "⏸️ 廣播暫停（進入背景）")
        disconnectMonitorTask?.cancel()
        disconnectMonitorTask = nil
    }

    // MARK: 直播恢復
    override func broadcastResumed() {
        isBroadcastPaused = false
        sendlog(message: "📹 廣播恢復（前景）")

        guard isSessionReady, !isStopping else { return }

        Task(priority: .medium) { [weak self] in
            guard let self else { return }

            // 確保 Socket 連線（背景時可能斷開）
            SocketClient.shared.setupConnection()

            // 重啓 MediaMixer（若被系統暫停）
            if !(await mediaMixer.isRunning) {
                await mediaMixer.startRunning()
                sendlog(message: "📹 MediaMixer 已重新啟動")
            }

            // 重新套用 video settings，强迫 VideoToolbox 重建 encoder session
            if let stream = rtmpStream {
                do {
                    let settings = await stream.videoSettings
                    try await stream.setVideoSettings(settings)
                    sendlog(message: "📹 Video encoder 已重建")
                } catch {
                    sendlog(message: "⚠️ Video encoder 重建失敗: \(error)")
                }
            }

            // 重建 video processor 確保 ProcessorActor 狀態乾淨（resetProcessing 無法清除 actor 內部卡死）
            rebuildVideo()

            // 重啟斷線監控
            startDisconnectMonitor()
        }
    }

    private var isBroadcasting = false
    private var isBroadcastPaused = false

    // MARK: 直播結束處理
    func broadcastEnd(message:String = "正常結束")  {
        // User has requested to finish the broadcast.

        
        Task {

            isStopping = true
            isBroadcasting = false
            isInitialSyncDone = false

            SocketClient.shared.onSocketReady = nil
            SocketClient.shared.sendStreamEnd()

            // 停止斷線監控 Task
            disconnectMonitorTask?.cancel()
            disconnectMonitorTask = nil

            
            isSessionReady = false

            
            removeObservers()

            await mediaMixer.removeOutput(rtmpStream)
            await mediaMixer.stopRunning()

            // 取消重連（由 RTMPConnection 內部處理，關閉連線即可）

            _ = try? await rtmpStream.close()
            _ = try? await rtmpConnection?.close()

            volumeNotifier=nil

            videoProcessor?.cleanup()
            videoProcessor=nil

            audioProcessor?.cleanup()
            audioProcessor=nil
            // AdaptiveVideoBufferManager 已停用
            // adaptiveBufferManager = nil

            sendlog(message:"[RTMP] \(message)")
            

        }


        LogManager.shared.forceFlush()



    }


    override func broadcastFinished() {

        broadcastEnd()

    }




    // MARK: 內部已配置處理
    private var didConfigureAudio = true


    var ReplyKitW = 0
    var ReplyKitH = 0

    /// 根據解析度與幀率選擇對應 H.264 High Profile Level

    enum H264Profile: String {
        case baseline = "Baseline"
        case main = "Main"
        case high = "High"
    }

    /// 根據解析度、幀率與 Profile 選擇 H.264 Level
    func h264ProfileLevel(forWidth width: Int, height: Int, fps: Int, profile: H264Profile) -> String {
        // 計算宏塊數
        let macroblockWidth = (width + 15) / 16
        let macroblockHeight = (height + 15) / 16
        let mbPerFrame = macroblockWidth * macroblockHeight

        switch profile {
        case .baseline:
            switch mbPerFrame {
            case 0..<1620: return kVTProfileLevel_H264_Baseline_3_0 as String
            case 1620..<3600:
                return fps <= 30 ? kVTProfileLevel_H264_Baseline_3_1 as String : kVTProfileLevel_H264_Baseline_3_2 as String
            case 3600..<8192: return fps <= 30 ? kVTProfileLevel_H264_Baseline_4_0 as String : kVTProfileLevel_H264_Baseline_4_1 as String
            default: return kVTProfileLevel_H264_Baseline_4_2 as String
            }

        case .main:
            switch mbPerFrame {
            case 0..<1620: return kVTProfileLevel_H264_Main_3_0 as String
            case 1620..<3600:
                return fps <= 30 ? kVTProfileLevel_H264_Main_3_1 as String : kVTProfileLevel_H264_Main_3_2 as String
            case 3600..<8192: return fps <= 30 ? kVTProfileLevel_H264_Main_4_0 as String : kVTProfileLevel_H264_Main_4_1 as String
            default: return kVTProfileLevel_H264_Main_4_2 as String
            }

        case .high:
            switch mbPerFrame {
            case 0..<1620: return kVTProfileLevel_H264_High_3_0 as String
            case 1620..<3600:
                return fps <= 30 ? kVTProfileLevel_H264_High_3_1 as String : kVTProfileLevel_H264_High_3_2 as String
            case 3600..<8192: return fps <= 30 ? kVTProfileLevel_H264_High_4_0 as String : kVTProfileLevel_H264_High_4_1 as String
            case 8192..<8704: return kVTProfileLevel_H264_High_4_2 as String
            case 8704..<36864: return kVTProfileLevel_H264_High_5_0 as String
            default: return fps <= 60 ? kVTProfileLevel_H264_High_5_1 as String : kVTProfileLevel_H264_High_5_2 as String
            }
        }
    }

    func configureVideo(_ sampleBuffer: CMSampleBuffer) async {


        guard let formatDesc = sampleBuffer.formatDescription else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)

        guard dims.width > 0 && dims.height > 0 else { return }



        var width = Int(dims.width)
        var height = Int(dims.height)

        let SharedW:Int = SharedDefaults.group?
            .integer(forKey: "ReplyKitWidth") ?? 0
        let SharedH:Int = SharedDefaults.group?
            .integer(forKey: "ReplyKitHeight") ?? 0

        logger.debug("Width+H ReplyKit:\(height)x\(width)")
        logger.debug("Shared \(SharedW)x\(SharedH)")

        // 寬高是反的 height = width -- width = height

        ReplyKitW = height
        ReplyKitH = width

        if RPConfig.shared.enableSocketLog {


                SocketClient.shared
                    .sendSettings(
                        key: "ReplyKitWidth",
                        value: height
                    )

                SocketClient.shared
                .sendSettings(
                    key: "ReplyKitHeight",
                    value: width
                )

            } else {

                if SharedW != height {

                    SharedDefaults.group?.set(height, forKey: "ReplyKitWidth")
                }

                if SharedH != width  {
                    SharedDefaults.group?.set(width, forKey: "ReplyKitHeight")
                }

            }




        if ODWidth > 0 && ODHeight > 0 {

            sendlog(
                message: "使用指定 輸出設定寬高：\(ODWidth) x \(ODHeight) GPU使用:\(ADWidth)x\(ADHeight)"
            )


            width = ODHeight
            height = ODWidth


        } else if ADWidth > 0 && ADHeight > 0 {
            sendlog(message: "使用與GPU一致設定寬高：\(ADWidth) x \(ADHeight)")
            width = ADHeight
            height = ADWidth
        } else {
            // fallback: 讀取 App Group 中上次設定的值
            let fbW = SharedDefaults.group?.integer(forKey: "dstW") ?? 0
            let fbH = SharedDefaults.group?.integer(forKey: "dstH") ?? 0
            if fbW > 0 && fbH > 0 {
                sendlog(message: "configureVideo fallback UserDefaults: \(fbW)x\(fbH)")
                width = fbH
                height = fbW
            }
        }



        if let orientationValue = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber {
            sendlog(message: "ReplayKit 當前畫面方向: \(orientationValue)")
        }

        var avfrom = lastVideoOrientation
        let newSize: CGSize

        let rotateConfig = RPConfig.shared.state.Rotate
        sendlog(message: "ReplayKit 畫面方向 : \(rotateConfig) | AD:\(ADWidth)x\(ADHeight) OD:\(ODWidth)x\(ODHeight) 原始:\(width)x\(height)")

        switch rotateConfig {
            case 0,180:
                avfrom = .portrait
                sendlog(message: "[旋轉時間軸] 配置=直向(\(rotateConfig)°)")
                break
            case 90,270:
                avfrom = .landscapeRight
                sendlog(message: "[旋轉時間軸] 配置=橫向(\(rotateConfig)°)")
                break
            default:
                avfrom = .landscapeRight
                sendlog(message: "[旋轉時間軸] 配置=橫向預設(\(rotateConfig)°)")
                break
        }

        switch avfrom {
            
        case .portrait, .portraitUpsideDown:
            newSize = CGSize(width: CGFloat(width), height: CGFloat(height))
            sendlog(message: "[旋轉時間軸] 初始更新直向 size:\(newSize)")
            await mediaMixer.setVideoOrientation(.portrait)
            break
        case .landscapeLeft,.landscapeRight:
            newSize = CGSize(width: CGFloat(height), height: CGFloat(width))
            sendlog(message: "[旋轉時間軸] 初始更新橫向 size:\(newSize)")
            await mediaMixer.setVideoOrientation(.landscapeRight)
            break
        default:
            newSize = CGSize(width: CGFloat(height), height: CGFloat(width))
            sendlog(message: "[旋轉時間軸] 初始更新橫向(預設) size:\(newSize)")
            await mediaMixer.setVideoOrientation(.landscapeRight)
            break
        }



        await applyAllVideoSettings(width: width, height: height, setSize: false)

        if lastConfiguredSize != newSize {
            lastConfiguredSize = newSize
            var vs2 = await rtmpStream.videoSettings
            vs2.videoSize = newSize
            try? await rtmpStream.setVideoSettings(vs2)
        }

        sendlog(message: "Video 拿到畫面 \(width)x\(height)")
    }

    var lastlogTime : Double = 0.0
    var lastlogTimeAudio : Double = 0.0
    var logInterval : CFTimeInterval = 1.0
    var logIntervalDetail : CFTimeInterval = 5.0
    var videoFrameCount: Int = 0
    var audioFrameCount: Int = 0
    var lastDetailLogTime: Double = 0.0


    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {


        // 這裡的 sampleBuffer 是 ReplayKit 給的原始幀數據，還沒有經過我們的處理器修改
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        let duration = CMSampleBufferGetDuration(sampleBuffer)

        let timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: timestamp,
            decodeTimeStamp: CMTime.invalid
        )


        lastTimestamp = timing.presentationTimeStamp

        switch sampleBufferType {
        case .video:


            if sampleBuffer.dataReadiness == .ready {

            if needVideoConfiguration {
                
                Task {
                    await self.configureVideo(sampleBuffer)
                }

                needVideoConfiguration = false




            }



            // AdaptiveVideoBufferManager 已停用：setVideoInputBufferCounts 在 runtime 無效
            // if let bm = adaptiveBufferManager {
            //     bm.monitorFPSAndAdjust(
            //         with: sampleBuffer,
            //         rtmpStream: rtmpStream,
            //         sendlog: { msg in sendlog(message: msg) }
            //     )
            // }

            videoFrameCount += 1

            if RPConfig.shared.enablePipelineLog, videoFrameCount == 1 || videoFrameCount % 300 == 0 {
                let sinceStart = timestamp.seconds
                sendlog(message: "[Video流水] #\(videoFrameCount) PTS:\(String(format:"%.3f",sinceStart))s proc:\(videoProcessor != nil ? "Y" : "N") init:\(processorsInitialized)")
            }

            
            if videoProcessor != nil {

                videoProcessor?.process(sampleBuffer,oringinaltime:timing )

            } else if processorsInitialized {
                if lastTimestamp.seconds > lastlogTime + logInterval  {
                    sendlog(message: "[Video] ⚠️ 進程不存在！ count:\(videoFrameCount)")
                    lastlogTime = lastTimestamp.seconds
                    if !isStopping {
                        rebuildVideo()
                    }
                }
            }


            }


            break



        case .audioApp, .audioMic:
            if sampleBuffer.dataReadiness == .ready {

                let trackType: AudioTrackType = (sampleBufferType == .audioApp) ? .app : .mic

                audioFrameCount += 1

                if RPConfig.shared.enablePipelineLog, audioFrameCount == 1 || audioFrameCount % 300 == 0 {
                    let sinceStart = timestamp.seconds
                    sendlog(message: "[Audio流水] #\(audioFrameCount) track:\(trackType) PTS:\(String(format:"%.3f",sinceStart))s proc:\(audioProcessor != nil ? "Y" : "N") init:\(processorsInitialized)")
                }

                
                if needAudioConfiguration  && !didConfigureAudio {
                    didConfigureAudio = true
                    needAudioConfiguration = false

                    sendlog(message: "音訊有效!")

                }


                if audioProcessor != nil {

                    audioProcessor?
                        .enqueue(sampleBuffer, trackType: trackType,oringinaltime:timing)

                } else if processorsInitialized {
                    if lastTimestamp.seconds > lastlogTimeAudio + logInterval  {
                        sendlog(message: "[Audio] ⚠️ 進程不存在！ count:\(audioFrameCount)")
                        lastlogTimeAudio = lastTimestamp.seconds

                        if !isStopping {
                            rebuildAudio()
                        }
                    }
                }


            }




            break


        @unknown default:

            // Handle other sample buffer types
            fatalError("Unknown type of sample buffer")

        }
    }

}
