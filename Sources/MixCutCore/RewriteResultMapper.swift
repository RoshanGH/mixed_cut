import Foundation

/// 把 AI 返回的 DTO 按输入分镜映射成结果：保序、漏返回回退原文、超预算标记。
public enum RewriteResultMapper {
    public static func map(dto: RewriteResultDTO,
                           inputs: [RewriteSegmentInput],
                           charsPerSecond cps: Double) -> [RewrittenSegment] {
        // segmentId → 改写文本（重复 id 取首个）
        var byId: [String: String] = [:]
        for item in dto.segments where byId[item.segmentId] == nil {
            byId[item.segmentId] = item.rewrittenText
        }

        return inputs.map { input in
            let budget = CharBudget.forDuration(input.durationSeconds, charsPerSecond: cps)
            let raw = byId[input.segmentId]
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if !trimmed.isEmpty {
                let count = trimmed.count
                let within = count >= budget.minChars && count <= budget.maxChars
                return RewrittenSegment(segmentId: input.segmentId,
                                        rewrittenText: trimmed,
                                        isFallback: false,
                                        withinBudget: within)
            } else {
                // 漏返回或空白 → 回退原台词
                return RewrittenSegment(segmentId: input.segmentId,
                                        rewrittenText: input.originalText,
                                        isFallback: true,
                                        withinBudget: false)
            }
        }
    }
}
