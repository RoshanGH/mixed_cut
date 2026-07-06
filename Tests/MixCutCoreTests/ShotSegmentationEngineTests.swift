import Testing
@testable import MixCutCore

struct ShotSegmentationEngineTests {
    @Test("窗口内 scene cuts 切成有序帧区间")
    func splitsByScenes() {
        let shots = ShotSegmentationEngine.split(
            segmentStart: 0.0, segmentEnd: 8.0,
            sceneCuts: [ShotCut(time: 3.0), ShotCut(time: 5.5)],
            fps: 30.0
        )
        #expect(shots.count == 3)
        #expect(shots[0].startFrame == 0)
        #expect(shots[0].endFrame == 90)
        #expect(shots[1].startFrame == 90)
        #expect(shots[2].endFrame == 240)
        #expect(shots.map(\.orderIndex) == [1, 2, 3])
    }

    @Test("窗口外/边界处的 cuts 被忽略")
    func ignoresOutOfRangeCuts() {
        let shots = ShotSegmentationEngine.split(
            segmentStart: 2.0, segmentEnd: 6.0,
            sceneCuts: [ShotCut(time: 1.0), ShotCut(time: 6.0), ShotCut(time: 8.0)],
            fps: 25.0
        )
        #expect(shots.count == 1)
        #expect(shots[0].startFrame == 50)
        #expect(shots[0].endFrame == 150)
    }

    @Test("过近的 cut 合并，不产生 <最小帧数 的碎片")
    func mergesTooCloseCuts() {
        let shots = ShotSegmentationEngine.split(
            segmentStart: 0.0, segmentEnd: 5.0,
            sceneCuts: [ShotCut(time: 0.1), ShotCut(time: 2.5)],
            fps: 30.0, minShotSeconds: 0.5
        )
        #expect(shots.count == 2)
        #expect(shots[0].startFrame == 0)
        #expect(shots[0].endFrame == 75)
    }
}
