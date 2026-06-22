import Foundation

/// 改写台词的字数预算：目标字数 = 时长 × 语速；允许区间 [0.85×目标, 1.0×目标]。
public struct CharBudget: Equatable, Sendable {
    /// 目标字数（= 时长 × 语速，四舍五入）
    public let target: Int
    /// 下限（0.85×目标，四舍五入）
    public let minChars: Int
    /// 上限（= 目标）
    public let maxChars: Int

    public init(target: Int, minChars: Int, maxChars: Int) {
        self.target = target
        self.minChars = minChars
        self.maxChars = maxChars
    }

    /// 由分镜时长与目标语速计算预算。时长或语速非正时返回全 0。
    public static func forDuration(_ seconds: Double, charsPerSecond cps: Double) -> CharBudget {
        guard seconds > 0, cps > 0 else {
            return CharBudget(target: 0, minChars: 0, maxChars: 0)
        }
        let t = seconds * cps
        let maxC = Int(t.rounded())
        let minC = Int((t * 0.85).rounded())
        return CharBudget(target: maxC, minChars: minC, maxChars: maxC)
    }
}
