import Testing
import Foundation
#if canImport(AppKit)
import AppKit
#endif
@testable import MixCutCore

@Suite("CaptionRenderer")
struct CaptionRendererTests {
    @Test("渲染出的 PNG 是 1× 像素，宽度等于请求画布（不是 2×）")
    func rendersAtOnePixelScale() throws {
        let img = try CaptionRenderer.render(text: "测试字幕一二三四五", canvasWidth: 900, withBackdrop: true)
        #expect(img.pixelWidth == 900)               // 关键：不是 1800
        #expect(img.pixelHeight > 0)
        #expect(img.pixelHeight < 600)
        #expect(!img.pngData.isEmpty)
        #if canImport(AppKit)
        let rep = NSBitmapImageRep(data: img.pngData)
        #expect(rep != nil)
        #expect(rep?.pixelsWide == 900)              // PNG 解码后仍 1×
        #endif
    }

    @Test("无底衬模式同样产出 1× PNG")
    func rendersWithoutBackdrop() throws {
        let img = try CaptionRenderer.render(text: "纯色条上的字幕", canvasWidth: 720, withBackdrop: false)
        #expect(img.pixelWidth == 720)
        #expect(!img.pngData.isEmpty)
    }

    @Test("写文件成功且文件非空")
    func renderToFileWritesPNG() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cap_test.png")
        try? FileManager.default.removeItem(at: url)
        let img = try CaptionRenderer.renderToFile(text: "落盘测试", canvasWidth: 600, withBackdrop: true, to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(img.pixelWidth == 600)
        try? FileManager.default.removeItem(at: url)
    }
}
