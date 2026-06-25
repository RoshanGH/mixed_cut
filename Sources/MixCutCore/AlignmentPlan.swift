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

/// 对齐阶梯纯决策。铁律：**配音绝不超过画面时长**——
/// 偏长一律用 atempo 压缩到正好等于画面（永不靠定格补帧延长画面，freezePadFrames 恒为 0）；
/// 偏短才适度放慢，残差用末尾静音补满。字数预算（按克隆语速配字）已让多数情况接近命中，
/// atempo 只做微小兜底。
public enum AudioAligner {
    /// 偏短直接命中阈值（秒）：配音比画面短 ≤ 此值时不变速，末尾补少量静音即可
    private static let directThreshold = 0.15
    /// 放慢封底（最多放慢 ~25%）：配音偏短时拉满画面、消除末尾空挡
    private static let atempoMinStretch = 0.8

    /// - Parameters:
    ///   - targetDuration: 画面（分镜）时长 D
    ///   - audioDuration: TTS 原始音频时长 D'
    ///   - fps: 视频帧率（保留参数，当前不再用于定格补帧）
    public static func plan(targetDuration: Double, audioDuration: Double, fps: Double) -> AlignmentPlan {
        guard targetDuration > 0, audioDuration > 0, fps > 0 else {
            return AlignmentPlan(atempoFactor: 1.0, freezePadFrames: 0, trailingSilence: 0)
        }

        let atempo: Double
        if audioDuration > targetDuration {
            // 偏长 → 无封顶压缩到正好等于画面：不管台词写多少字，配音都加速塞进画面、绝不超过。
            // （atempo>2.0 由 DubAudioFinalizer 链式拆分实现）
            atempo = audioDuration / targetDuration
        } else {
            let shortBy = targetDuration - audioDuration
            if shortBy <= directThreshold {
                atempo = 1.0                       // 偏短很小，不变速
            } else {
                atempo = max(audioDuration / targetDuration, atempoMinStretch)  // 适度放慢减小空挡
            }
        }

        let outDuration = audioDuration / atempo
        let residual = outDuration - targetDuration   // >0 仅在极端超长(封顶仍超)时出现；<0 偏短

        // 永不通过定格补帧延长画面：分镜时长 = 画面时长，配音绝不超过画面。
        if residual < -0.001 {
            return AlignmentPlan(atempoFactor: atempo, freezePadFrames: 0, trailingSilence: -residual)
        } else {
            return AlignmentPlan(atempoFactor: atempo, freezePadFrames: 0, trailingSilence: 0)
        }
    }
}
