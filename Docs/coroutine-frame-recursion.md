# Swift 協程幀分配器無窮遞迴

## 問題

`VideoFrameProcessor.process()` 對每幀 ReplayKit 畫面建立一個 unstructured `Task { }`。當 GPU 初次編譯 shader 管線時，`MTLComputePipelineState` 內部也使用 Swift async runtime。兩種非同步系統疊加 → Swift runtime 的 `__swift_coroFrameAllocStub` 無窮遞迴 → Stack Overflow。

### 觸發路徑

```
processSampleBuffer (ReplayKit 每幀呼叫, 30-60 fps)
  └─ VideoFrameProcessor.process()
       └─ Task { … }                        ← 每幀建立一個 unstructured Task
            └─ rotator.rotateAsync()
                 └─ ensureMetalResources()
                      └─ buildComputePipeline()
                           └─ makeComputePipelineState(function:)
                                └─ Metal shader 編譯內部 → 產生 async task
                                     └─ __swift_coroFrameAllocStub ← 無窮遞迴！
                                          └─ completeTaskWithClosure
                                               └─ (又回到 Task 建立...)
```

### Crash 特徵

- **例外：** `EXC_BAD_ACCESS / KERN_PROTECTION_FAILURE`（Stack Guard 溢位）
- **錯誤執行緒：** `com.apple.root.user-initiated-qos.cooperative`
- **堆疊深度：** 固定 ~11,162 frames（544KB stack / ~49 bytes per frame）
- **遞迴函式：** `__swift_coroFrameAllocStub`（編譯器產生的 coroutine frame 分配器）
- **Selector 特徵：** `rayscaleFilterWithAmount:` 出現在暫存器中（iOSS 27.0 beta 的 CoreImage internal selector，非本專案定義）
- **發生時機：** 推流啟動後數秒內（首次 Metal pipeline 建立時）

### 與其他遞迴問題的差異

| 類型 | 原因 | 深度 | 觸發時機 |
|------|------|------|----------|
| NWConnection 遞迴 | callback 內同步呼叫 `receive()` | ~11,162 | Socket 大量資料交換 |
| 泛型特化遞迴 | `withUnsafeBytes<UInt32>` 編譯器特化 | ~11,162 | ByteArray 讀取整數 |
| **協程幀遞迴** | **`__swift_coroFrameAllocStub` + `Task { }` 過多** | **~11,162** | **GPU pipeline 初次建立** |

三者都是 **~11,162 frames / 544KB stack** 的相同模式，因為 iOS 的協作執行緒預設 stack 大小為 544KB。

---

## 修復方式

### 根因

`VideoProcess.swift` 原本使用一個 unstructured `Task { }` + `NSLock` 搭配 8 個 inflight slot 來控制處理量：

```swift
// ❌ 危險：每幀建立 Task，與 Metal 的 async 內部機制碰撞
func process(_ sampleBuffer: CMSampleBuffer, oringinaltime: CMSampleTimingInfo) {
    Task { [weak self] in
        guard let self else { return }
        guard self.acquireSlot() else { return }
        defer { self.releaseSlot() }
        // ... 處理每一幀 ...
    }
}
```

### 修正後

將 frame 處理邏輯移入 **actor**，利用 actor 的序列化特性一次處理一幀，超過的直接丟棄：

```swift
// ✅ 安全：actor 序列化，一次只處理一幀
func process(_ sampleBuffer: CMSampleBuffer, oringinaltime: CMSampleTimingInfo) {
    guard let imageBuffer = sampleBuffer.imageBuffer else { return }
    Task { [weak self] in
        guard let self, self.isActive else { return }
        await self.processorActor.processFrame(
            imageBuffer: imageBuffer,
            originalTime: oringinaltime,
            angle: self.angle,
            mediaMixer: self.mediaMixer,
            sendlog: self.sendlog
        )
    }
}
```

actor 內部：

```swift
private actor ProcessorActor {
    private var isProcessing = false

    func processFrame(...) async {
        guard !isProcessing else {
            // 直接丟棄 — 不會進入 Metal pipeline 建立
            return
        }
        isProcessing = true
        defer { isProcessing = false }
        // ... 處理此幀（通過 async suspension points）...
    }
}
```

### 關鍵差異

| 項目 | 修正前 | 修正後 |
|------|--------|--------|
| 並行控制 | `NSLock` + 8 inflight slots | `actor` + `isProcessing` guard |
| 最大 inflight frames | 8 | 1 |
| Task 建立量 | 每幀 1 個 (30-60/s) | 每幀 1 個，但 actor 立即 drop |
| 與 Metal async 交互 | Task 內 Direct Metal pipeline 建立 → 遞迴 | 序列化處理，一次 call path 到底 |
| 丟幀機制 | 超過 8 個才丟 | 前一幀未完成就丟 |

---

## 受影響檔案

| 檔案 | 修改內容 |
|------|----------|
| `ReplyKIT/VideoProcess.swift` | `RotatorManager` actor → `ProcessorActor`，加入 `processFrame()` 與 `isProcessing` guard，移除 `NSLock` 與 inflight slot 邏輯 |
