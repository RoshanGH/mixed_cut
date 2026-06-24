import Testing
@testable import MixCutCore

@Suite("SpeechRatePlanner 语速对齐")
struct SpeechRatePlannerTests {
    @Test("一次合成已贴合（漂移 < 8%，无偏好）→ 不重合成")
    func withinToleranceNoResynth() {
        let r = SpeechRatePlanner.retargetRate(targetDuration: 6.0, measuredDuration: 6.2, measuredAtRate: 1.0)
        #expect(r == nil) // 6.2 vs 6.0 ≈ 3.3% < 8%
    }

    @Test("音频偏长 → 建议更快的 rate")
    func tooLongFaster() {
        // 6.0s 目标，1.0 rate 下测得 8.0s（偏长 33%）→ 需要 rate ≈ 8/6 ≈ 1.333
        let r = SpeechRatePlanner.retargetRate(targetDuration: 6.0, measuredDuration: 8.0, measuredAtRate: 1.0)
        #expect(r != nil)
        #expect(abs((r ?? 0) - 1.3333) < 0.01)
    }

    @Test("音频偏短 → 建议更慢的 rate")
    func tooShortSlower() {
        // 6.0s 目标，1.0 rate 下测得 4.0s（偏短）→ rate ≈ 4/6 ≈ 0.667
        let r = SpeechRatePlanner.retargetRate(targetDuration: 6.0, measuredDuration: 4.0, measuredAtRate: 1.0)
        #expect(r != nil)
        #expect(abs((r ?? 0) - 0.6667) < 0.01)
    }

    @Test("rate 夹断在 [0.5, 2.0]")
    func clamp() {
        // 目标极短，需要极快 → 夹到 2.0
        let fast = SpeechRatePlanner.retargetRate(targetDuration: 2.0, measuredDuration: 10.0, measuredAtRate: 1.0)
        #expect(fast == 2.0)
        // 目标极长，需要极慢 → 夹到 0.5
        let slow = SpeechRatePlanner.retargetRate(targetDuration: 20.0, measuredDuration: 5.0, measuredAtRate: 1.0)
        #expect(slow == 0.5)
    }

    @Test("语速偏好 bias>1（想更快）→ 期望音频更短，建议更快 rate")
    func biasFaster() {
        // 目标 6.0，bias 1.2 → 期望音频 5.0s；测得 6.0s（@1.0）→ rate ≈ 6/5 = 1.2
        let r = SpeechRatePlanner.retargetRate(targetDuration: 6.0, measuredDuration: 6.0, measuredAtRate: 1.0, bias: 1.2)
        #expect(r != nil)
        #expect(abs((r ?? 0) - 1.2) < 0.02)
    }

    @Test("非法入参 → nil，不崩")
    func invalidInputs() {
        #expect(SpeechRatePlanner.retargetRate(targetDuration: 0, measuredDuration: 5, measuredAtRate: 1) == nil)
        #expect(SpeechRatePlanner.retargetRate(targetDuration: 6, measuredDuration: 0, measuredAtRate: 1) == nil)
        #expect(SpeechRatePlanner.retargetRate(targetDuration: 6, measuredDuration: 5, measuredAtRate: 0) == nil)
    }
}
