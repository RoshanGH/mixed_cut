import Foundation

/// 成片级「全局 BGM 铺底」滤镜图（纯字符串，导出服务直接拼进 ffmpeg 命令）。
///
/// 输入约定：input 0 = 已拼好的纯口播成片；input 1 = 用户选的 BGM 音频，
/// 由调用方加 `-stream_loop -1` 无限循环 —— BGM 短于成片时循环补齐，
/// 长于成片时由 atrim 截断。结尾 1 秒淡出，避免 BGM 硬切。
/// 只动 BGM 那一路（口播不淡出、不改音量），amix 不归一化以保持口播原响度。
public enum GlobalBGMMixGraphBuilder {
    /// 结尾淡出时长（秒）
    public static let fadeOutDuration: Double = 1.0

    /// - Parameters:
    ///   - pieceDuration: 成片时长（秒）
    ///   - bgmVolume: BGM 音量（0…1，越界自动夹取）
    public static func filterComplex(pieceDuration: Double, bgmVolume: Double) -> String {
        let d = max(0.1, pieceDuration)
        let v = min(1.0, max(0.0, bgmVolume))
        let fadeLen = min(fadeOutDuration, d)
        let fadeStart = max(0, d - fadeLen)
        return "[1:a]atrim=0:\(f3(d)),asetpts=PTS-STARTPTS,aresample=44100," +
               "volume=\(f2(v)),afade=t=out:st=\(f3(fadeStart)):d=\(f3(fadeLen))[bgm];" +
               "[0:a][bgm]amix=inputs=2:duration=first:normalize=0[aout]"
    }

    private static func f3(_ x: Double) -> String { String(format: "%.3f", x) }
    private static func f2(_ x: Double) -> String { String(format: "%.2f", x) }
}
