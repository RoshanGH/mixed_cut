import Testing
@testable import MixCutCore

@Suite("SegmentExportExpander")
struct SegmentExportExpanderTests {

    @Test("非锁定分镜：1 原版 + 2 变体，命名正确")
    func nonLockedWithTwoVariants() {
        let src = SegmentExportSource(
            segmentKey: "seg1", sequenceNumber: 2, videoName: "clip", isVoiceLocked: false,
            variants: [VariantRef(dubKey: "a", textVariantIndex: 0),
                       VariantRef(dubKey: "b", textVariantIndex: 1)])
        let out = SegmentExportExpander.expand([src])
        #expect(out.count == 3)
        #expect(out[0].dubKey == nil)
        #expect(out[0].fileName == "2_clip.mp4")
        #expect(out[1].dubKey == "a")
        #expect(out[1].fileName == "2_clip_A.mp4")
        #expect(out[2].dubKey == "b")
        #expect(out[2].fileName == "2_clip_B.mp4")
    }

    @Test("锁定原声分镜：只产原版，忽略变体")
    func lockedProducesOnlyOriginal() {
        let src = SegmentExportSource(
            segmentKey: "s", sequenceNumber: 1, videoName: "v", isVoiceLocked: true,
            variants: [VariantRef(dubKey: "a", textVariantIndex: 0)])
        let out = SegmentExportExpander.expand([src])
        #expect(out.count == 1)
        #expect(out[0].dubKey == nil)
        #expect(out[0].fileName == "1_v.mp4")
    }

    @Test("变体乱序输入按 textVariantIndex 升序产出 A/B")
    func variantsSortedByIndex() {
        let src = SegmentExportSource(
            segmentKey: "s", sequenceNumber: 3, videoName: "v", isVoiceLocked: false,
            variants: [VariantRef(dubKey: "second", textVariantIndex: 1),
                       VariantRef(dubKey: "first", textVariantIndex: 0)])
        let out = SegmentExportExpander.expand([src])
        #expect(out.map(\.fileName) == ["3_v.mp4", "3_v_A.mp4", "3_v_B.mp4"])
        #expect(out[1].dubKey == "first")
        #expect(out[2].dubKey == "second")
    }

    @Test("无变体分镜只产原版")
    func noVariants() {
        let src = SegmentExportSource(
            segmentKey: "s", sequenceNumber: 5, videoName: "v", isVoiceLocked: false, variants: [])
        #expect(SegmentExportExpander.expand([src]).count == 1)
    }

    @Test("字母映射")
    func letterMapping() {
        #expect(SegmentExportExpander.letter(for: 0) == "A")
        #expect(SegmentExportExpander.letter(for: 2) == "C")
        #expect(SegmentExportExpander.letter(for: 26) == "V26")  // 越界回退
    }
}
