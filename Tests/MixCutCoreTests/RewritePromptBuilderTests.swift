import Testing
@testable import MixCutCore

@Suite("RewritePromptBuilder")
struct RewritePromptBuilderTests {
    private var sampleInputs: [RewriteSegmentInput] {
        [
            // 原台词 10 字 → forOriginalLength(10) = 区间 10~12
            RewriteSegmentInput(segmentId: "s1", originalText: "补水保湿一整天超划算", durationSeconds: 3.0, keywords: ["补水", "9.9元"]),
            // 原台词 5 字 → forOriginalLength(5) = 区间 5~6
            RewriteSegmentInput(segmentId: "s2", originalText: "限时抢9块", durationSeconds: 2.0, keywords: [])
        ]
    }

    @Test("占位符被替换，风格与分镜清单注入")
    func substitutesPlaceholders() {
        let tpl = "风格：{{STYLE}}\n分镜：\n{{SEGMENTS}}"
        let out = RewritePromptBuilder.build(template: tpl, inputs: sampleInputs, style: "快闪风格")
        #expect(!out.contains("{{STYLE}}"))
        #expect(!out.contains("{{SEGMENTS}}"))
        #expect(out.contains("快闪风格"))
    }

    @Test("每个分镜的 id / 原字数 / 允许区间 / 关键词 / 原台词都进入 prompt")
    func includesPerSegmentFacts() {
        let tpl = "{{SEGMENTS}}"
        let out = RewritePromptBuilder.build(template: tpl, inputs: sampleInputs, style: "x")
        #expect(out.contains("s1"))
        #expect(out.contains("s2"))
        #expect(out.contains("原字数=10字")) // s1 原文 10 字
        #expect(out.contains("10~12字"))     // s1 区间（forOriginalLength）
        #expect(out.contains("原字数=5字"))  // s2 原文 5 字
        #expect(out.contains("5~6字"))       // s2 区间
        #expect(out.contains("补水"))
        #expect(out.contains("9.9元"))
        #expect(out.contains("补水保湿一整天超划算"))
        #expect(out.contains("无")) // s2 无关键词
    }
}
