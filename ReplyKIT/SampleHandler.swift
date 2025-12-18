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
    static let group = UserDefaults(suiteName: "group.nuclear.liveAPP")
}


@available(iOS 10.0, *)
class SampleHandler: RPBroadcastSampleHandler , @unchecked Sendable{

   
    var DWidth = 1920
    var DHeight = 1334

    var rtmpURL:String?
    var rtmpKey:String?

    let h264level = RPConfig.shared.h264level

    var audioProcessor: AudioProcessor?
    var videoProcessor: VideoFrameProcessor?

    var streamStataus:MyStreamBitRateStrategy?

    var volumeCheckTimer: Timer?

    var volumeNotifier : VolumeNotifier?

    var isVideoRotationEnabled = true



    

#if os(iOS)
    private var currentOrientation: UIDeviceOrientation = .portrait
    private var nowOrientation: UIDeviceOrientation = .landscapeLeft

#else
    private var currentOrientation: Int = 0
    private var nowOrientation:Int = 0

#endif


    // MARK: 用戶設置輸出寬高
    var ADWidth : Int
    var ADHeight : Int

    private var lastVideoOrientation: AVCaptureVideoOrientation?

    var base:Int = 100_000
    var multiplier:Int = 39
    // 100_000 * 30 = 3_000_000 bps
    var bitrate:Int? {

        didSet {
            Task{

                guard let streamStataus = streamStataus else {
                    sendlog(message: "⚠️ streamStataus 尚未初始化，無法更新 BitRate")
                    return
                }
                let VSet=await streamStataus.mamimumVideoBitRate

                sendlog(message: "Old BitRate:\(VSet)")


                guard let bit = bitrate else { return }

                await streamStataus.updateVideoBitRate(to: bit)

                sendlog(message: "New BitRate:\(VSet)")
            }
        }
    }






    // MARK: 全局 MediaMixer
    let mediaMixer:MediaMixer = MediaMixer(captureSessionMode: .manual, multiTrackAudioMixingEnabled: true)



    private var lastVideoTimestamp: CMTime = .zero





    private var onAudioPage :Bool?
    //
    private var needVideoConfiguration = true
    private var needAudioConfiguration = true

    private var isSessionReady = false
    private var appVolume: Float = 1.0
    private var micVolume: Float = 1.0
    private var appAddVolume: Float = 1.0
    private var micAddVolume: Float = 1.0

    private var rtmpConnection = RTMPConnection()


    private var rtmpStream : RTMPStream!


    private var lastConfiguredSize: CGSize? = nil



    private func reloadVolumes(type:Int = -1,volume:Float = 1.0) {
        //sendlog(message:"app audio \(appVolume)\(micVolume)")

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

            appVolume = Float(RPConfig.shared.AppVolume)
            micVolume = Float(RPConfig.shared.MicVolume)

            sendlog(message:"app mic audio update \(appVolume) \(micVolume)")

            Task {
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

            let newVolume = SharedDefaults.group?.double(forKey: "micAddVolume") ?? 1.0


            micAddVolume=Float(newVolume)
            guard let audioProcessor else { return }

            Task {
                audioProcessor.updateVolumes(micAdd: micAddVolume)
            }
            sendlog(message: String(
                format: "麥克風音量放大: %.5f%%",
                newVolume
            ))
        case "appAdd":

            let newVolume = SharedDefaults.group?.double(forKey: "appAddVolume") ?? 1.0
            appAddVolume=Float(newVolume)
            guard let audioProcessor else { return }
            Task {
                audioProcessor.updateVolumes(appAdd: appAddVolume)
            }
            sendlog(message: String(
                format: "App音量放大: %.5f%%",
                newVolume
            ))


        case "micVolumeChanged":
            
            let newVolume = SharedDefaults.group?.double(forKey: "micVolume") ?? 1.0
            micVolume=Float(newVolume)

            guard let audioProcessor else { return }
            Task {
                audioProcessor.updateVolumes(mic: micVolume)
            }
            sendlog(message: String(
                format: "麥克風音量更新: %.2f%% (原始值: %.5f)",
                volumeToPercentage(newVolume),
                newVolume
            ))
            Task { await updateMicAudioVolume(Float(newVolume)) }

        case "appVolumeChanged":
            let newVolume = SharedDefaults.group?.double(forKey: "appVolume") ?? 1.0




            guard let audioProcessor else { return }
            Task {
                if let av = await SocketClient.shared.requestSet(for: "appVolume", type: "Double") {

                    sendlog(message: "原始AppVolume數據包:\(av)")

                }

                appVolume=Float(newVolume)

                audioProcessor.updateVolumes(app: appVolume)
            }

            sendlog(message: String(
                format: "!!應用音量更新: %.2f%% (原始值: %.5f)",
                volumeToPercentage(newVolume),
                newVolume
            ))

            Task { await updateAppAudioVolume(Float(newVolume)) }
            
        case "orientationChanged":
#if os(iOS)
            let orientationValue = SharedDefaults.group?.integer(
                forKey: "Orientation"
            ) ?? 0


            if let orientation = UIDeviceOrientation(rawValue: orientationValue) {

                sendlog(message: "OO:\(orientationValue) \(orientation)")
//                Task {
//                    configureOrientation()
//                }
            }



#else
            print("No Make tihs!")

#endif

        case "SocketRetry":
            SocketClient.shared.retry()
            sendlog(message: "重連Socket!")

       

        case "DebugRotate":
            let Rlog=SharedDefaults.group?.bool(forKey: "EnableRotatelog") ?? false
            videoProcessor?.rotator?.debug = Rlog
            sendlog(message:"[旋轉日誌變化] VideoRotate \(Rlog)")

        case "ChangeBit":
            let Rlog=SharedDefaults.group?.bool(forKey: "ChangeBit") ?? false
            Task {
                await streamStataus?.isChangBit(Rlog)
            }
            sendlog(message:"[網路]碼率控制: \(Rlog)")



        case "useBic":
            let Rlog=SharedDefaults.group?.bool(forKey: "useBic") ?? true
            videoProcessor?.rotator?.useBic = Rlog
            sendlog(message:"[GPU 使用Bic處理] \(Rlog)")


        case "bitRateChange":
            sendlog(message: "NewBit: \(String(describing: bitrate))")

            bitrate=SharedDefaults.group?.integer(forKey: "bitRate") ?? 3_900_000


        case "logURL":
            let logM=SharedDefaults.group?.string(
                forKey: "logURL"
            ) ?? "http://192.168.0.242/post"
            RPConfig.shared.logURL = logM
            sendlog(message: "LOG URL: \(logM)")


        case "logMode":
            let logM=SharedDefaults.group?.integer(forKey: "logMode") ?? 0
            sendlog(message: "LOG Mode \(logM)")
            if logM == 0 {
                LogManager.shared.forceFlush()
            }
            RPConfig.shared.logMode=logM
            RPConfig.shared.applyLogMode()


        case "onlogPage":
            let logPage=SharedDefaults.group?.bool(forKey: "onlogPage") ?? false

            RPConfig.shared.onLogPage=logPage
            if logPage {

                LogManager.shared.forceFlush()
                LogManager.shared.setupFlushTimer()



                sendlog(message: "正在LOG NTime:\(LogManager.shared.notifyThrottle)")

            } else {
                LogManager.shared.forceFlush()

                sendlog(message: "非LOG NTime:\(LogManager.shared.notifyThrottle)")
            }

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

        case "OutW":
            let dstRW=SharedDefaults.group?.integer(forKey: "dstW") ?? 0

            ADWidth = dstRW
            videoProcessor?.rotator?.dstWW = dstRW
            sendlog(message: "OutW:\(dstRW)")


        case "OutH":
            let dstRH=SharedDefaults.group?.integer(forKey: "dstH") ?? 0
            ADHeight = dstRH
            videoProcessor?.rotator?.dstHH = dstRH

            sendlog(message: "OutW:\(dstRH)")




        case "Enablelog":
            let Enablelog=SharedDefaults.group?.bool(forKey: "Enablelog") ?? false

            sendlog(message: "開關日誌log")
            RPConfig.shared.enableLog=Enablelog

            


        case "onAudioPage":
            onAudioPage=SharedDefaults.group?.bool(forKey: "onAudioPage") ?? false



                if audioProcessor != nil {

                    audioProcessor?.updatePage(status: onAudioPage)
                    sendlog(
                        message:"[Audio] Page \(String(describing: onAudioPage))"
                    )

                }
                
                else {
                    let onPause=SharedDefaults.group?.bool(
                        forKey: "PauseStream"
                    ) ?? false

                    if onPause {
                        sendlog(message: "正在暫停 取消重建Audio")
                        return
                    }

                    sendlog(message:"[Audio] audioProcessor is nil Rebuild AudioProcessor!")


                    guard let volumeNotifier = volumeNotifier else {
                        sendlog(message: "volumeNotifier沒有建立！")
                        return
                    }

                    audioProcessor = AudioProcessor(
                        mediaMixer: mediaMixer,
                        volumeNotifier: volumeNotifier,
                        appAddVolume: appAddVolume,
                        micAddVolume: micAddVolume,
                        appVolume: appVolume,
                        micVolume: micVolume,
                        onAudioPage: onAudioPage ?? false
                    )
                
                    // 假設 AudioProcessor 有無參數的初始化方法
                        audioProcessor?.updatePage(status: onAudioPage)


                }



            sendlog(message: "AudioPage:\(String(describing: onAudioPage))")


        case "PauseStream":
            self.broadcastPaused()
            sendlog(message: "你暫停直播畫面！")
        case "ResumeStream":
            self.broadcastResumed()
            sendlog(message: "你恢復了直播畫面！")


            
        default:
            break
        }
    }



    // MARK: 初始化
    override init() {

        rtmpStream = RTMPStream(connection: rtmpConnection)
        
        ADWidth = RPConfig.shared.ADWidth
        ADHeight = RPConfig.shared.ADHeight

        super.init()


        registerObservers()
        logger.info("ReplyKit Debug")

    }







    func updateAppAudioVolume(_ volume: Float) async {
        var settings = await mediaMixer.audioMixerSettings
        if var track = settings.tracks[0] {   // 0 是 app 音頻 track
            track.volume = volume            // volume 值 0.0 ~ 1.0
            settings.tracks[0] = track
        }
        await mediaMixer.setAudioMixerSettings(settings)
    }

    func updateMicAudioVolume(_ volume: Float) async {
        var settings = await mediaMixer.audioMixerSettings
        if var track = settings.tracks[1] {   // 1 是麥克風 track
            track.volume = volume
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

        var videoSettings = await rtmpStream.videoSettings
        var size = videoSettings.videoSize


        let newSize:CGSize

        if ADWidth > 0 && ADHeight > 0 {
            sendlog(message: "用戶設定寬高：\(ADWidth) x \(ADHeight)")
            size.width = CGFloat(ADHeight)
            size.height = CGFloat(ADWidth)
        }

        switch avOrientation {
        case .portrait, .portraitUpsideDown:
            newSize = CGSize(width: size.height, height: size.width)
            sendlog(message: "直向:\(size) → \(videoSettings)")

        default:
            newSize = CGSize(width: size.height, height: size.width)
            sendlog(message: "橫向:\(size) → \(videoSettings)")


            break;
        }

        // 如果上次已經設過這個 avOrientation，就不用再設
        guard avOrientation != lastVideoOrientation || videoSettings.videoSize != newSize else { return }
        lastVideoOrientation = avOrientation




        videoSettings.videoSize = newSize
        try? await rtmpStream.setVideoSettings(videoSettings)


        await mediaMixer.setVideoOrientation(avOrientation)
        sendlog(message: "更新方向: \(orientation) -> \(avOrientation)")
        sendlog(message: "Size:\(newSize) - \(videoSettings)")
    }

#endif





    func configureOrientation() {
        let manager = DeviceOrientationManager.shared   // 使用單例
        let lockedValue = SharedDefaults.group?.bool(forKey: "LockIN") ?? false
        if  lockedValue {
            sendlog(message:"\(lockedValue)不偵測 初始化一次")
            manager.isEnabled = false
            manager.stopUpdates()
        } else {
            // 解鎖方向 → 啟動 Motion 偵測
            manager.isEnabled = true
            sendlog(message:"偵測開啟")
            manager.startUpdates()
            manager.orientationChanged = { [weak self] deviceOrientation in

                sendlog(message: "方向Free中")
                #if os(iOS)
                guard let self else { return }
                Task.detached(priority: .utility) {

                    await self.updateVideoOrientation(from: deviceOrientation)
                }
                #endif

            }
        }
    }

    var isStopping = false

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
        disconnectMonitorTask = Task.detached { [weak self, weak streamStataus] in
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


        isVideoRotationEnabled = SharedDefaults.group?.bool(forKey: "VideoRotate") ?? false


        // MARK: Video dimensions
        ADWidth = RPConfig.shared.ADWidth
        ADHeight = RPConfig.shared.ADHeight

        if ADWidth > 0 && ADHeight > 0 {
            DWidth = ADWidth
            DHeight = ADHeight
        }

        onAudioPage = RPConfig.shared.onAudioPage


        // MARK: Volume
        let newMicAddVolume = RPConfig.shared.MicVolumeAdd

        let newAppAddVolume = RPConfig.shared.AppVolumeAdd

        micAddVolume=Float(newMicAddVolume)
        appAddVolume=Float(newAppAddVolume)



        let safelogKey = fixlogSafeKey(streamKey)
        // 組成完整 RTMP URL
        let fullURLString = "\(urlString)/\(safelogKey)"


        // MARK: 是否在日誌Log mode
        RPConfig.shared.logMode = SharedDefaults.group?
            .integer(forKey: "logMode") ?? 0
        RPConfig.shared.onLogPage = SharedDefaults.group?.bool(forKey: "onlogPage") ?? false


        RPConfig.shared.applyLogMode()

        // 🔹 轉成 URL
        sendlog(message: "🔹 推流 URL:\(fullURLString)")
        sendlog(message: "App:\(appVolume)  Mic:\(micVolume) AppAdd:\(appAddVolume) MicAdd:\(micAddVolume)")


    }


    func configureVideo() async {
        // Video settings

        var DW = 1334
        var DH = 1920
        if ADWidth > 0 && ADHeight > 0 {
            sendlog(message: "[CV]用戶設定寬高：\(ADWidth) x \(ADHeight)")
            DW = ADHeight
            DH = ADWidth
        }

        var videoSettings = await rtmpStream.videoSettings
        videoSettings.scalingMode = .letterbox
        videoSettings.profileLevel = kVTProfileLevel_H264_High_AutoLevel as String
        videoSettings.videoSize = .init(width: DW, height: DH)
        videoSettings.maxKeyFrameIntervalDuration = 2
        videoSettings.expectedFrameRate = 60.0


        try? await rtmpStream.setVideoSettings(videoSettings)

        // Video mixer passthrough
        var videoMixerSettings = await mediaMixer.videoMixerSettings
        videoMixerSettings.mode = .passthrough

        let track = videoMixerSettings.mainTrack

        sendlog(message:"VTrack:\(track)")


        do {
            try await mediaMixer.setFrameRate(60.0)
            let fps = await mediaMixer.frameRate
            sendlog(message: "FPS OK: \(fps)")


        } catch {
            sendlog(message: "FPS Error:\(error)")
        }

        
        await mediaMixer.setVideoMixerSettings(videoMixerSettings)

        let BCount = RPConfig.shared.BufferCount
        // ReplayKit is sensitive to memory, so we limit the queue to a maximum of five items.
        await rtmpStream.setVideoInputBufferCounts(BCount)

        sendlog(message: "Video Buffer -> \(BCount)")


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

        streamStataus = MyStreamBitRateStrategy()

        await streamStataus?.refreshStatusTimestamp()

        await streamStataus?.setOnDisconnect { [weak self] in
            self?.stopBroadcastWithError("RTMP 斷線")
        }


        let Rlog=RPConfig.shared.ChangeBit
        
        await streamStataus?.isChangBit(Rlog)


        await rtmpStream.setBitRateStrategy(streamStataus)

        await mediaMixer.addOutput(rtmpStream)
        await mediaMixer.startRunning()


        didConfigureVideo = false
        didConfigureAudio = false

        configureOrientation()


        // if DeviceOrientationManager.shared.isEnabled {


        //        #if os(iOS)
        //
        //        let videofrom = await UIDevice.current.orientation
        //        await updateVideoOrientation(from: videofrom)
        //
        //        #endif

        //}


    }


   // MARK: Process

    func initProcessors() async {


        bitrate = RPConfig.shared.BitRate


        volumeNotifier = VolumeNotifier()


            videoProcessor = VideoFrameProcessor(
                mediaMixer: mediaMixer,
                rtmpStream: rtmpStream,
                sendlog: { message in
                    sendlog(message: message)
                }
            )


            audioProcessor = AudioProcessor(
                mediaMixer: mediaMixer,
                volumeNotifier: volumeNotifier!,
                appAddVolume: appAddVolume,
                micAddVolume: micAddVolume,
                appVolume: appVolume,
                micVolume: micVolume,
                onAudioPage: onAudioPage ?? false
            )




    }


    func startRTMP(url:String?,key:String?) async {

        do {

            guard let url = url ,let key = key else {
                stopBroadcastWithError("RTMP配置取得異常!")
                return
            }
            // step 3: 連線 RTMP

            _ = try await rtmpConnection.connect(url)

            _ = try await rtmpStream.publish(key)

            // step 4: 標記 session ready
            await MainActor.run {
                // Add output
                self.isSessionReady = true
                logger.info("🎉 RTMP 推流成功")


            }

        }  catch RTMPConnection.Error.requestFailed(let response) {
            self.stopBroadcastWithError("RTMP 服務器連線失敗 \(response)")

        }  catch RTMPStream.Error.requestFailed(let response) {
            self.stopBroadcastWithError("RTMP 推流失敗 \(response)")

        } catch {
        self.stopBroadcastWithError("RTMP 其他錯誤 \(error)")

    }


    }


    enum TimeoutError: Error {
        case timedOut
    }

    func withTimeout<T>(_ seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError.timedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: 直播開始
    override func broadcastStarted(
        withSetupInfo setupInfo: [String : NSObject]?
    ) {
        // User has requested to start the broadcast. Setup info from the UI extension can be suppdlied but optional.

        logger.info("運行通知")

        isStopping = false


        //self.prepareCompressionSession()


        Task {

            do {
                try await withTimeout(3) {
                    ExtensionMessagePort.shared.connectToApp()
                }
                logger.debug("連線成功或至少嘗試完成")
            } catch TimeoutError.timedOut {
                logger.debug("連線主 App 超時")
            } catch {
                logger.debug("其他錯誤:\(error)")
            }


            do {
                // 同時發出兩個請求
                async let rtmpSuccess = withTimeout(5) {
                    await SocketClient.shared.requestRTMPKEY()
                }
                async let logSuccess = withTimeout(5) {
                    await SocketClient.shared.requestLogConfig()
                }
                // 等待兩個結果
                let (r, l) = try await (rtmpSuccess, logSuccess)

                if r { sendlog(message:"RTMP 已完成同步") }
                if l { sendlog(message:"LogConfig 已完成同步") }

            } catch TimeoutError.timedOut {
                sendlog(message: "超時！AppGroup有效時不影響")
            } catch {
                sendlog(message: "請求失敗! \(error)")
            }

                // 🔹 從 UserDefaults 拿 RTMP 設定
                rtmpURL = RPConfig.shared.RTMPURL
                rtmpKey = RPConfig.shared.RTMPKey


                self.setUserDefalutConfig(
                    urlString: self.rtmpURL ?? "rtmp://192.168.0.242/live",
                    streamKey: self.rtmpKey ?? "test"
                )

                logger.debug("✅ RTMP設定: \(String(describing: self.rtmpURL)) \(String(describing: self.rtmpKey))")


                await self.configureVideo()
                await self.configureAudio()
                await self.configureMediaMixer()

                logger.info("✅ MediaMixer 配置完成")

                await self.initProcessors()

                logger.info("✅ Processor 初始化完成")


                await self.startRTMP(url: self.rtmpURL , key: self.rtmpKey)
            }



    }


    // MARK: - 暫停畫面控制
    private var pauseTimer: DispatchSourceTimer?

    // MARK: 重用暫停
    private var pausedNV12PixelBuffer: CVPixelBuffer?
    private var pausedBGRAcontext: CGContext?
    private var pausedBGRABuffer: CVPixelBuffer?

    var isPause = false


    private let stateQueue = DispatchQueue(label: "broadcast.state.queue")

    private var pausedFrameTimestamp: CMTime = .zero
    private let pausedFrameDuration = CMTimeMake(value: 1, timescale: 1) // 每秒一幀

    private var pausedStartTime = CACurrentMediaTime()
    private var pausedFrameIndex: Int = 0

    // MARK: - 暫停畫面邏輯
    private func startPausedFrameLoop() {
        let width = DWidth
        let height = DHeight

        // 直接建立暫停畫面資源
        if pausedBGRABuffer == nil {
            pausedBGRABuffer = createPixelBuffer(width: width, height: height,
                                                 format: kCVPixelFormatType_32BGRA, reuse: nil)
            if let bgra = pausedBGRABuffer {
                pausedBGRAcontext = createContext(for: bgra)
                if let ctx = pausedBGRAcontext {
                    updatePausedContext(buffer: bgra, context: ctx, text: "直播暫停中")
                    sendlog(message: "✅ 暫停畫面 BGRA buffer 建立成功")
                }
            }
        }

        if pausedNV12PixelBuffer == nil {
            pausedNV12PixelBuffer = createPixelBuffer(width: width, height: height,
                                                      format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, reuse: nil)
        }

        // 啟動定時器推幀
        pauseTimer?.cancel()
        pauseTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        pauseTimer?.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        pauseTimer?.setEventHandler { [weak self] in
            guard let self = self,
                  let bgra = self.pausedBGRABuffer,
                  let nv12 = self.pausedNV12PixelBuffer else { return }

            convertBGRAtoNV12(bgra: bgra, nv12: nv12)

            var frameIndex = 0
            self.stateQueue.sync { frameIndex = self.pausedFrameIndex }

            if let sampleBuffer = createSampleBuffer(from: nv12, frameIndex: &frameIndex) {
                self.stateQueue.sync { self.pausedFrameIndex = frameIndex }
                Task { await self.mediaMixer.append(sampleBuffer) }
            }
        }
        pauseTimer?.resume()
    }

    private var isRebuilding = false
    private var isCleanup = false


    // MARK: 直播暫停
    override func broadcastPaused() {

        guard !isCleanup else {
            sendlog(message: "⚠️ 正在重建中，忽略重複 Resume")
            return
        }
        isCleanup = true
        defer { isCleanup = false }


        stateQueue.sync {
            guard !isPause else {
                sendlog(message: "⚠️ 已處於暫停狀態（防重複觸發）")
                return
            }
            isPause = true
            pausedFrameIndex = 0
            pausedStartTime = CACurrentMediaTime()
            pausedFrameTimestamp = .zero
            sendlog(title: "SampleHandler", message: "⚠️ Broadcast paused - sending paused frame repeatedly")
        }

        // 停止 Audio / Video 處理
        audioProcessor?.cleanup()


        videoProcessor?.cleanup()


        audioProcessor = nil
        videoProcessor = nil

        // MARK: === 建立暫停畫面資源 ===
        // 呼叫專門處理暫停畫面邏輯
        startPausedFrameLoop()


    }

    // MARK: 直播恢復
    override func broadcastResumed() {
        guard !isRebuilding else {
            sendlog(message: "⚠️ 正在重建中，忽略重複 Resume")
            return
        }
        isRebuilding = true
        defer { isRebuilding = false }


        stateQueue.sync {
            guard isPause else {
                sendlog(message: "⚠️ 非暫停狀態，忽略恢復操作（防重複觸發）")
                return
            }
            isPause = false
        }


        sendlog(title: "SampleHandler", message: "🎬 Broadcast resumed - stopping paused frame timer")

        // 停止暫停畫面定時器
        if let timer = pauseTimer {
            timer.cancel()
            pauseTimer = nil
            sendlog(message: "🛑 已停止暫停畫面定時器")
        }

        // 清理暫停畫面資源
        pausedBGRABuffer = nil
        pausedBGRAcontext = nil
        pausedNV12PixelBuffer = nil

        // 重建或啟用音量監聽器
        if volumeNotifier == nil {
            volumeNotifier = VolumeNotifier()
            sendlog(message: "🔊 VolumeNotifier 重新建立")
        }

        // MARK: 重建 VideoProcessor
        if videoProcessor == nil {


            videoProcessor = VideoFrameProcessor(
                mediaMixer: mediaMixer,
                rtmpStream: rtmpStream,
                sendlog: { message in
                    sendlog(message: message)
                }
            )
            sendlog(message: "🎥 VideoProcessor 重建完成")
        }

        // MARK: 重建 AudioProcessor
        if audioProcessor == nil {
            audioProcessor = AudioProcessor(
                mediaMixer: mediaMixer,
                volumeNotifier: volumeNotifier!,
                appAddVolume: appAddVolume,
                micAddVolume: micAddVolume,
                appVolume: appVolume,
                micVolume: micVolume,
                onAudioPage: onAudioPage ?? false
            )
            sendlog(message: "🎧 AudioProcessor 重建完成")
        }

        // 重新啟用音視頻處理
        videoProcessor?.isActive = true
        audioProcessor?.isActive = true
        sendlog(message: "✅ 已重新啟用音視頻處理")
    }

    
    // MARK: 直播結束處理
    func broadcastEnd(message:String = "正常結束")  {
        // User has requested to finish the broadcast.

        // 停止斷線監控 Task
        disconnectMonitorTask?.cancel()
        disconnectMonitorTask = nil

        ExtensionMessagePort.shared.disconnectFromApp()
        SocketClient.shared.closeConnection()



        needVideoConfiguration = true
        needAudioConfiguration = true


        removeObservers()

        isStopping = true
        isSessionReady = false


        Task {
#if os(iOS)
            await UIDevice.current.endGeneratingDeviceOrientationNotifications()

            NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)

#endif
        }

        
        DeviceOrientationManager.shared.stopUpdates()

        volumeNotifier?.cleanup()


        videoProcessor?.cleanup()


        audioProcessor?.cleanup()

        volumeNotifier=nil
        videoProcessor=nil
        audioProcessor=nil


        Task {

            await mediaMixer.removeOutput(rtmpStream)
            await mediaMixer.stopRunning()


            _ = try? await rtmpStream.close()
            _ = try? await rtmpConnection.close()
        }


        sendlog(message:"[RTMP] \(message)")
        LogManager.shared.forceFlush()


    }


    override func broadcastFinished() {


        broadcastEnd()

    }





    // MARK: 內部已配置處理
    private var didConfigureVideo = true
    private var didConfigureAudio = true

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

        // 如果已經初始化過，就不再重做
        if didConfigureVideo { return }
        didConfigureVideo = true  // 打上標記



        guard let formatDesc = sampleBuffer.formatDescription else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)

        guard dims.width > 0 && dims.height > 0 else { return }

        var width = Int(dims.width)
        var height = Int(dims.height)

        if ADWidth > 0 && ADHeight > 0 {
            sendlog(message: "用戶設定寬高：\(ADWidth) x \(ADHeight)")
            width = ADHeight
            height = ADWidth
        }


       
        if let orientationValue = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber {
            sendlog(message: "ReplayKit 當前畫面方向: \(orientationValue)")
        }

        let avfrom = lastVideoOrientation
        let newSize: CGSize

        switch avfrom {
        case .portrait, .portraitUpsideDown:
            newSize = CGSize(width: CGFloat(width), height: CGFloat(height))
            sendlog(message: "初始更新直向")
            await mediaMixer.setVideoOrientation(.portrait)
        default:
            newSize = CGSize(width: CGFloat(height), height: CGFloat(width))
            sendlog(message: "初始更新橫向")
            await mediaMixer.setVideoOrientation(.landscapeRight)
            let bb = await mediaMixer.videoOrientation
            let b2 = await mediaMixer.videoInputFormats
            sendlog(message: "\(bb).\(b2)")
        }

        var videoSettings = await rtmpStream.videoSettings
        videoSettings.videoSize = newSize
        videoSettings.expectedFrameRate = 60.0


        let profilelvl: String

        switch h264level {
        case "Baseline":
            let res = h264ProfileLevel(
                forWidth: width,
                height: height,
                fps: 60,
                profile: .baseline
            )

            profilelvl = res

        case "Main":
            let res = h264ProfileLevel(
                forWidth: width,
                height: height,
                fps: 60,
                profile: .main
            )

            profilelvl = res

        case "High":
            let res = h264ProfileLevel(
                forWidth: width,
                height: height,
                fps: 60,
                profile: .high
            )

            profilelvl = res

        case "AutoBaseline":
            profilelvl = kVTProfileLevel_H264_Baseline_AutoLevel as String
        case "AutoMain":
            profilelvl = kVTProfileLevel_H264_Main_AutoLevel as String
        case "AutoHigh":
            profilelvl = kVTProfileLevel_H264_High_AutoLevel as String

        case "ConstrainedBaseline":
            profilelvl = kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel as String
        case "ConstrainedHigh":
            profilelvl = kVTProfileLevel_H264_ConstrainedHigh_AutoLevel as String
        case "Extended":
            profilelvl = kVTProfileLevel_H264_Extended_AutoLevel as String

        default:
            profilelvl = kVTProfileLevel_H264_Main_AutoLevel as String
        }

        sendlog(message: "H264Profilelevel: \(profilelvl)")

        videoSettings.profileLevel = profilelvl
        videoSettings.maxKeyFrameIntervalDuration = 2

        if lastConfiguredSize != newSize {
            try? await rtmpStream.setVideoSettings(videoSettings)
        }




        lastConfiguredSize = newSize
        DWidth = Int(newSize.width)
        DHeight = Int(newSize.height)

        sendlog(message: "有效更新: \(newSize)")
        sendlog(message: "Video: \(videoSettings)")
        sendlog(message: "Video 拿到畫面 \(width)x\(height)")
    }

    var lastlogTime : Double = 0.0
    var lastlogTimeAudio : Double = 0.0
    var logInterval : CFTimeInterval = 1.0

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {

//        guard isSessionReady else { return }

        switch sampleBufferType {
        case RPSampleBufferType.video:

            if needVideoConfiguration && !didConfigureVideo {
                needVideoConfiguration = false

                Task { [weak self] in
                        guard let self else { return }
                        await self.configureVideo(sampleBuffer)
                    }


                // ✅ 初始化時才抓一次方向
#if os(iOS)
                if DeviceOrientationManager.shared.isEnabled {

                        let orientation = UIDevice.current.orientation
                        self.nowOrientation = orientation

                }
#endif

            }

            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            lastVideoTimestamp = timestamp



            if videoProcessor != nil {
                videoProcessor?.process(sampleBuffer, timestamp: timestamp)
            } else {
                if lastVideoTimestamp.seconds > lastlogTime + logInterval  {
                    sendlog(message: "Video進程不存在！")
                    lastlogTime = lastVideoTimestamp.seconds
                }
            }



            break



        case RPSampleBufferType.audioApp, RPSampleBufferType.audioMic:
            if sampleBuffer.dataReadiness == .ready {
                let trackType: AudioTrackType = (sampleBufferType == .audioApp) ? .app : .mic

                if needAudioConfiguration  && !didConfigureAudio {
                    didConfigureAudio = true
                    needAudioConfiguration = false

                    let BitAudio=pcmBitrate(from: sampleBuffer)
                    let HHZ=BitAudio["HZ"] as? Int ?? 0
                    let CHH=BitAudio["Channel"] as? Int ?? 0
                    let BitR=BitAudio["BitRate"] as? Int ?? 0

                    // 格式化字串
                    let logMessage = String(format: "SampleRate: %.0f Hz | Channels: %.0f | BitRate: %.1f kbps | BitO: %f",
                                            HHZ,
                                            CHH,
                                            BitR / 1000,
                                            BitR)

                    if let streamStatus = streamStataus {
                        Task {
                            await streamStatus.updateAudioBitRate(to: BitR)
                        }
                    }
                        sendlog(message: logMessage)

                }


                let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

                lastVideoTimestamp = timestamp

                if audioProcessor != nil {
                    audioProcessor?
                        .enqueue(sampleBuffer, trackType: trackType)
                } else {
                    if lastVideoTimestamp.seconds > lastlogTimeAudio + logInterval  {
                        sendlog(message: "Audio進程不存在！")
                        lastlogTimeAudio = lastVideoTimestamp.seconds
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
