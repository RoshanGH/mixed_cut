import Testing
@testable import MixCutCore

@Suite("RewriteResultMapper")
struct RewriteResultMapperTests {
    // 原台词用重复字精确控制字数（下限=原字数，上限 1.15×）：
    // s1 = 13 字 → forOriginalLength(13) = 区间 13~15
    // s2 = 9 字  → forOriginalLength(9)  = 区间 9~10
    private let origS1 = String(repeating: "原", count: 13)
    private let origS2 = String(repeating: "二", count: 9)

    private var inputs: [RewriteSegmentInput] {
        [
            RewriteSegmentInput(segmentId: "s1", originalText: origS1, durationSeconds: 3.0, keywords: []),
            RewriteSegmentInput(segmentId: "s2", originalText: origS2, durationSeconds: 2.0, keywords: [])
        ]
    }

    @Test("全部命中：按输入顺序映射，非回退，字数在区间内")
    func fullCoverage() {
        let dto = RewriteResultDTO(segments: [
            .init(segmentId: "s2", rewrittenText: String(repeating: "乙", count: 9)),   // 9 字 → 8~10 内
            .init(segmentId: "s1", rewrittenText: String(repeating: "甲", count: 13))   // 13 字 → 12~14 内
        ])
        let out = RewriteResultMapper.map(dto: dto, inputs: inputs)
        #expect(out.map(\.segmentId) == ["s1", "s2"]) // 顺序按 inputs
        #expect(out.allSatisfy { !$0.isFallback })
        #expect(out[0].withinBudget)
        #expect(out[1].withinBudget)
    }

    @Test("漏返回 → 回退原台词并标记 isFallback")
    func missingFallsBack() {
        let dto = RewriteResultDTO(segments: [
            .init(segmentId: "s1", rewrittenText: String(repeating: "甲", count: 13))
        ])
        let out = RewriteResultMapper.map(dto: dto, inputs: inputs)
        #expect(out[1].segmentId == "s2")
        #expect(out[1].isFallback)
        #expect(out[1].rewrittenText == origS2)
        #expect(!out[1].withinBudget)
    }

    @Test("返回空白 → 视为漏返回，回退")
    func blankFallsBack() {
        let dto = RewriteResultDTO(segments: [
            .init(segmentId: "s1", rewrittenText: "   "),
            .init(segmentId: "s2", rewrittenText: String(repeating: "乙", count: 9))
        ])
        let out = RewriteResultMapper.map(dto: dto, inputs: inputs)
        #expect(out[0].isFallback)
        #expect(out[0].rewrittenText == origS1)
    }

    @Test("多余 segmentId 被忽略，超原字数区间 withinBudget=false")
    func extraIgnoredAndBudget() {
        let dto = RewriteResultDTO(segments: [
            .init(segmentId: "s1", rewrittenText: String(repeating: "丙", count: 16)), // 16 字 → >14 超上限
            .init(segmentId: "s2", rewrittenText: String(repeating: "乙", count: 9)),
            .init(segmentId: "ghost", rewrittenText: "不存在")
        ])
        let out = RewriteResultMapper.map(dto: dto, inputs: inputs)
        #expect(out.count == 2)
        #expect(!out[0].withinBudget) // s1 超上限
        #expect(!out[0].isFallback)   // 但有内容，不算回退
    }
}
