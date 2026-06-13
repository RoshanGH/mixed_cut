import Testing
@testable import MixCutCore

struct FrameTimeTests {

    // MARK: - 帧 ↔ 秒

    @Test("帧号 → 秒")
    func frameToSeconds() {
        #expect(FrameTime.seconds(frame: 30, fps: 30) == 1.0)
        #expect(FrameTime.seconds(frame: 15, fps: 30) == 0.5)
        #expect(FrameTime.seconds(frame: 0, fps: 30) == 0.0)
    }

    @Test("秒 → 最近帧（四舍五入）")
    func secondsToFrame() {
        #expect(FrameTime.frame(seconds: 1.0, fps: 30) == 30)
        #expect(FrameTime.frame(seconds: 0.51, fps: 30) == 15)   // 15.3 → 15
        #expect(FrameTime.frame(seconds: 0.50, fps: 30) == 15)   // 15.0
        #expect(FrameTime.frame(seconds: 0.49, fps: 30) == 15)   // 14.7 → 15
    }

    @Test("帧/秒往返无损（整数帧率）")
    func roundTripLossless() {
        for f in [0, 1, 7, 30, 137, 1801, 99999] {
            let sec = FrameTime.seconds(frame: f, fps: 30)
            #expect(FrameTime.frame(seconds: sec, fps: 30) == f)
        }
    }

    @Test("fps 为 0 时安全返回 0")
    func zeroFpsSafe() {
        #expect(FrameTime.seconds(frame: 100, fps: 0) == 0)
        #expect(FrameTime.frame(seconds: 5.0, fps: 0) == 0)
    }

    // MARK: - 时间码

    @Test("时间码：30fps 进位")
    func timecode30fps() {
        #expect(FrameTime.timecode(frame: 0, fps: 30) == "00:00:00")
        #expect(FrameTime.timecode(frame: 29, fps: 30) == "00:00:29")
        #expect(FrameTime.timecode(frame: 30, fps: 30) == "00:01:00")   // 1 秒整
        #expect(FrameTime.timecode(frame: 75, fps: 30) == "00:02:15")   // 2 秒 15 帧
    }

    @Test("时间码：60fps 进位")
    func timecode60fps() {
        #expect(FrameTime.timecode(frame: 59, fps: 60) == "00:00:59")
        #expect(FrameTime.timecode(frame: 60, fps: 60) == "00:01:00")
        #expect(FrameTime.timecode(frame: 90, fps: 60) == "00:01:30")   // 1 秒 30 帧
    }

    @Test("时间码：超过 1 小时显示小时位")
    func timecodeWithHours() {
        // 1 小时 = 3600 秒 × 30 帧 = 108000 帧
        #expect(FrameTime.timecode(frame: 108000, fps: 30) == "1:00:00:00")
    }
}
