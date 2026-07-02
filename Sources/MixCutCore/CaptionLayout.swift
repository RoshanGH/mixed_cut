import Foundation

/// 整数像素矩形（ffmpeg crop/drawbox/overlay 需要整数坐标）。
public struct PixelRect: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// 归一化矩形 → 像素并取整：宽高至少 2px，整体钳进画面不出界。
    public static func from(_ rect: SubtitleMaskRect, outputWidth: Int, outputHeight: Int) -> PixelRect {
        let p = rect.clamped().pixelRect(width: Double(outputWidth), height: Double(outputHeight))
        var w = Int(p.width.rounded())
        var h = Int(p.height.rounded())
        w = max(2, min(w, outputWidth))
        h = max(2, min(h, outputHeight))
        var x = Int(p.x.rounded())
        var y = Int(p.y.rounded())
        x = max(0, min(x, outputWidth - w))
        y = max(0, min(y, outputHeight - h))
        return PixelRect(x: x, y: y, width: w, height: h)
    }
}

/// 字幕 PNG 在成片画面里的像素落位（纯数学）。
public enum CaptionLayout {
    /// 计算字幕 PNG 的 overlay 原点（左上角像素）。水平、竖直均居中于 maskRect 遮挡带
    /// （字幕永远落在遮挡区正中）；最后钳进画面避免出界。
    public static func overlayOrigin(outputWidth: Int, outputHeight: Int,
                                     maskRect: SubtitleMaskRect,
                                     captionWidth: Int, captionHeight: Int) -> (x: Int, y: Int) {
        let band = PixelRect.from(maskRect, outputWidth: outputWidth, outputHeight: outputHeight)
        let rawX = Double(band.x) + (Double(band.width) - Double(captionWidth)) / 2.0
        let rawY = Double(band.y) + (Double(band.height) - Double(captionHeight)) / 2.0
        let maxX = Double(max(0, outputWidth - captionWidth))
        let maxY = Double(max(0, outputHeight - captionHeight))
        let x = Int(min(max(rawX, 0), maxX).rounded())
        let y = Int(min(max(rawY, 0), maxY).rounded())
        return (x, y)
    }
}
