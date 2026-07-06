import Testing
@testable import MixCutCore

struct FrameCountAlignerTests {
    @Test("变体帧数多于目标 → trim 掉尾部多余帧")
    func trimsExtra() {
        let plan = FrameCountAligner.plan(actualFrames: 97, targetFrames: 90)
        #expect(plan == .trim(dropTrailing: 7))
    }

    @Test("变体帧数少于目标 → pad 重复末帧补齐")
    func padsShort() {
        let plan = FrameCountAligner.plan(actualFrames: 88, targetFrames: 90)
        #expect(plan == .pad(repeatLast: 2))
    }

    @Test("帧数正好 → 无需处理")
    func exact() {
        #expect(FrameCountAligner.plan(actualFrames: 90, targetFrames: 90) == .none)
    }
}
