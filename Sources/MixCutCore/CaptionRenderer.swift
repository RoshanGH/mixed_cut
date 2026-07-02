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

    /// 烧录字幕预处理：把中英文标点替换为空格并合并多余空白（短视频字幕风格，
    /// 既符合观感也利于换行）。全角/半角标点、全角空格统一处理。
    public static func stripPunctuation(_ text: String) -> String {
        // 恒定转空格的标点（中文标点、括号、引号、感叹问号等）
        let alwaysPunct: Set<Character> = [
            "，", "。", "、", "！", "？", "；", "：", "“", "”", "‘", "’",
            "「", "」", "『", "』", "（", "）", "【", "】", "《", "》", "〈", "〉",
            "…", "—", "～", "·", "・", "\u{3000}",
            "!", "?", ";", "\"", "'", "(", ")", "[", "]", "{", "}", "<", ">", "~"
        ]
        // 半角 . , : 是数字内部分隔符（9.9元 / 1,000 / 8:00）——前后都是数字时保留，
        // 否则视为标点转空格。避免破坏广告里的价格/折扣/时间等数字卖点。
        let numericSeparators: Set<Character> = [".", ",", ":"]

        let chars = Array(text)
        func isASCIIDigit(_ i: Int) -> Bool {
            guard i >= 0, i < chars.count else { return false }
            return chars[i].isNumber && chars[i].isASCII
        }

        var mapped: [Character] = []
        mapped.reserveCapacity(chars.count)
        for (i, c) in chars.enumerated() {
            if alwaysPunct.contains(c) {
                mapped.append(" ")
            } else if numericSeparators.contains(c) {
                mapped.append(isASCIIDigit(i - 1) && isASCIIDigit(i + 1) ? c : " ")
            } else {
                mapped.append(c)
            }
        }
        // 合并连续空白为单个空格并去首尾
        return String(mapped)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .joined(separator: " ")
    }

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
        // 垂直留白随字号放大，保证贴字底衬胶囊上下不被裁切
        let vPadding: CGFloat = max(18, fontSize * 0.20)
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
            // 贴字圆角胶囊（与分镜卡片预览一致：padding≈字号比例、opacity 0.5、圆角≈字号 0.25），
            // 非通栏满宽，保证「预览=成片」。多行时以最宽行为准。
            let padX = fontSize * 0.35
            let padY = fontSize * 0.18
            let textW = ceil(bounds.width)
            let pillW = min(CGFloat(canvasW), textW + padX * 2)
            let pillH = min(CGFloat(canvasH), textH + padY * 2)
            let pillRect = NSRect(x: (CGFloat(canvasW) - pillW) / 2,
                                  y: (CGFloat(canvasH) - pillH) / 2,
                                  width: pillW, height: pillH)
            let radius = min(fontSize * 0.25, pillH / 2)
            let pill = NSBezierPath(roundedRect: pillRect, xRadius: radius, yRadius: radius)
            NSColor(white: 0, alpha: 0.5).setFill()
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
