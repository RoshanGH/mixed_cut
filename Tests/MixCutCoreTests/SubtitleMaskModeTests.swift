import Testing
@testable import MixCutCore

@Suite("SubtitleMaskMode")
struct SubtitleMaskModeTests {
    @Test("无硬字幕 → none，忽略 style")
    func noHardSubtitleIsNone() {
        #expect(SubtitleMaskMode.from(hasHardSubtitle: false, maskStyleRaw: "solid") == .none)
        #expect(SubtitleMaskMode.from(hasHardSubtitle: false, maskStyleRaw: "blur") == .none)
    }

    @Test("有硬字幕 → 按 style 映射")
    func mapsKnownStyles() {
        #expect(SubtitleMaskMode.from(hasHardSubtitle: true, maskStyleRaw: "blur") == .blur)
        #expect(SubtitleMaskMode.from(hasHardSubtitle: true, maskStyleRaw: "solid") == .solid)
        #expect(SubtitleMaskMode.from(hasHardSubtitle: true, maskStyleRaw: "dim") == .dim)
    }

    @Test("未知 style 退回 blur")
    func unknownStyleFallsBackToBlur() {
        #expect(SubtitleMaskMode.from(hasHardSubtitle: true, maskStyleRaw: "wat") == .blur)
        #expect(SubtitleMaskMode.from(hasHardSubtitle: true, maskStyleRaw: "") == .blur)
    }
}
