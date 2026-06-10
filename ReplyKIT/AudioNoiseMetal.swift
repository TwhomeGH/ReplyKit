import Foundation
import Accelerate
import AVFoundation
import Metal

// MARK: - Metal shader params (mirror of Metal struct)
struct NoiseSuppressParams {
    var noiseAlpha: Float = 0.98
    var noiseBeta: Float = 0.02
    var vadThreshold: Float = 0.0001
    var minGain: Float = 0.01
    var frameSize: UInt32 = 0
}

// MARK: - GPU 延遲追蹤器（附冷卻機制，避免 Metal/CPU 反覆切換）
final class GPULatencyTracker {
    private var history: [Double] = []
    private let maxSize = 30
    private var _isOverloaded = false
    private var lastFallbackTime: CFTimeInterval = 0
    private let cooldownDuration: CFTimeInterval = 3.0

    var isOverloaded: Bool {
        guard _isOverloaded else { return false }
        let elapsed = CACurrentMediaTime() - lastFallbackTime
        if elapsed >= cooldownDuration {
            _isOverloaded = false
            reset()
            return false
        }
        return true
    }

    func record(_ seconds: Double) {
        let ms = seconds * 1000
        history.append(ms)
        if history.count > maxSize {
            history.removeFirst()
        }
        let avg = history.reduce(0, +) / Double(history.count)
        if avg > 8.0 {
            _isOverloaded = true
            lastFallbackTime = CACurrentMediaTime()
        } else if avg < 3.0 {
            _isOverloaded = false
        }
    }

    func reset() {
        history.removeAll()
        _isOverloaded = false
    }
}

// MARK: - Metal 加速降噪處理器
// Hybrid: vDSP FFT/IFFT + Metal per-bin noise estimation & Wiener gain
// GPU timeout 時自動 fallback 到 CPU Wiener gain（Scheme A+B+C）

final class MetalRealTimeNoiseSuppressor {

    private let frameSize = 512
    private let fftSize = 1024
    private let hopSize = 512

    private let log2n: vDSP_Length = 10

    private var fftSetup: FFTSetup

    private var window: [Float]
    private var inputBuffer: [Float]
    private var fftBuffer: [Float]
    private var outputBuffer: [Float]

    private var real: [Float]
    private var imag: [Float]
    private var mag: [Float]
    private var gain: [Float]

    private var noiseEstimate: [Float]
    private var tmp1: [Float]
    private var tmp2: [Float]
    private var outBuffer: [Float]
    private var overlapBuffer: [Float]

    private var ringBuffer: [Float]
    private var writeIndex: Int = 0

    private var vadThreshold: Float = 0.002
    private var vadHangover: Int = 5
    private var vadCounter: Int = 0
    private var isSpeech: Bool = false

    // MARK: Metal
    private let metalDevice: MTLDevice
    private let metalQueue: MTLCommandQueue
    private let metalPipeline: MTLComputePipelineState

    private let magBuffer: MTLBuffer
    private let noiseBuffer: MTLBuffer
    private let gainBuffer: MTLBuffer
    private let realBuffer: MTLBuffer
    private let imagBuffer: MTLBuffer
    private let paramsBuffer: MTLBuffer

    private let gpuTimeoutMs: Double = 8.0

    init?() {
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

        noiseEstimate = [Float](repeating: 1e-3, count: fftSize/2)
        tmp1 = [Float](repeating: 0, count: fftSize/2)
        tmp2 = [Float](repeating: 0, count: fftSize/2)
        outBuffer = [Float](repeating: 0, count: fftSize)
        overlapBuffer = [Float](repeating: 0, count: hopSize)

        vDSP_hann_window(&window,
                         vDSP_Length(fftSize),
                         Int32(vDSP_HANN_NORM))

        // MARK: Metal setup
        let ctx = MetalContext.shared
        metalDevice = ctx.device
        metalQueue = ctx.queue

        guard let fn = ctx.library.makeFunction(name: "noiseSuppress"),
              let pipeline = try? metalDevice.makeComputePipelineState(function: fn) else {
            sendlog(message: "MetalNoiseSuppressor: 建立 pipeline 失敗")
            return nil
        }
        metalPipeline = pipeline

        let binCount = fftSize / 2
        let binBytes = binCount * MemoryLayout<Float>.size

        magBuffer = metalDevice.makeBuffer(length: binBytes, options: .storageModeShared)!
        noiseBuffer = metalDevice.makeBuffer(length: binBytes, options: .storageModeShared)!
        gainBuffer = metalDevice.makeBuffer(length: binBytes, options: .storageModeShared)!
        realBuffer = metalDevice.makeBuffer(length: binBytes, options: .storageModeShared)!
        imagBuffer = metalDevice.makeBuffer(length: binBytes, options: .storageModeShared)!

        var params = NoiseSuppressParams(
            noiseAlpha: 0.98, noiseBeta: 0.02,
            vadThreshold: 0.0001, minGain: 0.01,
            frameSize: UInt32(binCount)
        )
        paramsBuffer = metalDevice.makeBuffer(bytes: &params,
                                              length: MemoryLayout<NoiseSuppressParams>.stride,
                                              options: .storageModeShared)!

        sendlog(message: "MetalNoiseSuppressor: 初始化完成 bins=\(binCount)")
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    @inline(__always)
    private func pushToRingBuffer(_ input: UnsafePointer<Float>, count: Int) {
        let safeCount = min(count, fftSize)
        let offset = count > fftSize ? count - fftSize : 0
        for i in 0..<safeCount {
            ringBuffer[writeIndex] = input[offset + i]
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

    func process(_ ptr: UnsafeMutablePointer<Float>, count: Int, forceCPU: Bool = false) {
        // 1. push into ring buffer
        pushToRingBuffer(ptr, count: count)

        // 2. load FFT window
        loadFFTWindow(&inputBuffer)

        // 3. window
        vDSP_vmul(inputBuffer, 1,
                  window, 1,
                  &fftBuffer, 1,
                  vDSP_Length(fftSize))

        // 4. FFT forward with safe pointer unwrapping
        real.withUnsafeMutableBufferPointer { rPtr in
        imag.withUnsafeMutableBufferPointer { iPtr in
            guard let rBase = rPtr.baseAddress, let iBase = iPtr.baseAddress else { return }
            var split = DSPSplitComplex(realp: rBase, imagp: iBase)

            fftBuffer.withUnsafeBufferPointer { buf in
                guard let src = buf.baseAddress else { return }
                src.withMemoryRebound(to: DSPComplex.self, capacity: fftSize/2) {
                    vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize/2))
                }
            }

            vDSP_fft_zrip(fftSetup,
                          &split,
                          1,
                          vDSP_Length(log2(Float(fftSize))),
                          FFTDirection(FFT_FORWARD))

            // 5. magnitude
            vDSP_zvmags(&split, 1, &mag, 1, vDSP_Length(fftSize/2))

            if forceCPU {
                // Scheme C: CPU fallback gain model (Wiener)
                fallbackCPUNoiseModel(split: &split)
            } else {
                // 6. GPU per-bin noise suppression with timeout
                let gpuOK = runMetalKernelWithTimeout(split: &split)
                if !gpuOK {
                    // GPU timeout → 原地 CPU Wiener gain fallback
                    fallbackCPUNoiseModel(split: &split)
                }
            }

            // 7. IFFT
            vDSP_fft_zrip(fftSetup,
                          &split,
                          1,
                          vDSP_Length(log2(Float(fftSize))),
                          FFTDirection(FFT_INVERSE))

            // 8. ZTO with safe pointer
            outBuffer.withUnsafeMutableBufferPointer { oPtr in
                guard let dst = oPtr.baseAddress else { return }
                dst.withMemoryRebound(to: DSPComplex.self, capacity: fftSize/2) {
                    vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(fftSize/2))
                }
            }

            // 9. scale
            var scale: Float = 1.0 / Float(fftSize)
            vDSP_vsmul(outBuffer, 1,
                       &scale,
                       &outBuffer, 1,
                       vDSP_Length(fftSize))

            // 10. overlap-add
            vDSP_vadd(outBuffer, 1,
                      overlapBuffer, 1,
                      ptr, 1,
                      vDSP_Length(hopSize))

            // 11. save tail
            outBuffer.withUnsafeBufferPointer { srcBuf in
                guard let src = srcBuf.baseAddress else { return }
                memcpy(&overlapBuffer, src + hopSize, hopSize * MemoryLayout<Float>.size)
            }
        }}
    }

    // MARK: - CPU fallback noise model (Scheme C)
    private func fallbackCPUNoiseModel(split: inout DSPSplitComplex) {
        let binCount = fftSize / 2

        var energy: Float = 0
        vDSP_measqv(mag, 1, &energy, vDSP_Length(binCount))

        if energy > vadThreshold {
            vadCounter = vadHangover
            isSpeech = true
        } else {
            vadCounter -= 1
            if vadCounter <= 0 {
                isSpeech = false
            }
        }

        var a: Float = 0.98
        var b: Float = 0.02
        vDSP_vsmul(noiseEstimate, 1, &a, &tmp1, 1, vDSP_Length(binCount))
        vDSP_vsmul(mag, 1, &b, &tmp2, 1, vDSP_Length(binCount))
        vDSP_vadd(tmp1, 1, tmp2, 1, &noiseEstimate, 1, vDSP_Length(binCount))

        var snr = self.gain
        vDSP_vdiv(noiseEstimate, 1, mag, 1, &snr, 1, vDSP_Length(binCount))

        var one: Float = 1.0
        vDSP_vsadd(snr, 1, &one, &gain, 1, vDSP_Length(binCount))

        vDSP_vmul(split.realp, 1, gain, 1, split.realp, 1, vDSP_Length(binCount))
        vDSP_vmul(split.imagp, 1, gain, 1, split.imagp, 1, vDSP_Length(binCount))
    }

    // MARK: - Async GPU kernel with timeout (Scheme A + C)
    private func runMetalKernelWithTimeout(split: inout DSPSplitComplex) -> Bool {
        let binCount = fftSize / 2

        memcpy(magBuffer.contents(), mag, binCount * MemoryLayout<Float>.size)
        memcpy(noiseBuffer.contents(), noiseEstimate, binCount * MemoryLayout<Float>.size)
        memcpy(realBuffer.contents(), split.realp, binCount * MemoryLayout<Float>.size)
        memcpy(imagBuffer.contents(), split.imagp, binCount * MemoryLayout<Float>.size)

        guard let cmd = metalQueue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return false }

        enc.setComputePipelineState(metalPipeline)
        enc.setBuffer(magBuffer, offset: 0, index: 0)
        enc.setBuffer(noiseBuffer, offset: 0, index: 1)
        enc.setBuffer(gainBuffer, offset: 0, index: 2)
        enc.setBuffer(realBuffer, offset: 0, index: 3)
        enc.setBuffer(imagBuffer, offset: 0, index: 4)
        enc.setBuffer(paramsBuffer, offset: 0, index: 5)

        let threads = MTLSize(width: binCount, height: 1, depth: 1)
        let tg = MTLSize(width: min(metalPipeline.threadExecutionWidth, binCount),
                         height: 1, depth: 1)
        enc.dispatchThreads(threads, threadsPerThreadgroup: tg)
        enc.endEncoding()

        let sema = DispatchSemaphore(value: 0)
        cmd.addCompletedHandler { _ in
            sema.signal()
        }
        cmd.commit()

        let timeout = DispatchTime.now() + .milliseconds(Int(gpuTimeoutMs))
        let waitResult = sema.wait(timeout: timeout)

        guard waitResult == .success else {
            return false
        }

        memcpy(&noiseEstimate, noiseBuffer.contents(), binCount * MemoryLayout<Float>.size)
        memcpy(&gain, gainBuffer.contents(), binCount * MemoryLayout<Float>.size)
        memcpy(split.realp, realBuffer.contents(), binCount * MemoryLayout<Float>.size)
        memcpy(split.imagp, imagBuffer.contents(), binCount * MemoryLayout<Float>.size)
        return true
    }
}
