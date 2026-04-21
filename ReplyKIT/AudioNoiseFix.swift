import Foundation
import Accelerate


final class AGCProcessor {

    private var targetLevel: Float = 0.15
    private var gain: Float = 1.0
    private let attack: Float = 0.01
    private let release: Float = 0.001

    func process(_ buffer: inout [Float]) {

        var rms: Float = 0
        vDSP_measqv(buffer, 1, &rms, vDSP_Length(buffer.count))
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
                   &buffer, 1,
                   vDSP_Length(buffer.count))
    }
}


final class EchoCanceller {

    /// 播放出去的 reference audio（speaker）
    private var referenceBuffer: [Float]

    init(size: Int) {
        referenceBuffer = [Float](repeating: 0, count: size)
    }

    func updateReference(_ ref: [Float]) {
        referenceBuffer = ref
    }

    func process(_ mic: inout [Float]) {

        let count = min(mic.count, referenceBuffer.count)

        var alpha: Float = 0.6

        for i in 0..<count {
            let echo = referenceBuffer[i] * alpha
            mic[i] -= echo
        }
    }
}



// MARK: - Metal-based Noise Suppressor (optional)

final class RealTimeNoiseSuppressor {


    // MARK: - Config
    private let frameSize: Int = 512
    private let fftSize: Int = 1024

    // MARK: - FFT
    private var fftSetup: FFTSetup

    // MARK: - Buffers
    private var window: [Float]

    private var noiseEstimate: [Float]
    private var prevGain: [Float]

    private var inputBuffer: [Float]
    private var fftBuffer: [Float]
    private var outputBuffer: [Float]

    // MARK: - VAD
    private var vadThreshold: Float = 0.002
    private var vadHangover: Int = 5
    private var vadCounter: Int = 0
    private var isSpeech: Bool = false

    // MARK: - Init
    init() {

        let log2n = vDSP_Length(log2(Float(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        window = [Float](repeating: 0, count: fftSize)
        noiseEstimate = [Float](repeating: 1e-3, count: fftSize/2)
        prevGain = [Float](repeating: 1.0, count: fftSize/2)

        inputBuffer = [Float](repeating: 0, count: fftSize)
        fftBuffer = [Float](repeating: 0, count: fftSize)
        outputBuffer = [Float](repeating: 0, count: fftSize)

        vDSP_hann_window(&window,
                         vDSP_Length(fftSize),
                         Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    // MARK: - PCM Decode (Int16 -> Float)
    private func decodeInt16(_ input: UnsafePointer<Float>) {
        let ptr = input.withMemoryRebound(to: Int16.self,
                                           capacity: frameSize) { $0 }

        for i in 0..<frameSize {
            inputBuffer[i] = Float(ptr[i]) / 32768.0
        }
    }

    // MARK: - Process
    func process(input: UnsafePointer<Float>,
                 output: UnsafeMutablePointer<Float>) {

        // ======================================================
        // 1️⃣ PCM decode (Int16 → Float)
        // ======================================================
        decodeInt16(input)

        // ======================================================
        // 2️⃣ window + zero pad
        // ======================================================
        vDSP_vmul(inputBuffer, 1,
                  window, 1,
                  &fftBuffer, 1,
                  vDSP_Length(fftSize))

        // ======================================================
        // 3️⃣ FFT
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
            // 4️⃣ magnitude
            // ======================================================
            var mag = [Float](repeating: 0, count: fftSize/2)
            vDSP_zvmags(&split, 1, &mag, 1, vDSP_Length(fftSize/2))

            // ======================================================
            // 5️⃣ VAD (RMS energy)
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

            // ======================================================
            // 6️⃣ noise update
            // ======================================================
            var a: Float = 0.98
            var b: Float = 0.02

            var tmp1 = [Float](repeating: 0, count: mag.count)
            var tmp2 = [Float](repeating: 0, count: mag.count)

            vDSP_vsmul(noiseEstimate, 1, &a, &tmp1, 1, vDSP_Length(mag.count))
            vDSP_vsmul(mag, 1, &b, &tmp2, 1, vDSP_Length(mag.count))
            vDSP_vadd(tmp1, 1, tmp2, 1, &noiseEstimate, 1, vDSP_Length(mag.count))

            // ======================================================
            // 7️⃣ SNR
            // ======================================================
            var eps: Float = 1e-6
            var noiseSafe = noiseEstimate
            vDSP_vsadd(noiseSafe, 1, &eps, &noiseSafe, 1, vDSP_Length(mag.count))

            var snr = [Float](repeating: 0, count: mag.count)
            vDSP_vdiv(noiseSafe, 1,
                      mag, 1,
                      &snr, 1,
                      vDSP_Length(mag.count))

            // ======================================================
            // 8️⃣ Wiener gain
            // ======================================================
            var one: Float = 1.0
            var denom = [Float](repeating: 0, count: mag.count)
            var gain = [Float](repeating: 0, count: mag.count)

            vDSP_vsadd(snr, 1, &one, &denom, 1, vDSP_Length(mag.count))
            vDSP_vdiv(denom, 1,
                      snr, 1,
                      &gain, 1,
                      vDSP_Length(mag.count))

            // ======================================================
            // 9️⃣ VAD gate
            // ======================================================
            if !isSpeech {
                var atten: Float = 0.08
                vDSP_vsmul(gain, 1,
                           &atten,
                           &gain, 1,
                           vDSP_Length(gain.count))
            } else {
                var minGain: Float = 0.25
                vDSP_vclip(gain, 1,
                           &minGain, &one,
                           &gain, 1,
                           vDSP_Length(gain.count))
            }

            // ======================================================
            // 🔟 smoothing
            // ======================================================
            var alpha: Float = 0.25
            var beta: Float = 0.75

            var temp = [Float](repeating: 0, count: gain.count)

            vDSP_vsmul(gain, 1, &alpha, &temp, 1, vDSP_Length(gain.count))
            vDSP_vsmul(prevGain, 1, &beta, &prevGain, 1, vDSP_Length(gain.count))
            vDSP_vadd(prevGain, 1, temp, 1, &gain, 1, vDSP_Length(gain.count))

            prevGain = gain

            // ======================================================
            // 1️⃣1️⃣ apply gain
            // ======================================================
            vDSP_vsmul(split.realp, 1,
                       gain, 1,
                       split.realp, 1,
                       vDSP_Length(gain.count))

            vDSP_vsmul(split.imagp, 1,
                       gain, 1,
                       split.imagp, 1,
                       vDSP_Length(gain.count))

            // ======================================================
            // 1️⃣2️⃣ IFFT
            // ======================================================
            vDSP_fft_zrip(fftSetup,
                          &split,
                          1,
                          vDSP_Length(log2(Float(fftSize))),
                          FFTDirection(FFT_INVERSE))

            var scale: Float = 1.0 / Float(fftSize)
            vDSP_vsmul(split.realp, 1,
                       &scale,
                       &outputBuffer,
                       1,
                       vDSP_Length(fftSize/2))
        }}

        // ======================================================
        // 🔚 output (stable downmix)
        // ======================================================
        if !isSpeech {
            var mute: Float = 0.03
            vDSP_vsmul(outputBuffer, 1,
                       &mute,
                       &outputBuffer, 1,
                       vDSP_Length(frameSize))
        }

        memcpy(output,
               &outputBuffer,
               frameSize * MemoryLayout<Float>.size)
    }
}





// MARK: - Main PreProcessor (AGC + Echo + Noise Suppression)
final class AudioPreProcessor {

    private let agc = AGCProcessor()
    private let echo = EchoCanceller(size: 512)

    /// 🔥 你可以接你現在 NS engine reference
    weak var noiseSuppressor: RealTimeNoiseSuppressor?

    // MARK: - Speaker reference (from playback side)
    func setPlaybackReference(_ buffer: [Float]) {
        echo.updateReference(buffer)
    }

    // MARK: - Main entry
    func process(_ buffer: inout [Float]) {

        // ======================================================
        // 🌫 Echo suppression (first step)
        // ======================================================
        echo.process(&buffer)

        // ======================================================
        // 🎚 AGC (normalize level)
        // ======================================================
        agc.process(&buffer)

        // ======================================================
        // 🧠 Noise suppression (your FFT engine)
        // ======================================================
        buffer.withUnsafeBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: Float.self,
                                               capacity: buffer.count) { p in

                var output = [Float](repeating: 0, count: buffer.count)

                noiseSuppressor?.process(input: p,
                                          output: &output)

                buffer = output
            }
        }
    }
}