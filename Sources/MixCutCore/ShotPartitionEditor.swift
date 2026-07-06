import Foundation

/// 分镜头的一段帧区间（源视频绝对帧）。
public struct ShotSpan: Equatable, Sendable {
    public let startFrame: Int
    public let endFrame: Int
    public init(startFrame: Int, endFrame: Int) {
        self.startFrame = startFrame
        self.endFrame = endFrame
    }
    public var frameCount: Int { max(0, endFrame - startFrame) }
}

/// 分镜头分区编辑（切分点建模）。所有操作保持无缝铺满 + 首尾边界不变（总长恒等于分镜时长）。
public enum ShotPartitionEditor {
    public static let defaultMinFrames = 5

    /// 合并 i 与 i+1。
    public static func merge(_ shots: [ShotSpan], at i: Int) -> [ShotSpan] {
        guard i >= 0, i + 1 < shots.count else { return shots }
        var out = shots
        let merged = ShotSpan(startFrame: shots[i].startFrame, endFrame: shots[i + 1].endFrame)
        out.replaceSubrange(i...(i + 1), with: [merged])
        return out
    }

    /// 移动第 b 个切分点（shots[b].end == shots[b+1].start）到 f，clamp 到 [start+min, nextEnd-min]。
    public static func moveBoundary(_ shots: [ShotSpan], boundaryIndex b: Int, toFrame f: Int,
                                    minFrames: Int = defaultMinFrames) -> [ShotSpan] {
        guard b >= 0, b + 1 < shots.count else { return shots }
        let lo = shots[b].startFrame + minFrames
        let hi = shots[b + 1].endFrame - minFrames
        guard hi >= lo else { return shots }
        let nf = min(max(f, lo), hi)
        var out = shots
        out[b] = ShotSpan(startFrame: shots[b].startFrame, endFrame: nf)
        out[b + 1] = ShotSpan(startFrame: nf, endFrame: shots[b + 1].endFrame)
        return out
    }

    /// 拆分镜头 i：在 f 处一分为二（f 需落在 [start+min, end-min]，否则原样返回）。
    public static func split(_ shots: [ShotSpan], at i: Int, atFrame f: Int,
                             minFrames: Int = defaultMinFrames) -> [ShotSpan] {
        guard i >= 0, i < shots.count else { return shots }
        let s = shots[i]
        guard f >= s.startFrame + minFrames, f <= s.endFrame - minFrames else { return shots }
        var out = shots
        out.replaceSubrange(i...i, with: [ShotSpan(startFrame: s.startFrame, endFrame: f),
                                          ShotSpan(startFrame: f, endFrame: s.endFrame)])
        return out
    }

    /// 中点拆分便捷。
    public static func splitAtMidpoint(_ shots: [ShotSpan], at i: Int,
                                       minFrames: Int = defaultMinFrames) -> [ShotSpan] {
        guard i >= 0, i < shots.count else { return shots }
        let s = shots[i]
        return split(shots, at: i, atFrame: (s.startFrame + s.endFrame) / 2, minFrames: minFrames)
    }
}
