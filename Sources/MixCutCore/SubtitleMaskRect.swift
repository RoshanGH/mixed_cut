import Foundation

/// 硬字幕遮挡矩形，归一化坐标（0~1，原点左上），与分辨率无关。
public struct SubtitleMaskRect: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// 9:16 竖屏常见底部字幕带
    public static let defaultBottomBand = SubtitleMaskRect(x: 0.0, y: 0.80, width: 1.0, height: 0.12)

    /// 最小尺寸，避免拖塌缩成 0
    private static let minSize = 0.02

    /// 把矩形钳制进 [0,1] 画面，并保证不出界、不塌缩
    public func clamped() -> SubtitleMaskRect {
        let w = min(max(width, Self.minSize), 1.0)
        let h = min(max(height, Self.minSize), 1.0)
        let cx = min(max(x, 0.0), 1.0 - w)
        let cy = min(max(y, 0.0), 1.0 - h)
        return SubtitleMaskRect(x: cx, y: cy, width: w, height: h)
    }

    /// 上下平移后钳制
    public func movedBy(dy: Double) -> SubtitleMaskRect {
        SubtitleMaskRect(x: x, y: y + dy, width: width, height: height).clamped()
    }

    /// 改高度后钳制（底边不出界）
    public func resizedBy(dHeight: Double) -> SubtitleMaskRect {
        SubtitleMaskRect(x: x, y: y, width: width, height: height + dHeight).clamped()
    }

    /// 换算成像素矩形
    public func pixelRect(width pxW: Double, height pxH: Double)
        -> (x: Double, y: Double, width: Double, height: Double) {
        (x * pxW, y * pxH, width * pxW, height * pxH)
    }
}
