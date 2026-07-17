with open(r'C:\Users\agp05\OneDrive\桌面\ReplyKit\ReplyKIT\VideoProcess.swift', 'r', encoding='utf-8') as f:
    raw = f.read()

c = raw.replace('\r\n', '\n')

# 1. Add videoTaskChain property after processingGeneration
c = c.replace(
    '    private var processingGeneration: UInt64 = 0',
    '    private var processingGeneration: UInt64 = 0\n    private let videoQueue = DispatchQueue(label: "com.replykit.video", qos: .userInitiated)\n    private weak var videoTaskChain: Task<Void, Never>?',
    1
)

# 2. Remove isProcessing variable (replaced by task chain)
c = c.replace('    private var isProcessing = false\n    private var processingStartedAt: Date?\n    private let processingTimeout: TimeInterval = 2.0\n    private var watchdogResetCount: Int = 0\n    private var consecutiveDropCount: Int = 0\n    private let maxConsecutiveDrops = 60\n    private var processingGeneration: UInt64 = 0',
    '    private var processingStartedAt: Date?\n    private let processingTimeout: TimeInterval = 2.0\n    private var watchdogResetCount: Int = 0\n    private var consecutiveDropCount: Int = 0\n    private let maxConsecutiveDrops = 60\n    private var processingGeneration: UInt64 = 0',
    1)

# 3. Remove isProcessing from the log line
c = c.replace('active:\(isActive) processing:\(isProcessing)',
    'active:\(isActive)')

# 4. Replace the watchdog that uses isProcessing
old_watchdog = '''        // Watchdog: \u63a2\u6e2c GPU \u65cb\u8f49\u904e\u6642\uff0c\u91cd\u7f6e\u6574\u500b\u7ba1\u7dda
        if isProcessing, let startedAt = processingStartedAt {
            if Date().timeIntervalSince(startedAt) > processingTimeout {
                isProcessing = false
                processingStartedAt = nil
                watchdogResetCount += 1
                resetProcessorActor(
                    reason: "[VideoProcessor] \u26a0\ufe0f #\(processedCount) GPU \u8655\u7406\u904e\u6642 (\(Int(processingTimeout))s)\uff0c\u91cd\u7f6e\u65cb\u8f49\u5668\u7ba1\u7dda (#\(watchdogResetCount))"
                )
            }
        }

        // \u9023\u7e8c\u904e\u6642\u91cd\u7f6e\u8d85\u904e\u4e0a\u9650\uff0c\u6a19\u8a18\u9700\u8981\u91cd\u5efa
        if watchdogResetCount > 3 {'''

new_watchdog = '''        // \u9023\u7e8c\u904e\u6642\u91cd\u7f6e\u8d85\u904e\u4e0a\u9650\uff0c\u6a19\u8a18\u9700\u8981\u91cd\u5efa
        if watchdogResetCount > 3 {'''

c = c.replace(old_watchdog, new_watchdog, 1)

# 5. Remove the old isProcessing guard + Task.detached block
old_task_block = '''        guard !isProcessing else { return }
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

new_task_block = '''        videoQueue.async { [weak self] in
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

if old_task_block in c:
    c = c.replace(old_task_block, new_task_block, 1)
    print('OK - task block replaced')
else:
    print('task block NOT FOUND')
    # Find where isProcessing guard appears
    idx = c.find('guard !isProcessing else { return }')
    if idx >= 0:
        print(f'Found isProcessing guard at {idx}')
        print(f'Context: ...{c[idx-30:idx+200]}...')
    else:
        print('isProcessing guard not found either')

with open(r'C:\Users\agp05\OneDrive\桌面\ReplyKit\ReplyKIT\VideoProcess.swift', 'w', encoding='utf-8') as f:
    f.write(c.replace('\n', '\r\n'))
print('saved')
