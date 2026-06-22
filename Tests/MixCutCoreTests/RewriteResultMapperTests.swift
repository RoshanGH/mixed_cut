import Testing
@testable import MixCutCore

@Suite("RewriteResultMapper")
struct RewriteResultMapperTests {
    private var inputs: [RewriteSegmentInput] {
        [
            RewriteSegmentInput(segmentId: "s1", originalText: "原一", durationSeconds: 3.0, keywords: []), // 预算 13~15
            RewriteSegmentInput(segmentId: "s2", originalText: "原二", durationSeconds: 2.0, keywords: [])  // 预算 9~10
        ]
    }

    @Test("全部命中：按输入顺序映射，非回退")
    func fullCoverage() {
        let dto = RewriteResultDTO(segments: [
            .init(segmentId: "s2", rewrittenText: "九个字九个字九个字"),   // 9 字 → 在 9~10 内
            .init(segmentId: "s1", rewrittenText: "十三个字十三个字十三个字甲")  // 13 字 → 在 13~15 内
        ])
        let out = RewriteResultMapper.map(dto: dto, inputs: inputs, charsPerSecond: 5.0)
        #expect(out.map(\.segmentId) == ["s1", "s2"]) // 顺序按 inputs
        #expect(out.allSatisfy { !$0.isFallback })
        #expect(out[0].withinBudget)
        #expect(out[1].withinBudget)
    }

    @Test("漏返回 → 回退原台词并标记 isFallback")
    func missingFallsBack() {
        let dto = RewriteResultDTO(segments: [
            .init(segmentId: "s1", rewrittenText: "十三个字十三个字十三个字甲")
        ])
        let out = RewriteResultMapper.map(dto: dto, inputs: inputs, charsPerSecond: 5.0)
        #expect(out[1].segmentId == "s2")
        #expect(out[1].isFallback)
        #expect(out[1].rewrittenText == "原二")
        #expect(!out[1].withinBudget)
    }

    @Test("返回空白 → 视为漏返回，回退")
    func blankFallsBack() {
        let dto = RewriteResultDTO(segments: [
            .init(segmentId: "s1", rewrittenText: "   "),
            .init(segmentId: "s2", rewrittenText: "九个字九个字九个字")
        ])
        let out = RewriteResultMapper.map(dto: dto, inputs: inputs, charsPerSecond: 5.0)
        #expect(out[0].isFallback)
        #expect(out[0].rewrittenText == "原一")
    }

    @Test("多余 segmentId 被忽略，超预算字数 withinBudget=false")
    func extraIgnoredAndBudget() {
        let dto = RewriteResultDTO(segments: [
            .init(segmentId: "s1", rewrittenText: "这句话太长太长太长太长太长太长了"), // 16 字 → >15 超上限
            .init(segmentId: "s2", rewrittenText: "九个字九个字九个字"),
            .init(segmentId: "ghost", rewrittenText: "不存在")
        ])
        let out = RewriteResultMapper.map(dto: dto, inputs: inputs, charsPerSecond: 5.0)
        #expect(out.count == 2)
        #expect(!out[0].withinBudget) // s1 超上限
        #expect(!out[0].isFallback)   // 但有内容，不算回退
    }
}
