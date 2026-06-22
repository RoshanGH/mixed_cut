import Testing
@testable import MixCutCore

@Test("默认底部带状区位置正确")
func defaultBottomBand() {
    let r = SubtitleMaskRect.defaultBottomBand
    #expect(r.x == 0.0)
    #expect(r.y == 0.80)
    #expect(r.width == 1.0)
    #expect(r.height == 0.12)
}

@Test("clamped 把越界分量拉回画面内")
func clampedKeepsInside() {
    let r = SubtitleMaskRect(x: -0.2, y: 0.95, width: 1.5, height: 0.3).clamped()
    #expect(r.x >= 0.0 && r.x <= 1.0)
    #expect(r.y >= 0.0 && r.y <= 1.0)
    #expect(r.x + r.width <= 1.0 + 1e-9)
    #expect(r.y + r.height <= 1.0 + 1e-9)
}

@Test("clamped 保证最小高度不塌缩")
func clampedMinHeight() {
    let r = SubtitleMaskRect(x: 0, y: 0.5, width: 1.0, height: 0.0).clamped()
    #expect(r.height >= 0.02)
}

@Test("movedBy 平移后仍在画面内")
func movedByClamps() {
    let r = SubtitleMaskRect.defaultBottomBand.movedBy(dy: 0.5)
    #expect(r.y + r.height <= 1.0 + 1e-9)
}

@Test("resizedBy 增高后底边不出界")
func resizedByClamps() {
    let r = SubtitleMaskRect(x: 0, y: 0.9, width: 1, height: 0.05).resizedBy(dHeight: 0.5)
    #expect(r.y + r.height <= 1.0 + 1e-9)
}

@Test("pixelRect 按画面尺寸换算")
func pixelRectScales() {
    let p = SubtitleMaskRect(x: 0.1, y: 0.5, width: 0.8, height: 0.1)
        .pixelRect(width: 1080, height: 1920)
    #expect(p.x == 108)
    #expect(p.y == 960)
    #expect(p.width == 864)
    #expect(abs(p.height - 192) < 1e-6)
}
