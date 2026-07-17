with open(r'C:\Users\agp05\OneDrive\桌面\ReplyKit\ReplyKIT\AudioProcess.swift', 'r', encoding='utf-8') as f:
    c = f.read()

old1 = '''    private var enqueueCount: Int = 0
    private var lastEnqueueLog: CFTimeInterval = 0
    private var _isEnqueuingApp = false
    private var _isEnqueuingMic = false
    private var _enqueueLock = os_unfair_lock()'''

new1 = '''    private var enqueueCount: Int = 0
    private var lastEnqueueLog: CFTimeInterval = 0
    private let audioQueue = DispatchQueue(label: "com.replykit.audio", qos: .userInitiated)'''

c = c.replace(old1, new1, 1)

old2 = '''    func enqueue(_ sampleBuffer: CMSampleBuffer, trackType: AudioTrackType, oringinaltime: CMSampleTimingInfo) {
        os_unfair_lock_lock(&_enqueueLock)
        switch trackType {
        case .app:
            guard !_isEnqueuingApp else { os_unfair_lock_unlock(&_enqueueLock); return }
            _isEnqueuingApp = true
        case .mic:
            guard !_isEnqueuingMic else { os_unfair_lock_unlock(&_enqueueLock); return }
            _isEnqueuingMic = true
        }
        os_unfair_lock_unlock(&_enqueueLock)

        enqueueCount += 1
        let pts = oringinaltime.presentationTimeStamp.seconds
        let now = CACurrentMediaTime()
        let enablePipeLog = RPConfig.shared.enablePipelineLog
        let shouldLog = enablePipeLog && (enqueueCount == 1 || enqueueCount % 300 == 0 || (now - lastEnqueueLog) > 5.0)
        let localCount = enqueueCount

        Task.detached(priority: .utility) { [weak self] in
            guard let self, self.isActive else {
                if let self { self.setEnqueuing(false, trackType: trackType) }
                return
            }
            defer {
                self.setEnqueuing(false, trackType: trackType)
            }
            guard await self.mediaMixer.isRunning else {
                if shouldLog { sendlog(message: "[AudioProcessor] \\u26a0\\ufe0f #\\(localCount) MediaMixer \\u672a\\u8fd0\\u884c PTS:\\(String(format:"%.3f",pts))s") }
                return
            }'''

new2 = '''    func enqueue(_ sampleBuffer: CMSampleBuffer, trackType: AudioTrackType, oringinaltime: CMSampleTimingInfo) {
        enqueueCount += 1
        let pts = oringinaltime.presentationTimeStamp.seconds
        let now = CACurrentMediaTime()
        let enablePipeLog = RPConfig.shared.enablePipelineLog
        let shouldLog = enablePipeLog && (enqueueCount == 1 || enqueueCount % 300 == 0 || (now - lastEnqueueLog) > 5.0)
        let localCount = enqueueCount

        audioQueue.async { [weak self] in
            guard let self, self.isActive else { return }
            Task { [weak self] in
                guard let self, self.isActive else { return }
                guard await self.mediaMixer.isRunning else {
                    if shouldLog { sendlog(message: "[AudioProcessor] \\u26a0\\ufe0f #\\(localCount) MediaMixer \\u672a\\u8fd0\\u884c PTS:\\(String(format:"%.3f",pts))s") }
                    return
                }'''

c = c.replace(old2, new2, 1)

# Also update the trailing parts: remove the setEnqueuing calls, etc.
# The rest of the function body stays the same, just the enclosing structure changes

with open(r'C:\Users\agp05\OneDrive\桌面\ReplyKit\ReplyKIT\AudioProcess.swift', 'w', encoding='utf-8') as f:
    f.write(c)
print('OK')
