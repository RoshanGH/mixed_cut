import Foundation

/// 用 CosyVoice 原生 `rate` 把 TTS 时长对齐到分镜时长的纯决策。
/// 思路：先按基准 rate 合成测一遍时长，再算出"要命中目标时长该用多快"，必要时二次合成。
/// rate 与时长成反比：rate 越大越快、时长越短。
public enum SpeechRatePlanner {
    /// CosyVoice rate 合法区间
    public static let rateMin = 0.5
    public static let rateMax = 2.0
    /// 一次合成漂移在此比例内（且无语速偏好）即认为已贴合，无需二次合成（剩余交给 atempo）。
    public static let acceptTolerance = 0.08

    /// 计算二次合成建议 rate。
    /// - Parameters:
    ///   - targetDuration: 分镜（画面）时长
    ///   - measuredDuration: 第一次合成得到的音频时长
    ///   - measuredAtRate: 第一次合成所用 rate
    ///   - bias: 用户语速偏好（相对"自然贴合"，1.0=完全贴合，>1 更快，<1 更慢）
    /// - Returns: 建议的二次合成 rate；返回 nil 表示无需二次合成。
    public static func retargetRate(targetDuration: Double,
                                    measuredDuration: Double,
                                    measuredAtRate: Double,
                                    bias: Double = 1.0) -> Double? {
        guard targetDuration > 0, measuredDuration > 0, measuredAtRate > 0 else { return nil }

        // 期望音频时长 = 目标 / bias（bias>1 想更快 → 音频更短）
        let desired = targetDuration / max(bias, 0.0001)
        let drift = abs(measuredDuration - desired) / desired
        // 已经够贴合且没有语速偏好 → 不重合成
        if drift <= acceptTolerance { return nil }

        // 要把 measuredDuration（@measuredAtRate）变成 desired：rate ∝ 1/时长
        let ideal = measuredAtRate * (measuredDuration / desired)
        let clamped = min(max(ideal, rateMin), rateMax)
        // 夹断后与一次合成 rate 几乎一致 → 重合成无意义
        if abs(clamped - measuredAtRate) < 0.01 { return nil }
        return clamped
    }
}
