import Foundation

/// 分镜头切分输入：一个画面切换点（秒，相对源视频时间轴）
public struct ShotCut: Sendable, Equatable {
    public let time: Double
    public init(time: Double) { self.time = time }
}

/// 分镜头切分结果：源视频绝对帧号区间 + 顺序
public struct ShotRange: Sendable, Equatable {
    public let orderIndex: Int
    public let startFrame: Int
    public let endFrame: Int
    public init(orderIndex: Int, startFrame: Int, endFrame: Int) {
        self.orderIndex = orderIndex
        self.startFrame = startFrame
        self.endFrame = endFrame
    }
}

/// 把一条逻辑分镜的时间窗口，按内部画面切换点切成有序物理镜头（纯函数）。
public enum ShotSegmentationEngine {
    public static func split(
        segmentStart: Double,
        segmentEnd: Double,
        sceneCuts: [ShotCut],
        fps: Double,
        minShotSeconds: Double = 0.5
    ) -> [ShotRange] {
        guard fps > 0, segmentEnd > segmentStart else { return [] }
        let interior = sceneCuts
            .map(\.time)
            .filter { $0 > segmentStart && $0 < segmentEnd }
            .sorted()
        var accepted: [Double] = []
        var last = segmentStart
        for t in interior where t - last >= minShotSeconds && segmentEnd - t >= minShotSeconds {
            accepted.append(t)
            last = t
        }
        let bounds = [segmentStart] + accepted + [segmentEnd]
        var shots: [ShotRange] = []
        for i in 0..<(bounds.count - 1) {
            let sf = FrameTime.frame(seconds: bounds[i], fps: fps)
            let ef = FrameTime.frame(seconds: bounds[i + 1], fps: fps)
            guard ef > sf else { continue }
            shots.append(ShotRange(orderIndex: shots.count + 1, startFrame: sf, endFrame: ef))
        }
        return shots
    }
}
