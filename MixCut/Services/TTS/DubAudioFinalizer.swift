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

        // ⚠️ 绝不能"先删旧文件再写新的"：dest 是确定性路径且已被 SegmentDub.audioFilePath 引用。
        // 一旦写入中途取消/失败，旧配音已经没了、新的又是截断的，而数据库里的路径字段照旧 ——
        // 用户会遇到"界面一切正常，但这个分镜的配音播不出来或只播半句"。
        // 改为写临时文件，成功后再原子替换。
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent("\(dest.deletingPathExtension().lastPathComponent).tmp.m4a")
        try? FileManager.default.removeItem(at: tmp)

        // atempo filter 单段只接受 0.5~2.0；大于 2.0 的加速（台词写很多时）需链式拆成多段相乘，
        // 这样不管多少字都能把配音压进画面、绝不超过。
        let filters = Self.atempoChain(plan.atempoFactor)

        let runner = FFmpegRunner()
        var args = ["-y", "-i", tts.wavPath]
        if !filters.isEmpty {
            args += ["-filter:a", filters.joined(separator: ",")]
        }
        args += ["-c:a", "aac", "-b:a", "128k", tmp.path]
        do {
            _ = try await runner.run(arguments: args, timeoutSeconds: 300)
        } catch {
            try? FileManager.default.removeItem(at: tmp)   // 失败/取消：清掉半成品，旧配音原样保留
            throw error
        }

        // 原子替换：到这一步才动已有文件
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)

        // ⚠️ finalize 是配音流水线里 TTS wav 的终点，用完必须删。
        // 以前从不删除：一次「一键改写」= 分镜数 × 变体数 × 重试次数 个 wav 永久堆在临时目录。
        // （试听走的是另一条路径、不经过 finalize，不受影响。）
        try? FileManager.default.removeItem(atPath: tts.wavPath)

        return FinalizedDub(m4aPath: dest.path, plan: plan)
    }

    /// 把任意 atempo 系数拆成每段都落在 [0.5, 2.0] 的链（相乘等于原系数）。
    /// 例：2.6 → ["atempo=2.0000","atempo=1.3000"]；接近 1.0 时返回空（不变速）。
    static func atempoChain(_ factor: Double) -> [String] {
        guard factor > 0, abs(factor - 1.0) > 0.001 else { return [] }
        var remaining = factor
        var parts: [String] = []
        while remaining > 2.0 { parts.append("atempo=2.0000"); remaining /= 2.0 }
        while remaining < 0.5 { parts.append("atempo=0.5000"); remaining /= 0.5 }
        parts.append("atempo=\(String(format: "%.4f", remaining))")
        return parts
    }
}
