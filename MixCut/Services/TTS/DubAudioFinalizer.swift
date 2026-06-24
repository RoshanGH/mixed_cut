import Foundation

/// 落库后的配音产物：m4a 路径 + 对齐方案（导出时复现）。
struct FinalizedDub: Sendable {
    let m4aPath: String
    let plan: AlignmentPlan
}

/// 把 TTS 原始 wav 按对齐方案做 atempo 变速 + 转 AAC/m4a，写到全局 Dubs 目录。
/// 定格补帧 / 末尾静音不在此处烧入音频——它们随 plan 落库，由导出阶段（P4）拼接时处理。
actor DubAudioFinalizer {
    func finalize(tts: TTSResult,
                  targetDuration: Double,
                  fps: Double,
                  videoHash: String,
                  segmentId: UUID,
                  voiceId: String,
                  textVariantIndex: Int) async throws -> FinalizedDub {
        let plan = AudioAligner.plan(targetDuration: targetDuration,
                                     audioDuration: tts.rawDuration,
                                     fps: fps)

        let dest = FileHelper.dubAudioURL(videoHash: videoHash, segmentId: segmentId,
                                          voiceId: voiceId, textVariantIndex: textVariantIndex)
        try? FileManager.default.removeItem(at: dest)

        // atempo 只接受 0.5~2.0，单系数即可覆盖我们 [0.9,1.1] 区间
        var filters: [String] = []
        if abs(plan.atempoFactor - 1.0) > 0.001 {
            filters.append("atempo=\(String(format: "%.4f", plan.atempoFactor))")
        }

        let runner = FFmpegRunner()
        var args = ["-y", "-i", tts.wavPath]
        if !filters.isEmpty {
            args += ["-filter:a", filters.joined(separator: ",")]
        }
        args += ["-c:a", "aac", "-b:a", "128k", dest.path]
        _ = try await runner.run(arguments: args)

        return FinalizedDub(m4aPath: dest.path, plan: plan)
    }
}
