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

    @Test("过长，atempo 封顶 1.15 仍超 → 定格补帧兜底")
    func tooLongFreezePad() {
        let p = AudioAligner.plan(targetDuration: 3.5, audioDuration: 5.0, fps: 30)
        #expect(p.atempoFactor == 1.15)
        // 变速后 5.0/1.15=4.3478，残差 0.8478 → round(0.8478×30)=25 帧
        #expect(p.freezePadFrames == 25)
        #expect(p.trailingSilence == 0)
    }

    @Test("过短，atempo 封底 0.8 仍短 → 末尾留静音")
    func tooShortSilence() {
        let p = AudioAligner.plan(targetDuration: 5.0, audioDuration: 3.0, fps: 30)
        #expect(p.atempoFactor == 0.8)
        // 变速后 3.0/0.8=3.75，残差 -1.25 → 留静音 1.25
        #expect(p.freezePadFrames == 0)
        #expect(approx(p.trailingSilence, 1.25))
    }

    @Test("14% 偏短(克隆常见) → atempo 在区间内拉满，无空挡")
    func shortFilledByWiderAtempo() {
        // 原 7.3s 画面、配音 6.3s（约短 14%）：raw=6.3/7.3=0.863 ∈ [0.8,1.15] → 拉满无静音
        let p = AudioAligner.plan(targetDuration: 7.3, audioDuration: 6.3, fps: 30)
        #expect(approx(p.atempoFactor, 0.863))
        #expect(p.freezePadFrames == 0)
        #expect(approx(p.trailingSilence, 0))   // 旧的 0.9 封底会留 ~0.7s 空挡，现已消除
    }

    @Test("非法输入 → 安全默认")
    func guards() {
        let p = AudioAligner.plan(targetDuration: 0, audioDuration: 3, fps: 30)
        #expect(p == AlignmentPlan(atempoFactor: 1.0, freezePadFrames: 0, trailingSilence: 0))
    }
}
