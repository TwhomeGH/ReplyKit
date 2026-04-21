import Foundation
import Accelerate
import AVFoundation

func CMSampleBufferToFloatArray(_ sampleBuffer: CMSampleBuffer) -> [Float]? {

    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
        return nil
    }

    let length = CMBlockBufferGetDataLength(blockBuffer)
    var data = [UInt8](repeating: 0, count: length)

    CMBlockBufferCopyDataBytes(blockBuffer,
                               atOffset: 0,
                               dataLength: length,
                               destination: &data)

    guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
    else {
        return nil
    }

    let format = asbd.pointee

    let sampleCount = length / Int(format.mBytesPerFrame)

    var floatBuffer = [Float](repeating: 0, count: sampleCount)

    // =========================
    // 🎯 Int16 PCM
    // =========================
    if format.mBitsPerChannel == 16 {

        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            let int16Ptr = ptr.bindMemory(to: Int16.self)

            for i in 0..<sampleCount {
                floatBuffer[i] = Float(int16Ptr[i]) / 32768.0
            }
        }

    }
    // =========================
    // 🎯 Float32 PCM
    // =========================
    else if format.mBitsPerChannel == 32 {

        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            let floatPtr = ptr.bindMemory(to: Float.self)
            floatBuffer = Array(floatPtr)
        }
    }
    else {
        return nil
    }

    return floatBuffer
}

func FloatArrayToCMSampleBuffer(_ samples: [Float],
                               original: CMSampleBuffer) -> CMSampleBuffer? {

    guard let formatDesc = CMSampleBufferGetFormatDescription(original)
    else {
        return nil
    }

    
    let sampleCount = samples.count

    // 🎯 轉回 Int16
    var int16Buffer = [Int16](repeating: 0, count: sampleCount)

    for i in 0..<sampleCount {
        let v = max(-1.0, min(1.0, samples[i]))
        int16Buffer[i] = Int16(v * 32767.0)
    }

    let dataSize = sampleCount * MemoryLayout<Int16>.size

    var blockBuffer: CMBlockBuffer?

    CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: &int16Buffer,
        blockLength: dataSize,
        blockAllocator: kCFAllocatorNull,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: dataSize,
        flags: 0,
        blockBufferOut: &blockBuffer
    )

    guard let bb = blockBuffer else { return nil }

    var newSampleBuffer: CMSampleBuffer?

    var timingInfo = CMSampleTimingInfo()
    CMSampleBufferGetSampleTimingInfo(original,
                                      at: 0,
                                      timingInfoOut: &timingInfo)

    CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: bb,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: formatDesc,
        sampleCount: sampleCount,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timingInfo,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &newSampleBuffer
    )

    return newSampleBuffer
}

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

        let alpha: Float = 0.6

        for i in 0..<count {
            let echo = referenceBuffer[i] * alpha
            mic[i] -= echo
        }
    }
}



// MARK: - Noise Suppressor (FFT-based)

final class RealTimeNoiseSuppressor {

    // MARK: - Config
    private let frameSize: Int = 512
    private let fftSize: Int = 1024
    private let hopSize: Int = 512

    // MARK: - FFT
    private var fftSetup: FFTSetup

    // MARK: - Buffers
    private var window: [Float]
    private var synthesisWindow: [Float]

    private var noiseEstimate: [Float]
    private var prevGain: [Float]

    private var inputBuffer: [Float]
    private var fftBuffer: [Float]

    // OLA
    private var overlapBuffer: [Float]

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
        synthesisWindow = [Float](repeating: 0, count: fftSize)

        noiseEstimate = [Float](repeating: 1e-3, count: fftSize/2)
        prevGain = [Float](repeating: 1.0, count: fftSize/2)

        inputBuffer = [Float](repeating: 0, count: fftSize)
        fftBuffer = [Float](repeating: 0, count: fftSize)

        overlapBuffer = [Float](repeating: 0, count: fftSize)

        // analysis / synthesis window
        vDSP_hann_window(&window,
                         vDSP_Length(fftSize),
                         Int32(vDSP_HANN_NORM))

        vDSP_hann_window(&synthesisWindow,
                         vDSP_Length(fftSize),
                         Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    // MARK: - Int16 → Float
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
        // 1️⃣ PCM decode
        // ======================================================
        decodeInt16(input)

        // ======================================================
        // 2️⃣ shift buffer（簡化版：直接覆蓋前半）
        // ======================================================
        for i in 0..<frameSize {
            inputBuffer[i] = inputBuffer[i]
            inputBuffer[i + frameSize] = 0
        }

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
            // 5️⃣ magnitude
            // ======================================================
            var mag = [Float](repeating: 0, count: fftSize/2)
            vDSP_zvmags(&split, 1, &mag, 1, vDSP_Length(fftSize/2))

            // ======================================================
            // 6️⃣ VAD
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
            // 7️⃣ noise update
            // ======================================================
            var a: Float = 0.98
            var b: Float = 0.02

            var tmp1 = [Float](repeating: 0, count: mag.count)
            var tmp2 = [Float](repeating: 0, count: mag.count)

            vDSP_vsmul(noiseEstimate, 1, &a, &tmp1, 1, vDSP_Length(mag.count))
            vDSP_vsmul(mag, 1, &b, &tmp2, 1, vDSP_Length(mag.count))
            vDSP_vadd(tmp1, 1, tmp2, 1, &noiseEstimate, 1, vDSP_Length(mag.count))

            // ======================================================
            // 8️⃣ SNR
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
            // 9️⃣ Wiener gain
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
            // 🔟 VAD gate
            // ======================================================
            if !isSpeech {
                var atten: Float = 0.08
                vDSP_vsmul(gain, 1,
                           &atten,
                           &gain, 1,
                           vDSP_Length(gain.count))
            }

            // clamp
            var minGain: Float = 0.05
            var maxGain: Float = 1.0
            vDSP_vclip(gain, 1,
                       &minGain, &maxGain,
                       &gain, 1,
                       vDSP_Length(gain.count))

            // ======================================================
            // 1️⃣1️⃣ smoothing
            // ======================================================
            var alpha: Float = 0.25
            var beta: Float = 0.75

            var temp1 = [Float](repeating: 0, count: gain.count)
            var temp2 = [Float](repeating: 0, count: gain.count)

            vDSP_vsmul(gain, 1, &alpha, &temp1, 1, vDSP_Length(gain.count))
            vDSP_vsmul(prevGain, 1, &beta, &temp2, 1, vDSP_Length(gain.count))
            vDSP_vadd(temp1, 1, temp2, 1, &gain, 1, vDSP_Length(gain.count))

            prevGain = gain

            // ======================================================
            // 1️⃣2️⃣ apply gain（修正點）
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
            // 1️⃣3️⃣ IFFT
            // ======================================================
            vDSP_fft_zrip(fftSetup,
                          &split,
                          1,
                          vDSP_Length(log2(Float(fftSize))),
                          FFTDirection(FFT_INVERSE))

            // ======================================================
            // 1️⃣4️⃣ split → interleaved
            // ======================================================
            var interleaved = [Float](repeating: 0, count: fftSize)

            interleaved.withUnsafeMutableBufferPointer { ptr in
                ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                   capacity: fftSize/2) { complexPtr in
                    vDSP_ztoc(&split, 1,
                              complexPtr, 2,
                              vDSP_Length(fftSize/2))
                }
            }

            // scale
            var scale: Float = 1.0 / Float(fftSize)
            vDSP_vsmul(interleaved, 1,
                       &scale,
                       &interleaved, 1,
                       vDSP_Length(fftSize))

            // synthesis window
            vDSP_vmul(interleaved, 1,
                      synthesisWindow, 1,
                      &interleaved, 1,
                      vDSP_Length(fftSize))

            // ======================================================
            // 1️⃣5️⃣ overlap-add
            // ======================================================
            memmove(&overlapBuffer[0],
                    &overlapBuffer[hopSize],
                    (fftSize - hopSize) * MemoryLayout<Float>.size)

            memset(&overlapBuffer[fftSize - hopSize],
                   0,
                   hopSize * MemoryLayout<Float>.size)

            vDSP_vadd(overlapBuffer, 1,
                      interleaved, 1,
                      &overlapBuffer, 1,
                      vDSP_Length(fftSize))

            // ======================================================
            // 1️⃣6️⃣ output
            // ======================================================
            memcpy(output,
                   overlapBuffer,
                   hopSize * MemoryLayout<Float>.size)
        }}
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