import Testing
@testable import MixCutCore

@Suite("RewritePromptBuilder")
struct RewritePromptBuilderTests {
    private var sampleInputs: [RewriteSegmentInput] {
        [
            RewriteSegmentInput(segmentId: "s1", originalText: "原台词一", durationSeconds: 3.0, keywords: ["补水", "9.9元"]),
            RewriteSegmentInput(segmentId: "s2", originalText: "原台词二", durationSeconds: 2.0, keywords: [])
        ]
    }

    @Test("占位符被替换，风格与分镜清单注入")
    func substitutesPlaceholders() {
        let tpl = "风格：{{STYLE}}\n分镜：\n{{SEGMENTS}}"
        let out = RewritePromptBuilder.build(template: tpl, inputs: sampleInputs, style: "快闪风格", charsPerSecond: 5.0)
        #expect(!out.contains("{{STYLE}}"))
        #expect(!out.contains("{{SEGMENTS}}"))
        #expect(out.contains("快闪风格"))
    }

    @Test("每个分镜的 id / 字数预算 / 关键词 / 原台词都进入 prompt")
    func includesPerSegmentFacts() {
        let tpl = "{{SEGMENTS}}"
        let out = RewritePromptBuilder.build(template: tpl, inputs: sampleInputs, style: "x", charsPerSecond: 5.0)
        #expect(out.contains("s1"))
        #expect(out.contains("s2"))
        #expect(out.contains("13~15")) // s1: 3.0×5=15，下限 round(12.75)=13
        #expect(out.contains("9~10"))  // s2: 2.0×5=10，下限 round(8.5)=9
        #expect(out.contains("补水"))
        #expect(out.contains("9.9元"))
        #expect(out.contains("原台词一"))
        #expect(out.contains("无")) // s2 无关键词
    }
}
