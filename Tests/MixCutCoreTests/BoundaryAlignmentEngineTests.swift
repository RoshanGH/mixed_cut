import Testing
@testable import MixCutCore

/// 边界对齐引擎测试
///
/// 覆盖核心诉求：边缘画面突变大 → 吸附到切镜点；画面平缓 → 保留语义切点。
/// 以及安全约束（限幅/递增/最小时长）、按帧量化。
struct BoundaryAlignmentEngineTests {

    // 默认 fps 设大一点（100），让量化几乎不影响断言里的精确小数；
    // 单独的量化测试用真实 fps。
    private let cfg = BoundaryAlignConfig()

    // MARK: - 强切镜优先

    @Test("强切镜在搜索窗内 → 吸附到切镜点")
    func snapsToStrongSceneCut() {
        let result = BoundaryAlignmentEngine.align(
            boundaries: [5.0],
            scenes: [SceneCut(time: 5.2, strength: 0.8)],
            silences: [],
            sentences: [],
            duration: 100, fps: 100
        )
        #expect(abs(result[0] - 5.2) < 0.01)
    }

    @Test("弱画面变化（强度低于阈值）→ 不吸附，保留语义切点")
    func weakSceneDoesNotSnap() {
        let result = BoundaryAlignmentEngine.decide(
            boundaries: [5.0],
            scenes: [SceneCut(time: 5.2, strength: 0.2)], // < 0.4 阈值
            silences: [],
            sentences: [],
            duration: 100, fps: 100
        )
        #expect(result[0].anchor == .original)
        #expect(abs(result[0].aligned - 5.0) < 0.01)
    }

    @Test("强切镜超出搜索窗 → 不吸附")
    func strongSceneOutOfRangeDoesNotSnap() {
        let result = BoundaryAlignmentEngine.decide(
            boundaries: [5.0],
            scenes: [SceneCut(time: 6.0, strength: 0.9)], // 距离 1.0s > 0.5s 窗
            silences: [],
            sentences: [],
            duration: 100, fps: 100
        )
        #expect(result[0].anchor != .scene)
    }

    @Test("多个强切镜 → 吸附到最近的那个")
    func snapsToNearestStrongScene() {
        let result = BoundaryAlignmentEngine.align(
            boundaries: [5.0],
            scenes: [
                SceneCut(time: 4.7, strength: 0.6),
                SceneCut(time: 5.3, strength: 0.9),
            ],
            silences: [],
            sentences: [],
            duration: 100, fps: 100
        )
        #expect(abs(result[0] - 4.7) < 0.01) // 4.7 距 5.0 更近
    }

    // MARK: - 优先级

    @Test("强切镜优先于句子结束")
    func sceneBeatsSentence() {
        let result = BoundaryAlignmentEngine.decide(
            boundaries: [5.0],
            scenes: [SceneCut(time: 5.15, strength: 0.7)],
            silences: [],
            sentences: [SentenceSpan(start: 3.0, end: 4.9)],
            duration: 100, fps: 100
        )
        #expect(result[0].anchor == .scene)
    }

    @Test("无强切镜时吸附到句子结束")
    func snapsToSentenceEndWhenNoScene() {
        let result = BoundaryAlignmentEngine.decide(
            boundaries: [5.0],
            scenes: [],
            silences: [],
            sentences: [SentenceSpan(start: 3.0, end: 4.85)],
            duration: 100, fps: 100
        )
        #expect(result[0].anchor == .sentence)
        #expect(abs(result[0].aligned - 4.85) < 0.01)
    }

    @Test("句子结束优先于静音")
    func sentenceBeatsSilence() {
        let result = BoundaryAlignmentEngine.decide(
            boundaries: [5.0],
            scenes: [],
            silences: [SilenceGap(start: 5.1, end: 5.3)],
            sentences: [SentenceSpan(start: 3.0, end: 4.9)],
            duration: 100, fps: 100
        )
        #expect(result[0].anchor == .sentence)
    }

    // MARK: - 静音

    @Test("边界落在静音段内 → 移到静音中点")
    func snapsToSilenceMidpointWhenInside() {
        let result = BoundaryAlignmentEngine.align(
            boundaries: [5.0],
            scenes: [],
            silences: [SilenceGap(start: 4.8, end: 5.4)], // 中点 5.1
            sentences: [],
            duration: 100, fps: 100
        )
        #expect(abs(result[0] - 5.1) < 0.01)
    }

    // MARK: - 安全约束

    @Test("吸附偏移超过 maxBoundaryShift → 回退原切点")
    func revertsWhenShiftTooLarge() {
        var c = BoundaryAlignConfig()
        c.maxBoundaryShift = 0.3
        c.sceneSearchRange = 2.0 // 放大窗让强切镜被选中，再被约束回退
        let result = BoundaryAlignmentEngine.decide(
            boundaries: [5.0],
            scenes: [SceneCut(time: 6.0, strength: 0.9)], // 偏移 1.0 > 0.3
            silences: [],
            sentences: [],
            duration: 100, fps: 100, config: c
        )
        #expect(result[0].anchor == .original)
        #expect(abs(result[0].aligned - 5.0) < 0.01)
    }

    @Test("边界保持严格递增")
    func keepsBoundariesIncreasing() {
        let result = BoundaryAlignmentEngine.align(
            boundaries: [5.0, 5.2, 8.0],
            // 让前两个都吸到同一个静音中点，制造非递增，验证约束修正
            scenes: [],
            silences: [SilenceGap(start: 5.0, end: 5.2)], // 中点 5.1
            sentences: [],
            duration: 100, fps: 100
        )
        #expect(result[0] < result[1])
        #expect(result[1] < result[2])
    }

    @Test("空边界 → 空结果")
    func emptyBoundaries() {
        let result = BoundaryAlignmentEngine.align(
            boundaries: [], scenes: [], silences: [], sentences: [],
            duration: 100, fps: 30
        )
        #expect(result.isEmpty)
    }

    // MARK: - 按帧量化

    @Test("最终边界吸到帧栅格")
    func quantizesToFrameGrid() {
        // fps=25 → 帧间隔 0.04s。原切点 5.013 应量化到最近帧 5.00 或 5.04
        let result = BoundaryAlignmentEngine.align(
            boundaries: [5.013],
            scenes: [], silences: [], sentences: [],
            duration: 100, fps: 25
        )
        let frameIndex = (result[0] * 25).rounded()
        #expect(abs(result[0] * 25 - frameIndex) < 0.001) // 落在整数帧上
    }
}
