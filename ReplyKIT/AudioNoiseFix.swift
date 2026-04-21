import CoreML


func loadRemoteModel(from url: URL) throws -> MLModel {
    // 下載模型檔案到本地暫存路徑
    let data = try Data(contentsOf: url)
    let tempUrl = FileManager.default.temporaryDirectory.appendingPathComponent("MyDenoiseModel.mlmodel")
    try data.write(to: tempUrl)

    // 編譯模型
    let compiledUrl = try MLModel.compileModel(at: tempUrl)

    // 載入模型
    let model = try MLModel(contentsOf: compiledUrl)
    return model
}


final class DenoiseModelWrapper {
    private let model: MyDenoiseModel

    init?() {
        guard let m = try? MyDenoiseModel(configuration: MLModelConfiguration()) else {
            return nil
        }
        self.model = m
    }

    func predict(samples: [Float]) -> [Float]? {
        guard let mlArray = try? MLMultiArray(shape: [NSNumber(value: samples.count)], dataType: .float32) else {
            return nil
        }
        for i in 0..<samples.count {
            mlArray[i] = NSNumber(value: samples[i])
        }

        guard let output = try? model.prediction(input: mlArray),
              let denoisedArray = output.output else {
            return nil
        }

        return (0..<samples.count).map { denoisedArray[$0].floatValue }
    }



}

private func denoiseWithCoreML(_ buffer: CMSampleBuffer) -> CMSampleBuffer {
    guard let model = try? MyDenoiseModel(configuration: MLModelConfiguration()) else {
        return buffer
    }

    // 取出 PCM 資料
    guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { return buffer }
    var length = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    guard CMBlockBufferGetDataPointer(blockBuffer,
                                      atOffset: 0,
                                      lengthAtOffsetOut: &length,
                                      totalLengthOut: &length,
                                      dataPointerOut: &dataPointer) == noErr,
          let ptr = dataPointer else { return buffer }

    let sampleCount = length / MemoryLayout<Float>.size
    let floatPtr = UnsafeMutablePointer<Float>(OpaquePointer(ptr))
    let samples = Array(UnsafeBufferPointer(start: floatPtr, count: sampleCount))

    // 包裝成 MLMultiArray
    guard let mlArray = try? MLMultiArray(shape: [NSNumber(value: sampleCount)], dataType: .float32) else {
        return buffer
    }
    for i in 0..<sampleCount {
        mlArray[i] = NSNumber(value: samples[i])
    }

    // 推論
    guard let output = try? model.prediction(input: mlArray),
          let denoisedArray = output.output else {
        return buffer
    }

    // 寫回 buffer
    for i in 0..<sampleCount {
        floatPtr[i] = denoisedArray[i].floatValue
    }

    return buffer
}
