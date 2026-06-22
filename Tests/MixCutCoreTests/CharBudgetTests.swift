import Testing
@testable import MixCutCore

@Suite("CharBudget 字数预算")
struct CharBudgetTests {
    @Test("目标=时长×语速，下限=0.85×目标（四舍五入）")
    func normalBudget() {
        let b = CharBudget.forDuration(3.0, charsPerSecond: 5.0) // 目标 15，下限 round(12.75)=13
        #expect(b.target == 15)
        #expect(b.maxChars == 15)
        #expect(b.minChars == 13)
    }

    @Test("时长为 0 → 全 0")
    func zeroDuration() {
        let b = CharBudget.forDuration(0, charsPerSecond: 5.0)
        #expect(b == CharBudget(target: 0, minChars: 0, maxChars: 0))
    }

    @Test("语速非正 → 全 0，不崩")
    func nonPositiveRate() {
        let b = CharBudget.forDuration(3.0, charsPerSecond: 0)
        #expect(b == CharBudget(target: 0, minChars: 0, maxChars: 0))
    }

    @Test("四舍五入：2.0s × 5 = 10，下限 round(8.5)=9")
    func rounding() {
        let b = CharBudget.forDuration(2.0, charsPerSecond: 5.0)
        #expect(b.maxChars == 10)
        #expect(b.minChars == 9)
    }
}
