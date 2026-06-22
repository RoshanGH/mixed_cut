import Foundation
import Testing
@testable import MixCutCore

@Suite("Rewrite 数据类型")
struct RewriteTypesTests {
    @Test("RewriteResultDTO 可从 AI 风格 JSON 解码")
    func decodeDTO() throws {
        let json = """
        {"segments":[{"segmentId":"s1","rewrittenText":"全新文案一"},{"segmentId":"s2","rewrittenText":"全新文案二"}]}
        """.data(using: .utf8)!
        let dto = try JSONDecoder().decode(RewriteResultDTO.self, from: json)
        #expect(dto.segments.count == 2)
        #expect(dto.segments[0].segmentId == "s1")
        #expect(dto.segments[1].rewrittenText == "全新文案二")
    }

    @Test("输入/输出值语义相等")
    func valueEquality() {
        let a = RewriteSegmentInput(segmentId: "s1", originalText: "原文", durationSeconds: 2.0, keywords: ["A"])
        let b = RewriteSegmentInput(segmentId: "s1", originalText: "原文", durationSeconds: 2.0, keywords: ["A"])
        #expect(a == b)
        let r = RewrittenSegment(segmentId: "s1", rewrittenText: "新", isFallback: false, withinBudget: true)
        #expect(r.segmentId == "s1")
        #expect(r.withinBudget)
    }
}
