with open(r'C:\Users\agp05\OneDrive\桌面\ReplyKit\ReplyKIT\VP.tmp', 'r', encoding='utf-8') as f:
    raw = f.read()

c = raw.replace('\r\n', '\n')

old_props = '''    private let processingTimeout: TimeInterval = 5.0
    private var processingGeneration: UInt64 = 0'''

new_props = '''    private let processingTimeout: TimeInterval = 5.0
    private var processingGeneration: UInt64 = 0
    private let videoQueue = DispatchQueue(label: "com.replykit.video", qos: .userInitiated)
    private weak var videoTaskChain: Task<Void, Never>?'''

c = c.replace(old_props, new_props, 1)

old_task = '''        guard !isProcessing else { return }
        isProcessing = true
        processingStartedAt = Date()
        processingGeneration &+= 1
        let taskGeneration = processingGeneration

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                if self.processingGeneration == taskGeneration {
                    self.isProcessing = false
                    self.processingStartedAt = nil
                }
            }
            guard self.isActive else { return }

            guard let rotated = await actor.processFrame(
                imageBuffer: imageBuffer,
                originalTime: oringinaltime,
                angle: self.angle
            ) else {
                self.consecutiveDropCount += 1
                if self.consecutiveDropCount >= self.maxConsecutiveDrops {
                    self.isActive = false
                    sendlog("[VideoProcessor] \u2764\ufe0f \u9023\u7e8c \(self.consecutiveDropCount) \u5e40\u65cb\u8f49\u5931\u6557\uff0c\u6a19\u8a18\u91cd\u5efa")
                }
                return
            }

            self.watchdogResetCount = 0
            self.consecutiveDropCount = 0

            let duration: CMTime
            if oringinaltime.duration.isValid, oringinaltime.duration.seconds > 0 {
                duration = oringinaltime.duration
            } else {
                duration = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
            }
            var correctedTiming = CMSampleTimingInfo(
                duration: duration,
                presentationTimeStamp: pts,
                decodeTimeStamp: CMTime.invalid
            )
            var correctedBuffer: CMSampleBuffer?
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: rotated,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &correctedTiming,
                sampleBufferOut: &correctedBuffer
            )

            guard await self.mediaMixer.isRunning else {
                if enablePipeLog {
                    sendlog("[VideoProcessor] \u26a0\ufe0f #\(localCount) MediaMixer \u672a\u8fd0\u884c\uff0c\u8df3\u904e PTS:\(String(format:"%.3f",pts.seconds))s")
                }
                return
            }
            self.sentCount += 1
            if enablePipeLog, isFirstFrame || localCount % 300 == 0 {
                sendlog("[VideoProcessor] #\(localCount) \u9001\u51faMediaMixer PTS:\(String(format:"%.3f",pts.seconds))s")
            }
            if let cb = correctedBuffer {
                await self.mediaMixer.append(cb)
            } else {
                await self.mediaMixer.append(rotated)
            }
        }'''

new_task = '''        videoQueue.async { [weak self] in
            guard let self else { return }
            let prev = self.videoTaskChain
            self.videoTaskChain = Task(priority: .high) { [weak self] in
                _ = await prev?.value
                guard let self, self.isActive else { return }

                guard let rotated = await actor.processFrame(
                    imageBuffer: imageBuffer,
                    originalTime: oringinaltime,
                    angle: self.angle
                ) else {
                    self.consecutiveDropCount += 1
                    if self.consecutiveDropCount >= self.maxConsecutiveDrops {
                        self.isActive = false
                        sendlog("[VideoProcessor] \u2764\ufe0f \u9023\u7e8c \(self.consecutiveDropCount) \u5e40\u65cb\u8f49\u5931\u6557\uff0c\u6a19\u8a18\u91cd\u5efa")
                    }
                    return
                }

                self.watchdogResetCount = 0
                self.consecutiveDropCount = 0

                let duration: CMTime
                if oringinaltime.duration.isValid, oringinaltime.duration.seconds > 0 {
                    duration = oringinaltime.duration
                } else {
                    duration = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
                }
                var correctedTiming = CMSampleTimingInfo(
                    duration: duration,
                    presentationTimeStamp: pts,
                    decodeTimeStamp: CMTime.invalid
                )
                var correctedBuffer: CMSampleBuffer?
                CMSampleBufferCreateCopyWithNewTiming(
                    allocator: kCFAllocatorDefault,
                    sampleBuffer: rotated,
                    sampleTimingEntryCount: 1,
                    sampleTimingArray: &correctedTiming,
                    sampleBufferOut: &correctedBuffer
                )

                guard await self.mediaMixer.isRunning else {
                    if enablePipeLog {
                        sendlog("[VideoProcessor] \u26a0\ufe0f #\(localCount) MediaMixer \u672a\u8fd0\u884c\uff0c\u8df3\u904e PTS:\(String(format:"%.3f",pts.seconds))s")
                    }
                    return
                }
                self.sentCount += 1
                if enablePipeLog, isFirstFrame || localCount % 300 == 0 {
                    sendlog("[VideoProcessor] #\(localCount) \u9001\u51faMediaMixer PTS:\(String(format:"%.3f",pts.seconds))s")
                }
                if let cb = correctedBuffer {
                    await self.mediaMixer.append(cb)
                } else {
                    await self.mediaMixer.append(rotated)
                }
            }
        }'''

if old_task in c:
    c = c.replace(old_task, new_task, 1)
    print('OK - task replaced')
else:
    print('NOT FOUND')

with open(r'C:\Users\agp05\OneDrive\桌面\ReplyKit\ReplyKIT\VP.tmp', 'w', encoding='utf-8', newline='\r\n') as f:
    f.write(c)
