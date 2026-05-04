import Foundation
import Accelerate
import AVFoundation



final class AGCProcessor {

    private var targetLevel: Float = 0.15
    private var gain: Float = 1.0
    private let attack: Float = 0.01
    private let release: Float = 0.001

    func process(_ buffer: UnsafeMutablePointer<Float>, count: Int) {

        var rms: Float = 0
        vDSP_measqv(buffer, 1, &rms, vDSP_Length(count))
        rms = sqrt(rms)

        guard rms > 0 else { return }

        let desiredGain = targetLevel / rms

        if desiredGain < gain {
            gain = gain * (1 - attack) + desiredGain * attack
        } else {
            gain = gain * (1 - release) + desiredGain * release
        }

        vDSP_vsmul(buffer, 1,
                &gain,
                buffer, 1,
                vDSP_Length(count))


    }
}


final class EchoCanceller {

    private var referenceBuffer: [Float]
    private var writeIndex: Int = 0

    init(size: Int) {
        referenceBuffer = [Float](repeating: 0, count: size)
    }

    func updateReference(_ ref: UnsafePointer<Float>, count: Int) {

        let size = referenceBuffer.count
        let n = min(count, size)

        for i in 0..<n {
            let idx = (writeIndex + i) % size
            referenceBuffer[idx] = ref[i]
        }

        writeIndex = (writeIndex + n) % size
    }

    func process(_ mic: UnsafeMutablePointer<Float>, count: Int) {

        let size = referenceBuffer.count

        for i in 0..<count {
            let idx = (writeIndex + i) % size
            let echo = referenceBuffer[idx] * 0.5
            mic[i] -= echo
        }
    }
}



// MARK: - Noise Suppressor (FFT-based)

final class RealTimeNoiseSuppressor {


    private let frameSize = 512
    private let fftSize = 1024
    private let hopSize = 512

    private let log2n: vDSP_Length = 10

    private var fftSetup: FFTSetup

    // buffers（全部重用，0 allocation）
    private var window: [Float]
    private var inputBuffer: [Float]
    private var fftBuffer: [Float]
    private var outputBuffer: [Float]

    private var real: [Float]
    private var imag: [Float]
    private var mag: [Float]
    private var gain: [Float]
    private var snr: [Float]

    private var noiseEstimate: [Float]

    private var ringBuffer: [Float]
    private var writeIndex: Int = 0

    private var vadThreshold: Float = 0.002
    private var vadHangover: Int = 5
    private var vadCounter: Int = 0
    private var isSpeech: Bool = false


    init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        window = [Float](repeating: 0, count: fftSize)
        inputBuffer = [Float](repeating: 0, count: fftSize)
        fftBuffer = [Float](repeating: 0, count: fftSize)
        outputBuffer = [Float](repeating: 0, count: fftSize)

        ringBuffer = [Float](repeating: 0, count: fftSize)
        
        
        real = [Float](repeating: 0, count: fftSize/2)
        imag = [Float](repeating: 0, count: fftSize/2)
        mag  = [Float](repeating: 0, count: fftSize/2)
        gain = [Float](repeating: 1.0, count: fftSize/2)
        snr  = [Float](repeating: 0, count: fftSize/2)

        noiseEstimate = [Float](repeating: 1e-3, count: fftSize/2)

        vDSP_hann_window(&window,
                         vDSP_Length(fftSize),
                         Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }


    @inline(__always)
    private func pushToRingBuffer(_ input: UnsafePointer<Float>, count: Int) {

        for i in 0..<count {

            ringBuffer[writeIndex] = input[i]

            writeIndex += 1
            if writeIndex >= fftSize {
                writeIndex = 0
            }
        }
    }

    @inline(__always)
    private func loadFFTWindow(_ out: inout [Float]) {

        let start = writeIndex

        for i in 0..<fftSize {

            let idx = (start + i) % fftSize
            out[i] = ringBuffer[idx]
        }
    }

    func process(_ ptr: UnsafeMutablePointer<Float>, count: Int) {

        // ======================================================
        // 1️⃣ push into ring buffer
        // ======================================================
            pushToRingBuffer(ptr, count: count)

        // ======================================================
        // 2️⃣ load FFT frame (no memmove)
        // ======================================================
            loadFFTWindow(&inputBuffer)

        // ======================================================
        // 3️⃣ window
        // ======================================================
            vDSP_vmul(inputBuffer, 1,
                    window, 1,
                    &fftBuffer, 1,
                    vDSP_Length(fftSize))

        // ======================================================
        // 4️⃣ FFT
        // ======================================================
        var real = [Float](repeating: 0, count: fftSize/2)
        var imag = [Float](repeating: 0, count: fftSize/2)

        real.withUnsafeMutableBufferPointer { rPtr in
        imag.withUnsafeMutableBufferPointer { iPtr in

            var split = DSPSplitComplex(realp: rPtr.baseAddress!,
                                        imagp: iPtr.baseAddress!)

            fftBuffer.withUnsafeBufferPointer { buf in
                buf.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                capacity: fftSize/2) {
                    vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize/2))
                }
            }

            vDSP_fft_zrip(fftSetup,
                        &split,
                        1,
                        vDSP_Length(log2(Float(fftSize))),
                        FFTDirection(FFT_FORWARD))

            // ======================================================
            // magnitude
            // ======================================================
            var mag = [Float](repeating: 0, count: fftSize/2)
            vDSP_zvmags(&split, 1, &mag, 1, vDSP_Length(fftSize/2))

            // ======================================================
            // VAD + noise model（保留你原本邏輯）
            // ======================================================
            var energy: Float = 0
            vDSP_measqv(mag, 1, &energy, vDSP_Length(mag.count))

            if energy > vadThreshold {
                vadCounter = vadHangover
                isSpeech = true
            } else {
                vadCounter -= 1
                if vadCounter <= 0 {
                    isSpeech = false
                }
            }

            // noise update
            var a: Float = 0.98
            var b: Float = 0.02

            var tmp1 = [Float](repeating: 0, count: mag.count)
            var tmp2 = [Float](repeating: 0, count: mag.count)

            vDSP_vsmul(noiseEstimate, 1, &a, &tmp1, 1, vDSP_Length(mag.count))
            vDSP_vsmul(mag, 1, &b, &tmp2, 1, vDSP_Length(mag.count))
            vDSP_vadd(tmp1, 1, tmp2, 1, &noiseEstimate, 1, vDSP_Length(mag.count))

            // ======================================================
            // gain compute
            // ======================================================
            var snr = [Float](repeating: 0, count: mag.count)

            vDSP_vdiv(noiseEstimate, 1,
                    mag, 1,
                    &snr, 1,
                    vDSP_Length(mag.count))

            var gain = [Float](repeating: 0, count: mag.count)

            var one: Float = 1.0
            vDSP_vsadd(snr, 1, &one, &gain, 1, vDSP_Length(mag.count))

            // ======================================================
            // apply gain
            // ======================================================
            vDSP_vmul(split.realp, 1,
                    gain, 1,
                    split.realp, 1,
                    vDSP_Length(gain.count))

            vDSP_vmul(split.imagp, 1,
                    gain, 1,
                    split.imagp, 1,
                    vDSP_Length(gain.count))

            // ======================================================
            // IFFT
            // ======================================================
            vDSP_fft_zrip(fftSetup,
                        &split,
                        1,
                        vDSP_Length(log2(Float(fftSize))),
                        FFTDirection(FFT_INVERSE))

            // ======================================================
            // output (直接寫回 ptr)
            // ======================================================
            var out = [Float](repeating: 0, count: fftSize)

            out.withUnsafeMutableBufferPointer { oPtr in
                oPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                    capacity: fftSize/2) {
                    vDSP_ztoc(&split, 1,
                            $0, 2,
                            vDSP_Length(fftSize/2))
                }
            }

            var scale: Float = 1.0 / Float(fftSize)

            vDSP_vsmul(out, 1,
                    &scale,
                    &out, 1,
                    vDSP_Length(fftSize))

            // 👉 直接寫回（無 overlap buffer）
            memcpy(ptr,
                out,
                count * MemoryLayout<Float>.size)
        }}
    }
}


final class AudioEngine {

    private let preProcessor: AudioPreProcessor

    init(noiseFix: Bool? = nil,echoFix:Bool?=nil,agcFix:Bool? = nil,micGain:Float?=nil) {

        self.preProcessor = AudioPreProcessor(micGain:micGain,echoFix:echoFix,noiseFix: noiseFix,agcFix:agcFix)
    }

   // ======================================================
    // 🎛 封裝後的唯一控制入口
    // ======================================================
    func updateAudioState(micGain: Float? = nil,
                          echoFix: Bool? = nil,
                          noiseFix: Bool? = nil,
                          agcFix:Bool? = nil) {

        preProcessor.updateState(
            micGain: micGain,
            echoFix: echoFix,
            noiseFix: noiseFix,
            agcFix: agcFix
        )
    }

    // ======================================================
    // 🎧 routing only (no return transformation)
    // ======================================================
    func process(_ sampleBuffer: CMSampleBuffer,
                 track: AudioTrackType) {

        preProcessor.process(sampleBuffer, track: track)
    }
}



// MARK: - Main PreProcessor (AGC + Echo + Noise Suppression)


final class AudioPreProcessor {


    // ======================================================
    // 🎛 DSP State（唯一控制入口）
    // ======================================================
    private struct State {
        var micGain: Float = 1.0
        var echoFix: Bool = false
        var noiseFixEnabled: Bool = false
        var agcFixEnabled: Bool = false
    }

    private var state = State()

    private let stateQueue = DispatchQueue(label: "audio.state.queue")


    // MARK: - Public control API
    // ======================================================
    // 🎛 unified state update
    // ======================================================
    func updateState(micGain: Float? = nil,
                     echoFix: Bool? = nil,
                     noiseFix: Bool? = nil,
                     agcFix: Bool? = nil) {

        stateQueue.async {

        if let micGain = micGain {
            self.state.micGain = micGain.isFinite ? micGain : 1.0
        }

        if let echoFix = echoFix {
            self.state.echoFix = echoFix
        }

        if let noiseFix = noiseFix {
            self.state.noiseFixEnabled = noiseFix
        }
        if let agcFix = agcFix {
            self.state.agcFixEnabled = agcFix
        }


        }
    }



    // ======================================================
    // 🧠 Reusable buffers（關鍵：避免每次 alloc）
    // ======================================================
    private var micFloatBuffer: [Float]
    private var tempFloatBuffer: [Float]

    private let agc = AGCProcessor()
    private let echo = EchoCanceller(size: 1024)
    private let ns = RealTimeNoiseSuppressor()
    


    



    init(maxFrameSize: Int = 512,noiseFix:Bool? = nil,echoFix:Bool? = nil, agcFix:Bool? = nil,micGain:Float? = nil) {
        self.micFloatBuffer = [Float](repeating: 0, count: maxFrameSize)
        self.tempFloatBuffer = [Float](repeating: 0, count: maxFrameSize)

        self.updateState(micGain:micGain,echoFix:echoFix,noiseFix:noiseFix,agcFix:agcFix) 

    }

    // ======================================================
    // 🎧 App reference（不做任何 DSP）
    // ======================================================

    func processApp(_ ptr: UnsafeMutablePointer<Float>, count: Int) {

        // ✔ 只做 conversion（reuse buffer，不 alloc）
        ensureCapacity(count)

        for i in 0..<count {
            tempFloatBuffer[i] = Float(ptr[i]) / 32768.0
        }

        tempFloatBuffer.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }

            echo.updateReference(base, count: ptr.count)
        }

        
    }

    // ======================================================
    // 🎤 Mic main pipeline
    // ======================================================
    func processMic(_ ptr: UnsafeMutablePointer<Float>, count: Int) {

        ensureCapacity(count)

        // ==================================================
        // 1️⃣ Int16 → Float (reuse buffer)
        // ==================================================
        for i in 0..<count {
            micFloatBuffer[i] = Float(ptr[i]) / 32768.0
        }

        // ==================================================
        // 2️⃣ Echo cancel (in-place)
        // ==================================================
        if state.echoFix {
        echo.process(&micFloatBuffer, count: count)

        }

        // ==================================================
        // 3️⃣ Noise suppression
        // ==================================================

        if state.noiseFixEnabled {
        ns.process(&micFloatBuffer, count: count)

        }

        // ==================================================
        // 4️⃣ AGC
        // ==================================================
        if state.agcFixEnabled {
        agc.process(&micFloatBuffer, count: count)

        }
        // ==================================================
        // 5️⃣ User gain (final stage)
        // ==================================================
        applyPostGain(&micFloatBuffer, count: count)
    }

     // ======================================================
    // 🎧 process（你原本 DSP pipeline）
    // ======================================================
    func process(_ sampleBuffer: CMSampleBuffer,
                track: AudioTrackType) {

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return
        }

        var dataPointer: UnsafeMutablePointer<Int8>?

        CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: nil,
            dataPointerOut: &dataPointer
        )

        guard let rawPtr = dataPointer else {
            return
        }

        // ======================================================
        // 🎧 Int16 pointer
        // ======================================================
        let byteCount = CMBlockBufferGetDataLength(blockBuffer)
        let sampleCount = byteCount / MemoryLayout<Int16>.size

        let int16Ptr = UnsafeMutableRawPointer(rawPtr)
            .bindMemory(to: Int16.self, capacity: sampleCount)

        // ======================================================
        // 🎧 Float buffer（必要轉換）
        // ======================================================
        var floatBuffer = [Float](repeating: 0, count: sampleCount)

        vDSP_vflt16(int16Ptr, 1,
                    &floatBuffer, 1,
                    vDSP_Length(sampleCount))

        var scale: Float = 1.0 / 32768.0
        vDSP_vsmul(floatBuffer, 1,
                &scale,
                &floatBuffer, 1,
                vDSP_Length(sampleCount))

        // ======================================================
        // 🎧 分流（真正 DSP 在這）
        // ======================================================
        floatBuffer.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }

            switch track {

            case .app:
                processApp(base, count: sampleCount)

            case .mic:
                processMic(base, count: sampleCount)
            }
        }

        // ======================================================
        // 🔚 Float → Int16（寫回原 buffer）
        // ======================================================
        var invScale: Float = 32768.0

        vDSP_vsmul(floatBuffer, 1,
                &invScale,
                &floatBuffer, 1,
                vDSP_Length(sampleCount))

        vDSP_vfix16(floatBuffer, 1,
                    int16Ptr, 1,
                    vDSP_Length(sampleCount))
    }

    // ======================================================
    // 🎚 user gain（最后 stage）
    // ======================================================
    private func applyPostGain(_ buffer: inout [Float], count: Int) {

        let gain = state.micGain

        guard abs(gain - 1.0) > 0.001 else { return }

        var g = gain
        vDSP_vsmul(buffer, 1,
                   &g,
                   &buffer, 1,
                   vDSP_Length(count))
    }

    // ======================================================
    // 🧠 buffer safety
    // ======================================================
    private func ensureCapacity(_ count: Int) {
        if micFloatBuffer.count < count {
            micFloatBuffer = [Float](repeating: 0, count: count)
        }

        if tempFloatBuffer.count < count {
            tempFloatBuffer = [Float](repeating: 0, count: count)
        }
    }


}

    
