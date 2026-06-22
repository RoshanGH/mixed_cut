import Testing
@testable import MixCutCore

@Suite("AudioAligner 对齐阶梯")
struct AlignmentPlanTests {
    private func approx(_ a: Double, _ b: Double, _ tol: Double = 0.02) -> Bool { abs(a - b) < tol }

    @Test("完全相等 → 不变速、不补帧、不留静音")
    func exact() {
        let p = AudioAligner.plan(targetDuration: 3.5, audioDuration: 3.5, fps: 30)
        #expect(p.atempoFactor == 1.0)
        #expect(p.freezePadFrames == 0)
        #expect(p.trailingSilence == 0)
    }

    @Test("微长(≤0.15s) → 不变速，末尾定格补帧")
    func slightlyLonger() {
        let p = AudioAligner.plan(targetDuration: 3.5, audioDuration: 3.6, fps: 30)
        #expect(p.atempoFactor == 1.0)
        #expect(p.freezePadFrames == 3) // round(0.1×30)
        #expect(p.trailingSilence == 0)
    }

    @Test("微短(≤0.15s) → 不变速，末尾留静音")
    func slightlyShorter() {
        let p = AudioAligner.plan(targetDuration: 3.5, audioDuration: 3.4, fps: 30)
        #expect(p.atempoFactor == 1.0)
        #expect(p.freezePadFrames == 0)
        #expect(approx(p.trailingSilence, 0.1))
    }

    @Test("中等偏长，atempo 区间内吸收 → 变速到位，无补帧无静音")
    func atempoAbsorbs() {
        let p = AudioAligner.plan(targetDuration: 3.5, audioDuration: 3.76, fps: 30)
        // raw = 3.76/3.5 = 1.074 ∈ [0.9,1.1]
        #expect(approx(p.atempoFactor, 1.074))
        #expect(p.freezePadFrames == 0)
        #expect(approx(p.trailingSilence, 0))
    }

    @Test("过长，atempo 封顶 1.1 仍超 → 定格补帧兜底")
    func tooLongFreezePad() {
        let p = AudioAligner.plan(targetDuration: 3.5, audioDuration: 5.0, fps: 30)
        #expect(p.atempoFactor == 1.1)
        // 变速后 5.0/1.1=4.545，残差 1.045 → round(1.045×30)=31 帧
        #expect(p.freezePadFrames == 31)
        #expect(p.trailingSilence == 0)
    }

    @Test("过短，atempo 封底 0.9 仍短 → 末尾留静音")
    func tooShortSilence() {
        let p = AudioAligner.plan(targetDuration: 5.0, audioDuration: 3.0, fps: 30)
        #expect(p.atempoFactor == 0.9)
        // 变速后 3.0/0.9=3.333，残差 -1.667 → 留静音 1.667
        #expect(p.freezePadFrames == 0)
        #expect(approx(p.trailingSilence, 1.667))
    }

    @Test("非法输入 → 安全默认")
    func guards() {
        let p = AudioAligner.plan(targetDuration: 0, audioDuration: 3, fps: 30)
        #expect(p == AlignmentPlan(atempoFactor: 1.0, freezePadFrames: 0, trailingSilence: 0))
    }
}
