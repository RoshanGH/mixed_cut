import Testing
@testable import MixCutCore

struct ShotPartitionEditorTests {
    private func spans(_ pairs: [(Int, Int)]) -> [ShotSpan] { pairs.map { ShotSpan(startFrame: $0.0, endFrame: $0.1) } }

    @Test("合并相邻：无缝、总长不变、边界不动")
    func merge() {
        let r = ShotPartitionEditor.merge(spans([(0, 90), (90, 165), (165, 240)]), at: 0)
        #expect(r == spans([(0, 165), (165, 240)]))
        #expect(r.first?.startFrame == 0 && r.last?.endFrame == 240)
    }

    @Test("移动边界：clamp、两侧无缝")
    func moveBoundary() {
        let base = spans([(0, 90), (90, 240)])
        #expect(ShotPartitionEditor.moveBoundary(base, boundaryIndex: 0, toFrame: 150, minFrames: 5) == spans([(0, 150), (150, 240)]))
        #expect(ShotPartitionEditor.moveBoundary(base, boundaryIndex: 0, toFrame: -10, minFrames: 5)[0].endFrame == 5)
        #expect(ShotPartitionEditor.moveBoundary(base, boundaryIndex: 0, toFrame: 9999, minFrames: 5)[0].endFrame == 235)
    }

    @Test("拆分中点：两段和=原段、无缝")
    func split() {
        #expect(ShotPartitionEditor.split(spans([(0, 240)]), at: 0, atFrame: 120) == spans([(0, 120), (120, 240)]))
    }

    @Test("拆分点过近端点（<minFrames）→ 原样返回")
    func splitTooClose() {
        let base = spans([(0, 240)])
        #expect(ShotPartitionEditor.split(base, at: 0, atFrame: 2, minFrames: 5) == base)
    }

    @Test("中点拆分便捷")
    func splitMid() {
        #expect(ShotPartitionEditor.splitAtMidpoint(spans([(10, 250)]), at: 0) == spans([(10, 130), (130, 250)]))
    }

    @Test("任何操作后 首尾边界 = 原分区首尾")
    func endpointsInvariant() {
        let base = spans([(0, 90), (90, 240)])
        let m = ShotPartitionEditor.merge(base, at: 0)
        #expect(m.first?.startFrame == 0 && m.last?.endFrame == 240)
        let mv = ShotPartitionEditor.moveBoundary(base, boundaryIndex: 0, toFrame: 120)
        #expect(mv.first?.startFrame == 0 && mv.last?.endFrame == 240)
    }
}
