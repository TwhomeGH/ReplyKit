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
var userDefaults = UserDefaults(suiteName: "group.nuclear.liveAPP")



@available(iOS 10.0, *)
class SampleHandler: RPBroadcastSampleHandler , @unchecked Sendable{

    //private var userDefaults: UserDefaults?

    var DWidth = 1920
    var DHeight = 1334

    var audioProcessor: AudioProcessor!
    var videoProcessor: VideoFrameProcessor!

    var streamStataus:MyStreamBitRateStrategy!

    var volumeCheckTimer: Timer?

    var volumeNotifier : VolumeNotifier?

    var isVideoRotationEnabled = true

    var rtmpURL:String?
    var rtmpKey:String?


    

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
    var bitrate:Int {

        didSet {
            Task{

                guard let streamStataus = streamStataus else {
                    sendlog(message: "⚠️ streamStataus 尚未初始化，無法更新 BitRate")
                    return
                }
                let VSet=await streamStataus.mamimumVideoBitRate

                sendlog(message: "Old BitRate:\(VSet)")



                await streamStataus.updateVideoBitRate(to: bitrate)

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

    var videoBufferManager: AdaptiveVideoBufferManager?

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
            appVolume = userDefaults?.float(forKey: "appVolume") ?? 1.0
            micVolume = userDefaults?.float(forKey: "micVolume") ?? 1.0
            sendlog(message:"app mic audio update \(appVolume) \(micVolume)")

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

    // MARK: 統一處理事件
    func handleEvent(eventName: String) {
        switch eventName {
        case "micAdd":

            let newVolume = userDefaults?.double(forKey: "micAddVoulme") ?? 1.0
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

            let newVolume = userDefaults?.double(forKey: "appAddVoulme") ?? 1.0
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
            
            let newVolume = userDefaults?.double(forKey: "micVolume") ?? 1.0
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
            let newVolume = userDefaults?.double(forKey: "appVolume") ?? 1.0
            appVolume=Float(newVolume)
            guard let audioProcessor else { return }
            Task {
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
            if let orientationValue = userDefaults?.integer(forKey: "Orientation"),


                let orientation = UIDeviceOrientation(rawValue: orientationValue) {

                sendlog(message: "OO:\(orientationValue) \(orientation)")
                Task {
                    configureOrientation()
                }


            }
#else
            print("No Make tihs!")

#endif

        case "videoRotateChanged":
            sendlog(message: "棄用方法！")
            break
            //isVideoRotationEnabled=userDefaults?.bool(forKey: "VideoRotate") ?? true

//            Task {
//                videoProcessor.updateRotator(status: rotator)
//            }
            //logger.info("AutoVideoRotate:\(self.isVideoRotationEnabled)")


        case "DebugRotate":
            let Rlog=userDefaults?.bool(forKey: "EnableRotatelog") ?? false
            videoProcessor.rotator?.debug = Rlog
            sendlog(message:"[旋轉日誌變化] VideoRotate \(Rlog)")


        case "useBic":
            let Rlog=userDefaults?.bool(forKey: "useBic") ?? true
            videoProcessor.rotator?.useBic = Rlog
            sendlog(message:"[GPU 使用Bic處理] \(Rlog)")


        case "bitRateChange":
            sendlog(message: "NewBit: \(bitrate)")

            bitrate=userDefaults?.integer(forKey: "bitRate") ?? 3_900_000


        case "logURL":
            let logM=userDefaults?.string(forKey: "logURL") ?? "http://192.168.0.242/post"
            RPConfig.shared.logURL = logM
            sendlog(message: "LOG URL: \(logM)")


        case "logMode":
            let logM=userDefaults?.integer(forKey: "logMode") ?? 0
            sendlog(message: "LOG Mode \(logM)")
            if logM == 0 {
                LogManager.shared.forceFlush()
            }
            RPConfig.shared.logMode=logM


        case "onlogPage":
            let logPage=userDefaults?.bool(forKey: "onlogPage") ?? false

            RPConfig.shared.onLogPage=logPage
            if logPage {

                videoBufferManager?.adjustInterval = 3.0
                LogManager.shared.flushInterval = 1.0

                // 先取消舊的 timer（如果存在）
                if let oldTimer = LogManager.shared.flushTimer {
                    oldTimer.cancel()
                    LogManager.shared.flushTimer = nil
                }

                LogManager.shared.setupFlushTimer()

                LogManager.shared.notifyThrottle = 1.0
                sendlog(message: "正在LOG NTime:\(LogManager.shared.notifyThrottle)")
            } else {

                videoBufferManager?.adjustInterval = 30.0

                // 先取消舊的 timer（如果存在）
                if let oldTimer = LogManager.shared.flushTimer {
                    oldTimer.cancel()
                    LogManager.shared.flushTimer = nil
                }


                LogManager.shared.flushInterval = 10.0
                LogManager.shared.setupFlushTimer()


                LogManager.shared.notifyThrottle = 20.0
                sendlog(message: "非LOG NTime:\(LogManager.shared.notifyThrottle)")
            }


        case "OutW":
            let dstRW=userDefaults?.integer(forKey: "dstW") ?? 0

            ADWidth = dstRW
            videoProcessor.rotator?.dstWW = dstRW
            sendlog(message: "OutW:\(dstRW)")


        case "OutH":
            let dstRH=userDefaults?.integer(forKey: "dstH") ?? 0
            ADHeight = dstRH
            videoProcessor.rotator?.dstHH = dstRH

            sendlog(message: "OutW:\(dstRH)")




        case "Enablelog":
            let Enablelog=userDefaults?.bool(forKey: "Enablelog") ?? false
            sendlog(message: "開關日誌log")
            RPConfig.shared.enableLog=Enablelog


        case "onAudioPage":
            onAudioPage=userDefaults?.bool(forKey: "onAudioPage") ?? false



                if audioProcessor != nil {

                    audioProcessor.updatePage(status: onAudioPage)
                    sendlog(
                        message:"[Audio] Page \(String(describing: onAudioPage))"
                    )

                }
                
                else {
                    let onPause=userDefaults?.bool(forKey: "PauseStream") ?? false

                    if onPause {
                        sendlog(message: "正在暫停 取消重建Audio")
                        return
                    }

                    sendlog(message:"[Audio] audioProcessor is nil Rebuild AudioProcessor!")
                    audioProcessor = AudioProcessor(
                        mediaMixer: mediaMixer,
                        volumeNotifier: volumeNotifier!,
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
            sendlog(message: "你灰復了直播畫面！")
            

            
        default:
            break
        }
    }

    deinit {

        //rtmpStream = nil

        removeObservers()
    }

    // MARK: 初始化
    override init() {


        bitrate=userDefaults?.integer(forKey: "bitRate") ?? 3_900_000

        rtmpStream = RTMPStream(connection: rtmpConnection)
        
        ADWidth = 0
        ADHeight = 0

        super.init()


        registerObservers()
        logger.info("ReplyKit Debug")


        // 初始讀取
        reloadVolumes()

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
        let lockedValue = userDefaults?.bool(forKey: "LockIN") ?? false
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
        isVideoRotationEnabled = userDefaults?.bool(forKey: "VideoRotate") ?? true

        if userDefaults?.object(forKey: "appVolume") == nil {
            userDefaults?.set(1.0, forKey: "appVolume")
        }
        if userDefaults?.object(forKey: "micVolume") == nil {
            userDefaults?.set(1.0, forKey: "micVolume")
        }

        // MARK: Video dimensions
        ADWidth = userDefaults?.integer(forKey: "dstW") ?? 0
        ADHeight = userDefaults?.integer(forKey: "dstH") ?? 0

        if ADWidth > 0 && ADHeight > 0 {
            DWidth = ADWidth
            DHeight = ADHeight
        }

        onAudioPage=userDefaults?.bool(forKey: "onAudioPage") ?? false


        //bitrate=userDefaults?.integer(forKey: "bitRate") ?? 3_900_000


        // MARK: Volume
        let newMicAddVolume = userDefaults?.double(forKey: "micAddVoulme") ?? 1.0
        let newAppAddVolume = userDefaults?.double(forKey: "appAddVoulme") ?? 1.0

        micAddVolume=Float(newMicAddVolume)
        appAddVolume=Float(newAppAddVolume)



        // 組成完整 RTMP URL
        let fullURLString = "\(urlString)/\(streamKey)"


        // MARK: 是否在日誌Log mode
        RPConfig.shared.logMode = userDefaults?.integer(forKey: "logMode") ?? 0
        RPConfig.shared.onLogPage = userDefaults?.bool(forKey: "onlogPage") ?? false


        // 🔹 轉成 URL
        sendlog(message: "🔹 推流 URL:\(fullURLString)")
        sendlog(message: "App:\(appVolume)  Mic:\(micVolume) AppAdd:\(appAddVolume) MicAdd:\(micAddVolume)")



        reloadVolumes()

    }


    func configureVideo() async {
        // Video settings
        var videoSettings = await rtmpStream.videoSettings
        videoSettings.scalingMode = .letterbox
        videoSettings.profileLevel = kVTProfileLevel_H264_High_AutoLevel as String
        videoSettings.videoSize = .init(width: 1334, height: 1920)
        videoSettings.maxKeyFrameIntervalDuration = 2
        try? await rtmpStream.setVideoSettings(videoSettings)

        // Video mixer passthrough
        var videoMixerSettings = await mediaMixer.videoMixerSettings
        videoMixerSettings.mode = .passthrough


        await mediaMixer.setVideoMixerSettings(videoMixerSettings)


        // ReplayKit is sensitive to memory, so we limit the queue to a maximum of five items.
        await rtmpStream.setVideoInputBufferCounts(5)


    }
    func configureAudio() async {
        // Audio settings
        var audioSettings = await mediaMixer.audioMixerSettings
        audioSettings.tracks[0] = .default
        audioSettings.tracks[1] = .default


        await mediaMixer.setAudioMixerSettings(audioSettings)



    }
    // MARK: Video Setting
    func configureMediaMixer() async {

        streamStataus = MyStreamBitRateStrategy()

        await streamStataus.refreshStatusTimestamp()

        await streamStataus.setOnDisconnect { [weak self] in
            self?.stopBroadcastWithError("RTMP 斷線")
        }

        await rtmpStream.setBitRateStrategy(streamStataus)


        await mediaMixer.addOutput(rtmpStream)
        await mediaMixer.startRunning()


        didConfigureVideo = false
        didConfigureAudio = false

        configureOrientation()


//        #if os(iOS)
//
//        let videofrom = await UIDevice.current.orientation
//        await updateVideoOrientation(from: videofrom)
//
//        #endif

    }


   // MARK: Process

    func initProcessors() async {
        videoBufferManager = AdaptiveVideoBufferManager()

        volumeNotifier = VolumeNotifier()


            videoProcessor = VideoFrameProcessor(
                mediaMixer: mediaMixer,
                videoBufferManager: videoBufferManager!,
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


    func startRTMP(url:String,key:String) async {

        do {

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



    // MARK: 直播開始
    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        // User has requested to start the broadcast. Setup info from the UI extension can be suppdlied but optional.

        logger.info("運行通知")

        isStopping = false


        // 🔹 從 UserDefaults 拿 RTMP 設定
        rtmpURL = userDefaults?.string(forKey: "rtmpURL") ?? "rtmp://192.168.0.102/live"
        rtmpKey = userDefaults?.string(forKey: "rtmpKey") ?? "stream1?vhost=live2"




//       let rtmpURL2 = "rtmp://192.168.0.106/live"
//       let rtmpKey2 = "e5c162ed9ae3?secret=BBA0A8FD817F4F75"
//


        //self.prepareCompressionSession()

        Task {
            setUserDefalutConfig(
                urlString: rtmpURL!,
                streamKey: rtmpKey!
            )

            logger.debug("✅ RTMP設定: \(String(describing: self.rtmpURL)) \(String(describing: self.rtmpKey))")


            await configureVideo()
            await configureAudio()
            await configureMediaMixer()

            logger.info("✅ MediaMixer 配置完成")

            await initProcessors()

            logger.info("✅ Processor 初始化完成")


            await startRTMP(url: rtmpURL! , key: rtmpKey!)
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
                videoBufferManager: videoBufferManager!,
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

        videoBufferManager = nil
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
    private var didConfigureVideo = false

    private var didConfigureAudio = false

    func configureVideo(_ sampleBuffer: CMSampleBuffer) async {

        // 如果已經初始化過，就不再重做
        if didConfigureVideo { return }
        didConfigureVideo = true  // 打上標記



        let h264level = userDefaults?.string(forKey: "h264level")

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

        let profilelvl: String
        switch h264level {
        case "Baseline": profilelvl = kVTProfileLevel_H264_Baseline_AutoLevel as String
        case "Main": profilelvl = kVTProfileLevel_H264_Main_AutoLevel as String
        case "High": profilelvl = kVTProfileLevel_H264_High_AutoLevel as String
        case "ConstrainedBaseline": profilelvl = kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel as String
        case "ConstrainedHigh": profilelvl = kVTProfileLevel_H264_ConstrainedHigh_AutoLevel as String
        case "Extended": profilelvl = kVTProfileLevel_H264_Extended_AutoLevel as String
        default: profilelvl = kVTProfileLevel_H264_Main_AutoLevel as String
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
                videoProcessor.process(sampleBuffer, timestamp: timestamp)
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
                    audioProcessor
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
