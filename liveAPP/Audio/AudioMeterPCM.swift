import AVFoundation

/// 限頻監測用 PCM RMS；跨所有聲道取均方根，不套用音量設定或重寫樣本。
enum AudioMeterPCM {
    /// 複製當次樣本，支援 AVAudioPCMBuffer 可表達的 PCM；失敗回傳 nil。
    static func rms(_ sample: CMSampleBuffer) -> Float? {
        guard sample.numSamples > 0, sample.numSamples <= 65536,
              let description = sample.formatDescription,
              let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }
        var asbd = pointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              let format = AVAudioFormat(streamDescription: &asbd),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(sample.numSamples)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0,
            frameCount: Int32(sample.numSamples), into: buffer.mutableAudioBufferList) == noErr else { return nil }
        return rms(buffer)
    }

    /// 支援 float32／float64／int16／int32，交錯或平面排列；空或非有限值不視為靜音。
    static func rms(_ buffer: AVAudioPCMBuffer) -> Float? {
        var sum = 0.0
        var count = 0
        for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let data = audio.mData else { return nil }
            let samples = Int(buffer.frameLength) * Int(audio.mNumberChannels)
            func accumulate<T>(_ type: T.Type, scale: Double, value: (T) -> Double) -> Bool {
                guard samples <= Int(audio.mDataByteSize) / MemoryLayout<T>.stride else { return false }
                let values = data.assumingMemoryBound(to: T.self)
                for index in 0..<samples {
                    let normalized = value(values[index]) / scale
                    guard normalized.isFinite else { return false }
                    sum += normalized * normalized
                }
                count += samples
                return true
            }
            let valid: Bool
            switch buffer.format.commonFormat {
            case .pcmFormatFloat32: valid = accumulate(Float.self, scale: 1) { Double($0) }
            case .pcmFormatFloat64: valid = accumulate(Double.self, scale: 1) { $0 }
            case .pcmFormatInt16: valid = accumulate(Int16.self, scale: 32768) { Double($0) }
            case .pcmFormatInt32: valid = accumulate(Int32.self, scale: 2147483648) { Double($0) }
            default: return nil
            }
            guard valid else { return nil }
        }
        guard count > 0 else { return nil }
        let result = Float(sqrt(sum / Double(count)))
        return result.isFinite ? result : nil
    }
}
