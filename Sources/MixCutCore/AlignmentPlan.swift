import Foundation

/// 把一段配音音频塞进固定画面时长的对齐方案（导出时照此拼）。
public struct AlignmentPlan: Equatable, Sendable {
    /// atempo 变速系数（>1 加速，<1 减速，1.0 不变速）
    public let atempoFactor: Double
    /// 变速后音频仍比画面长时，末尾定格补的帧数
    public let freezePadFrames: Int
    /// 变速后音频比画面短时，末尾补的静音秒数
    public let trailingSilence: Double

    public init(atempoFactor: Double, freezePadFrames: Int, trailingSilence: Double) {
        self.atempoFactor = atempoFactor
        self.freezePadFrames = freezePadFrames
        self.trailingSilence = trailingSilence
    }
}

/// 对齐阶梯纯决策：字数预算已让多数情况落在直接命中/atempo 区间，定格/静音仅兜残差。
public enum AudioAligner {
    /// 直接命中阈值（秒）：差异在此内不变速，保留自然音色
    private static let directThreshold = 0.15
    /// atempo 允许区间（±10% 几乎听不出）
    private static let atempoMin = 0.9
    private static let atempoMax = 1.1

    /// - Parameters:
    ///   - targetDuration: 画面（分镜）时长 D
    ///   - audioDuration: TTS 原始音频时长 D'
    ///   - fps: 视频帧率（算定格补帧用）
    public static func plan(targetDuration: Double, audioDuration: Double, fps: Double) -> AlignmentPlan {
        guard targetDuration > 0, audioDuration > 0, fps > 0 else {
            return AlignmentPlan(atempoFactor: 1.0, freezePadFrames: 0, trailingSilence: 0)
        }

        let diff = audioDuration - targetDuration
        let atempo: Double
        if abs(diff) <= directThreshold {
            atempo = 1.0
        } else {
            atempo = min(max(audioDuration / targetDuration, atempoMin), atempoMax)
        }

        let outDuration = audioDuration / atempo
        let residual = outDuration - targetDuration   // >0 仍偏长；<0 偏短

        if residual > 0.001 {
            return AlignmentPlan(atempoFactor: atempo,
                                 freezePadFrames: Int((residual * fps).rounded()),
                                 trailingSilence: 0)
        } else if residual < -0.001 {
            return AlignmentPlan(atempoFactor: atempo,
                                 freezePadFrames: 0,
                                 trailingSilence: -residual)
        } else {
            return AlignmentPlan(atempoFactor: atempo, freezePadFrames: 0, trailingSilence: 0)
        }
    }
}
