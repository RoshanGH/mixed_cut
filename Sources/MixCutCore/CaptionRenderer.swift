import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// 字幕渲染结果：PNG 数据 + 实际像素尺寸（供 CaptionLayout 落位）。
public struct CaptionImage: Equatable, Sendable {
    public let pngData: Data
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(pngData: Data, pixelWidth: Int, pixelHeight: Int) {
        self.pngData = pngData; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }
}

/// 用 macOS 原生（系统苹方字体）把台词渲染成透明 PNG。
/// ⚠️ 必须用 NSBitmapImageRep 显式像素渲染，绝不能用 NSImage.lockFocus（会按 Retina 2× 放大）。
public enum CaptionRenderer {
    public enum RenderError: Error { case contextCreationFailed, pngEncodingFailed, unsupportedPlatform }

    /// - Parameters:
    ///   - text: 台词文本
    ///   - canvasWidth: 画布像素宽（一般取成片宽度的 ~90%）
    ///   - withBackdrop: 是否画半透明圆角底衬（none/blur 模式 true；solid 模式底衬由 ffmpeg 字幕条提供，传 false）
    ///   - fontSize: 字号像素
    public static func render(text: String,
                              canvasWidth: Int,
                              withBackdrop: Bool,
                              fontSize: CGFloat = 56) throws -> CaptionImage {
        #if canImport(AppKit)
        let sidePadding: CGFloat = 28
        let vPadding: CGFloat = 18
        let maxTextWidth = max(1, CGFloat(canvasWidth) - sidePadding * 2)

        let font = NSFont(name: "PingFangSC-Semibold", size: fontSize)
            ?? NSFont.boldSystemFont(ofSize: fontSize)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 4

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black,
            .strokeWidth: -2.0,                 // 负值 = 描边 + 填充
            .paragraphStyle: paragraph,
            .shadow: shadow
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)

        // boundingRect 量真实换行后尺寸（size() 会低估宽度导致裁切）
        let bounds = attributed.boundingRect(
            with: NSSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let textH = ceil(bounds.height)

        let canvasW = canvasWidth
        let canvasH = Int(ceil(textH + vPadding * 2))

        // 显式像素 1:1 bitmap（关键：避免 Retina 2×）
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: canvasW,
            pixelsHigh: canvasH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { throw RenderError.contextCreationFailed }
        rep.size = NSSize(width: canvasW, height: canvasH)   // 1 point = 1 pixel

        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            throw RenderError.contextCreationFailed
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high

        ctx.cgContext.clear(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))  // 透明背景

        if withBackdrop {
            let inset: CGFloat = 6
            let pillRect = NSRect(x: inset, y: inset,
                                  width: CGFloat(canvasW) - inset * 2,
                                  height: CGFloat(canvasH) - inset * 2)
            let pill = NSBezierPath(roundedRect: pillRect, xRadius: 14, yRadius: 14)
            NSColor(white: 0, alpha: 0.55).setFill()
            pill.fill()
        }

        let textRect = NSRect(
            x: sidePadding,
            y: (CGFloat(canvasH) - textH) / 2,
            width: maxTextWidth,
            height: textH
        )
        attributed.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])

        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw RenderError.pngEncodingFailed
        }
        return CaptionImage(pngData: png, pixelWidth: canvasW, pixelHeight: canvasH)
        #else
        throw RenderError.unsupportedPlatform
        #endif
    }

    /// 渲染并写文件，返回尺寸信息。
    @discardableResult
    public static func renderToFile(text: String, canvasWidth: Int, withBackdrop: Bool,
                                    fontSize: CGFloat = 56, to url: URL) throws -> CaptionImage {
        let image = try render(text: text, canvasWidth: canvasWidth, withBackdrop: withBackdrop, fontSize: fontSize)
        try image.pngData.write(to: url)
        return image
    }
}
