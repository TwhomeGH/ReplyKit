import CoreGraphics
import Foundation

/// 推流幾何的唯一解析規則；ReplayKit 與 ScreenCaptureKit 都應使用同一份結果。
///
/// 語意：
/// - `fixedCanvas`（例如 16:9 政策或錄影畫布）優先，其次才是 OD／AD。
/// - OD 是最終顯示畫布；AD 是中間處理尺寸；兩者必須成對有效。
/// - 90／270 度只轉置「擷取緩衝」與方向，不再次改寫最終 encoder canvas。
enum CaptureStreamRotation: Int, Equatable, Sendable {
    case none = 0
    case left = 90
    case upsideDown = 180
    case right = 270

    var swapsDimensions: Bool {
        self == .left || self == .right
    }

    var orientation: CaptureStreamOrientation {
        swapsDimensions ? .landscape : .portrait
    }

    init(rotateLeft: Bool) {
        self = rotateLeft ? .left : .none
    }
}

enum CaptureStreamOrientation: Equatable, Sendable {
    case portrait
    case landscape
}

struct CaptureStreamGeometry: Equatable, Sendable {
    let encoderSize: CGSize
    let captureBufferSize: CGSize
    let rotatorCanvas: CGSize
    let overlayCanvas: CGSize
    let intermediateSize: CGSize?
    let rotation: CaptureStreamRotation
    let orientation: CaptureStreamOrientation

    /// - Parameters:
    ///   - output: OD，最終顯示畫布。
    ///   - intermediate: AD，GPU 中間處理尺寸。
    ///   - source: 擷取來源尺寸；native 且沒有 OD／AD 時使用。
    ///   - rotation: 顯示方向；只影響擷取緩衝與 mixer orientation。
    ///   - fixedCanvas: 政策固定畫布（優先於 OD／AD）；nil 表示不固定。
    ///   - fallback: 全部尺寸都無效時的最終畫布。
    static func resolve(output: CGSize?, intermediate: CGSize?, source: CGSize?,
                        rotation: CaptureStreamRotation, fixedCanvas: CGSize?,
                        fallback: CGSize) -> CaptureStreamGeometry {
        let fixed = normalized(fixedCanvas)
        let od = normalized(output)
        let ad = normalized(intermediate)
        let sourceSize = normalized(source)
        let fallbackSize = normalized(fallback) ?? CGSize(width: 2, height: 2)

        let base: CGSize
        if let fixed {
            base = fixed
        } else if let od {
            base = od
        } else if let ad {
            base = ad
        } else if let sourceSize {
            base = rotation.swapsDimensions
                ? CGSize(width: sourceSize.height, height: sourceSize.width)
                : sourceSize
        } else {
            base = fallbackSize
        }

        let canvas = normalized(base) ?? fallbackSize
        let capture = rotation.swapsDimensions
            ? CGSize(width: canvas.height, height: canvas.width)
            : canvas

        return CaptureStreamGeometry(
            encoderSize: canvas,
            captureBufferSize: capture,
            rotatorCanvas: canvas,
            overlayCanvas: canvas,
            intermediateSize: ad,
            rotation: rotation,
            orientation: rotation.orientation)
    }

    /// 成對、有限、正數且為偶數；不把單一軸有效誤當成完整尺寸。
    static func normalized(_ size: CGSize?) -> CGSize? {
        guard let size, size.width.isFinite, size.height.isFinite,
              size.width >= 2, size.height >= 2 else { return nil }
        let width = min(8192, max(2, Int(size.width.rounded(.down) / 2) * 2))
        let height = min(8192, max(2, Int(size.height.rounded(.down) / 2) * 2))
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }
}
