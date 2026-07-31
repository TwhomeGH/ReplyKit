# Metal Shader 性能優化

## 2026.07.30 三項改進

### 1. 移除 `unsharpY` 死碼

**檔案：** `ReplyKIT/rotateNV12.metal`

`kernel void unsharpY` 已編譯進 Metal library 但 Swift 端從未呼叫。移除後減少 Metal library 編譯時間與 binary size。

相關：`catmullRom1D_uv` helper function 也一併移除（僅被 `bicubicSampleUV_16tap` 使用）。

### 2. Threadgroup 大小最佳化

**檔案：** `ReplyKIT/GPUVideoRotator.swift:884`

```
// 改前
let tgWidth = min(compute.threadExecutionWidth, 32)

// 改後
let tgWidth = compute.threadExecutionWidth
```

舊 code 硬 cap 在 32，在 M 系列 GPU（threadExecutionWidth = 64）上只用了一半 SIMD 頻寬。改為直接使用 GPU 回報的最佳寬度：

| GPU | threadExecutionWidth | 改前 | 改後 |
|-----|---------------------|------|------|
| A14-A17 | 32 | 32 | 32 (不變) |
| M1-M4 | 64 | 32 | 64 |

### 3. UV 平面 16-tap bicubic → 4-tap bilinear 近似

**檔案：** `ReplyKIT/rotateNV12.metal`

#### 改動
- 移除 `bicubicSampleUV_16tap()`（完整 16-tap Catmull-Rom）
- 新增 `bicubicSampleUV_4tap()`（利用 bilinear 硬體逼近 bicubic）
- `rotateNV12_bicubic` kernel 改用 4-tap

#### 原理

NV12 的 UV 平面解析度只有 Y 的 1/4（寬高各半），對它做完整 16-tap Catmull-Rom 的視覺回報極低。Y 平面早已使用相同的 4-tap 手法（`bicubicSampleY_4tap`），UV 比照辦理。

| 指標 | 16-tap | 4-tap |
|------|--------|-------|
| texture sample 次數 | 16 | 4 |
| 乘加運算 | ~80 | ~20 |
| 視覺差異 | baseline | 極小（UV 解析度低） |

#### 效能影響

假設輸出 1080p（1920×1080）：
- UV 平面 thread count = 960 × 540 = 518,400
- 每個 thread 少 12 次 texture sample → 總計每秒減少約 6.2M 次 texture sample（@60fps）
