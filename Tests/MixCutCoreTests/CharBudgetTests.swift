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

    // MARK: - forOriginalLength（下限=原字数不更短，上限 1.15×）

    @Test("原字数 10 → 目标 10，区间 [10,12]")
    func originalLengthNormal() {
        let b = CharBudget.forOriginalLength(10)
        #expect(b.target == 10)
        #expect(b.minChars == 10)  // 不允许比原台词短
        #expect(b.maxChars == 12)  // round(11.5)=12
    }

    @Test("原字数 20 → 区间 [20,23]")
    func originalLengthTwenty() {
        let b = CharBudget.forOriginalLength(20)
        #expect(b.minChars == 20)
        #expect(b.maxChars == 23)  // round(23.0)=23
    }

    @Test("原字数 0（无台词）→ 全 0，不崩")
    func originalLengthZero() {
        let b = CharBudget.forOriginalLength(0)
        #expect(b == CharBudget(target: 0, minChars: 0, maxChars: 0))
    }

    @Test("极短原字数 4 → 上限不小于原字数，下限至少 1")
    func originalLengthShort() {
        let b = CharBudget.forOriginalLength(4)
        #expect(b.target == 4)
        #expect(b.minChars >= 1)
        #expect(b.maxChars >= 4)   // max(原字数, round(4.4)) = 4
    }
}
