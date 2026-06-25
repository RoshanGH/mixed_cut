import Foundation

/// 把改写输入拼成可发送给 AI 的 prompt。模板里 {{STYLE}} / {{SEGMENTS}} 为占位符。
public enum RewritePromptBuilder {
    public static func build(template: String,
                             inputs: [RewriteSegmentInput],
                             style: String) -> String {
        let segmentLines = inputs.map { input -> String in
            let origCount = input.originalText.count
            let budget = CharBudget.forOriginalLength(origCount)
            let kw = input.keywords.isEmpty ? "无" : input.keywords.joined(separator: "、")
            let dur = String(format: "%.2f", input.durationSeconds)
            return "- segmentId=\(input.segmentId) | 原字数=\(origCount)字（目标≈\(origCount)字，允许 \(budget.minChars)~\(budget.maxChars)字，与原台词字数相当即可，配音会自动加速对齐到画面）| 时长=\(dur)s | 必须保留关键事实=\(kw) | 原台词：\(input.originalText)"
        }.joined(separator: "\n")

        return template
            .replacingOccurrences(of: "{{STYLE}}", with: style)
            .replacingOccurrences(of: "{{SEGMENTS}}", with: segmentLines)
    }
}
