import re

with open(r'C:\Users\agp05\OneDrive\桌面\ReplyKit\ReplyKIT\VP.tmp', 'r', encoding='utf-8') as f:
    raw = f.read()
c = raw.replace('\r\n', '\n')

# Find second occurrence of guard !isProcessing
matches = list(re.finditer(r'guard !isProcessing', c))
if len(matches) >= 2:
    idx = matches[1].start()
    # Go back to find the closing brace before it
    prev_brace = c.rfind('}', idx - 60, idx)
    if prev_brace >= 0:
        start = prev_brace
    else:
        start = idx - 50
    
    # Find the end of the Task.detached block
    task_end = c.find('\n        }', idx + 200)
    if task_end >= 0:
        end = task_end + len('\n        }')
    else:
        end = idx + 2000
    
    old_block = c[start:end]
    
    # Build new block
    new_block = c[start:prev_brace + 1] + '''
        videoQueue.async { [weak self] in
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
                        sendlog("[VideoProcessor] \\u2764\\ufe0f \\u9023\\u7e8c \\(self.consecutiveDropCount) \\u5e40\\u65cb\\u8f49\\u5931\\u6557\\uff0c\\u6a19\\u8a18\\u91cd\\u5efa")
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
                        sendlog("[VideoProcessor] \\u26a0\\ufe0f #\\(localCount) MediaMixer \\u672a\\u8fd0\\u884c\\uff0c\\u8df3\\u904e PTS:\\(String(format:"%.3f",pts.seconds))s")
                    }
                    return
                }
                self.sentCount += 1
                if enablePipeLog, isFirstFrame || localCount % 300 == 0 {
                    sendlog("[VideoProcessor] #\\(localCount) \\u9001\\u51faMediaMixer PTS:\\(String(format:"%.3f",pts.seconds))s")
                }
                if let cb = correctedBuffer {
                    await self.mediaMixer.append(cb)
                } else {
                    await self.mediaMixer.append(rotated)
                }
            }
        }'''
    
    if old_block in c:
        c = c.replace(old_block, new_block, 1)
        with open(r'C:\Users\agp05\OneDrive\桌面\ReplyKit\ReplyKIT\VP.tmp', 'w', encoding='utf-8') as f:
            f.write(c.replace('\n', '\r\n'))
        print(f'OK - replaced {len(old_block)} chars')
    else:
        print('old_block NOT FOUND in c')
        # Debug: show the overlap
        overlap = c[idx-20:end+20]
        print(f'Context around match:')
        for i, ch in enumerate(overlap):
            if i < 20:
                print(f'{ch}', end='')
        print()
else:
    print(f'Found {len(matches)} matches, need 2')
