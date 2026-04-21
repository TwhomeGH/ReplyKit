// 目前不使用未來留給其他的使用或重寫成其他功能

// import Foundation
// import Metal

// final class MetalNoiseSuppressor {

//     // MARK: Metal
//     private let device: MTLDevice
//     private let queue: MTLCommandQueue
//     private let pipeline: MTLComputePipelineState

//     // MARK: Buffers
//     private var magBuffer: MTLBuffer
//     private var noiseBuffer: MTLBuffer
//     private var gainBuffer: MTLBuffer
//     private var vadBuffer: MTLBuffer

//     private let fftSize: Int

//     init?(fftSize: Int) {
//         self.fftSize = fftSize

//         guard let device = MTLCreateSystemDefaultDevice(),
//               let queue = device.makeCommandQueue()
//         else { return nil }

//         self.device = device
//         self.queue = queue

//         guard let lib = device.makeDefaultLibrary(),
//               let fn = lib.makeFunction(name: "noiseSuppress"),
//               let pipeline = try? device.makeComputePipelineState(function: fn)
//         else { return nil }

//         self.pipeline = pipeline

//         magBuffer = device.makeBuffer(length: fftSize/2 * MemoryLayout<Float>.size)!
//         noiseBuffer = device.makeBuffer(length: fftSize/2 * MemoryLayout<Float>.size)!
//         gainBuffer = device.makeBuffer(length: fftSize/2 * MemoryLayout<Float>.size)!
//         vadBuffer = device.makeBuffer(length: fftSize/2)!
//     }

//     // MARK: Process
//     func process(mag: [Float],
//                  noise: inout [Float],
//                  gain: inout [Float],
//                  vad: inout [Bool]) {

//         memcpy(magBuffer.contents(), mag, mag.count * 4)
//         memcpy(noiseBuffer.contents(), noise, noise.count * 4)

//         guard let cmd = queue.makeCommandBuffer(),
//               let enc = cmd.makeComputeCommandEncoder()
//         else { return }

//         enc.setComputePipelineState(pipeline)
//         enc.setBuffer(magBuffer, offset: 0, index: 0)
//         enc.setBuffer(noiseBuffer, offset: 0, index: 1)
//         enc.setBuffer(gainBuffer, offset: 0, index: 2)
//         enc.setBuffer(vadBuffer, offset: 0, index: 3)

//         let threads = MTLSize(width: mag.count, height: 1, depth: 1)
//         let grid = MTLSize(width: pipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1)

//         enc.dispatchThreads(threads, threadsPerThreadgroup: grid)
//         enc.endEncoding()

//         cmd.commit()
//         cmd.waitUntilCompleted()

//         memcpy(&gain, gainBuffer.contents(), gain.count * 4)
//         memcpy(&noise, noiseBuffer.contents(), noise.count * 4)

//         let vadPtr = vadBuffer.contents().bindMemory(to: UInt8.self, capacity: mag.count)
//         for i in 0..<mag.count {
//             vad[i] = vadPtr[i] != 0
//         }
//     }
// }