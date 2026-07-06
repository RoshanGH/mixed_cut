import Testing
@testable import MixCutCore

@Suite("SegmentExportExpander")
struct SegmentExportExpanderTests {
    private func src(_ locked: Bool, _ orig: Bool, _ variants: [VariantRef], seq: Int = 1, name: String = "v") -> SegmentExportSource {
        SegmentExportSource(segmentKey: "s\(seq)", sequenceNumber: seq, videoName: name,
                            isVoiceLocked: locked, includeOriginal: orig, variants: variants)
    }
    private let a = VariantRef(dubKey: "a", textVariantIndex: 0)
    private let b = VariantRef(dubKey: "b", textVariantIndex: 1)

    @Test("原版参与 + 2 变体 → 3 条，命名正确")
    func originalPlusTwo() {
        let out = SegmentExportExpander.expand([src(false, true, [a, b], seq: 2, name: "clip")])
        #expect(out.map(\.fileName) == ["2_clip.mp4", "2_clip_A.mp4", "2_clip_B.mp4"])
        #expect(out.map(\.dubKey) == [nil, "a", "b"])
    }

    @Test("仅变体不含原版 → 只出变体")
    func variantsOnly() {
        let out = SegmentExportExpander.expand([src(false, false, [a, b])])
        #expect(out.map(\.dubKey) == ["a", "b"])
        #expect(out.allSatisfy { $0.dubKey != nil })
    }

    @Test("不含原版且无变体 → 兜底仅原版")
    func fallbackOriginal() {
        let out = SegmentExportExpander.expand([src(false, false, [])])
        #expect(out.count == 1)
        #expect(out[0].dubKey == nil)
    }

    @Test("锁定 → 仅原版，忽略 includeOriginal/变体")
    func lockedOnlyOriginal() {
        let out = SegmentExportExpander.expand([src(true, false, [a])])
        #expect(out.count == 1)
        #expect(out[0].dubKey == nil)
    }

    @Test("变体乱序按 textVariantIndex 升序产出 A/B")
    func sorted() {
        let out = SegmentExportExpander.expand([src(false, true,
            [VariantRef(dubKey: "second", textVariantIndex: 1),
             VariantRef(dubKey: "first", textVariantIndex: 0)], seq: 3)])
        #expect(out.map(\.fileName) == ["3_v.mp4", "3_v_A.mp4", "3_v_B.mp4"])
        #expect(out.map(\.dubKey) == [nil, "first", "second"])
    }

    @Test("字母映射") func letterMapping() {
        #expect(SegmentExportExpander.letter(for: 0) == "A")
        #expect(SegmentExportExpander.letter(for: 26) == "V26")
    }
}
