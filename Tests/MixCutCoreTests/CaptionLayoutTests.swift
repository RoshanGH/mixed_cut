import Testing
@testable import MixCutCore

@Suite("CaptionLayout")
struct CaptionLayoutTests {
    @Test("PixelRect 归一化换算并钳进画面、取整、最小 2px")
    func pixelRectConversion() {
        let rect = SubtitleMaskRect(x: 0.0, y: 0.80, width: 1.0, height: 0.12)
        let px = PixelRect.from(rect, outputWidth: 1080, outputHeight: 1920)
        #expect(px.x == 0)
        #expect(px.width == 1080)
        #expect(px.y == 1536)            // round(0.80 * 1920)
        #expect(px.height == 230)        // round(0.12 * 1920)
    }

    @Test("满宽遮挡带：水平居中等价于整幅居中")
    func captionCenteredHorizontallyFullWidth() {
        let band = SubtitleMaskRect(x: 0.0, y: 0.80, width: 1.0, height: 0.12)
        let o = CaptionLayout.overlayOrigin(outputWidth: 1080, outputHeight: 1920,
                                            maskRect: band, captionWidth: 600, captionHeight: 100)
        #expect(o.x == 240)              // band.x(0) + (1080 - 600)/2
    }

    @Test("窄偏移遮挡区：水平居中于遮挡区而非整幅画面")
    func captionCenteredHorizontallyInNarrowBand() {
        // 归一化 x=0.2 width=0.5 → 像素 x=216 width=540
        let band = SubtitleMaskRect(x: 0.2, y: 0.80, width: 0.5, height: 0.12)
        let o = CaptionLayout.overlayOrigin(outputWidth: 1080, outputHeight: 1920,
                                            maskRect: band, captionWidth: 300, captionHeight: 100)
        #expect(o.x == 336)              // 216 + (540 - 300)/2，若按整幅居中会是 390
    }

    @Test("字幕竖直居中于字幕带")
    func captionCenteredInBand() {
        let band = SubtitleMaskRect(x: 0.0, y: 0.80, width: 1.0, height: 0.12) // 像素 y=1536 h=230
        let o = CaptionLayout.overlayOrigin(outputWidth: 1080, outputHeight: 1920,
                                            maskRect: band, captionWidth: 600, captionHeight: 100)
        #expect(o.y == 1601)             // 1536 + (230 - 100)/2
    }

    @Test("字幕比画面宽时 x 钳到 0")
    func captionWiderThanFrameClampsX() {
        let band = SubtitleMaskRect.defaultBottomBand
        let o = CaptionLayout.overlayOrigin(outputWidth: 1080, outputHeight: 1920,
                                            maskRect: band, captionWidth: 1200, captionHeight: 100)
        #expect(o.x == 0)
    }
}
