import Foundation

/// 把一段视频切片规整到目标帧数的计划（纯计算，实际 trim/pad 由 FFmpeg 层执行）。
public enum FrameAlignPlan: Sendable, Equatable {
    case none
    case trim(dropTrailing: Int)
    case pad(repeatLast: Int)
}

public enum FrameCountAligner {
    /// 计算视频切片帧数对齐方案。
    /// - Parameters:
    ///   - actualFrames: 实际帧数（原切片或 AI 变体）
    ///   - targetFrames: 目标帧数（在混剪方案中指定的）
    /// - Returns: 对齐计划（trim/pad/none）
    public static func plan(actualFrames: Int, targetFrames: Int) -> FrameAlignPlan {
        if actualFrames == targetFrames { return .none }
        return actualFrames > targetFrames
            ? .trim(dropTrailing: actualFrames - targetFrames)
            : .pad(repeatLast: targetFrames - actualFrames)
    }
}
