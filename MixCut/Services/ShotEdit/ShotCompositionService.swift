import Foundation

/// 把占位式选定的分镜头（原切片 / 变体切片）按序合成为一条新分镜视频：
/// 逐坑规整到精确帧数 → concat 拼接 → 合回原逻辑分镜音频（防音画漂移）。
/// 产物落临时目录；hash + 拷入 Videos/ + 建 Video/Segment 由调用方完成。
actor ShotCompositionService {
    private let ffmpeg: FFmpegRunner
    init(ffmpeg: FFmpegRunner = FFmpegRunner()) { self.ffmpeg = ffmpeg }

    /// 一个坑的输入：帧区间 + （变体视频路径，nil = 用原分镜头切片）
    struct SlotInput: Sendable {
        let startFrame: Int
        let endFrame: Int
        let variantVideoPath: String?
        init(startFrame: Int, endFrame: Int, variantVideoPath: String? = nil) {
            self.startFrame = startFrame
            self.endFrame = endFrame
            self.variantVideoPath = variantVideoPath
        }
    }

    struct Result: Sendable {
        let compositeVideoPath: String
        let totalFrames: Int
        let duration: Double
    }

    /// - Parameters:
    ///   - sourceVideoPath: 原视频
    ///   - fps: 帧率
    ///   - slots: 按 orderIndex 升序排列的坑
    ///   - segmentStart/segmentEnd: 原逻辑分镜时间窗口（秒），用于取原音频
    ///   - resolution: 输出分辨率（默认竖屏 720×1280）
    func compose(sourceVideoPath: String,
                 fps: Double,
                 slots: [SlotInput],
                 segmentStart: Double,
                 segmentEnd: Double,
                 resolution: String = "720:1280") async throws -> Result {   // scale 滤镜用冒号，非 x
        guard fps > 0, !slots.isEmpty else {
            throw NSError(domain: "ShotComposition", code: -1, userInfo: [NSLocalizedDescriptionKey: "无有效分镜头或帧率"])
        }
        let work = FileHelper.tempDirectory.appendingPathComponent("shotcompose-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // 1) 逐坑产出「与目标帧数完全一致」的切片，记录目标时长
        var segs: [(path: String, start: Double, end: Double)] = []
        var totalFrames = 0
        for (i, slot) in slots.enumerated() {
            let targetFrames = max(1, slot.endFrame - slot.startFrame)
            totalFrames += targetFrames
            let out = work.appendingPathComponent("slot-\(i).mp4").path
            if let variantPath = slot.variantVideoPath {
                try await normalizeVariant(variantPath, targetFrames: targetFrames, fps: fps, to: out)
            } else {
                // 原分镜头：帧精确切片
                try await ffmpeg.cutSegment(from: sourceVideoPath,
                                            start: Double(slot.startFrame) / fps,
                                            end: Double(slot.endFrame) / fps,
                                            fps: fps, to: out)
            }
            segs.append((out, 0.0, Double(targetFrames) / fps))
        }

        // 2) concat 拼接（统一 30fps/scale/pad）
        let joined = work.appendingPathComponent("joined.mp4").path
        try await ffmpeg.concat(segments: segs, outputPath: joined, resolution: resolution)

        // 3) 取原逻辑分镜音频段
        let audio = work.appendingPathComponent("audio.m4a").path
        _ = try await ffmpeg.run(arguments: [
            "-ss", String(format: "%.3f", max(0, segmentStart)),
            "-to", String(format: "%.3f", segmentEnd),
            "-i", sourceVideoPath,
            "-vn", "-c:a", "aac", "-b:a", "192k",
            "-y", audio
        ], timeoutSeconds: 600)

        // 4) mux：拼接画面 + 原音频（替换音轨）
        let finalURL = FileHelper.tempDirectory.appendingPathComponent("composite-\(UUID().uuidString).mp4")
        let hasAudio = FileManager.default.fileExists(atPath: audio)
        var muxArgs = ["-i", joined]
        if hasAudio { muxArgs += ["-i", audio] }
        muxArgs += ["-map", "0:v:0"]
        if hasAudio { muxArgs += ["-map", "1:a:0", "-c:a", "aac"] }
        muxArgs += ["-c:v", "copy", "-shortest", "-movflags", "+faststart", "-y", finalURL.path]
        _ = try await ffmpeg.run(arguments: muxArgs, timeoutSeconds: 600)

        // 探测最终合成片的**实际**帧数（concat 可能统一到 30fps，与 source-fps 累加值不同），
        // 供就地替换的 effectivePicture 精确裁全片。
        let actualFrames = (try? await probeFrameCount(finalURL.path)) ?? totalFrames
        let duration = Double(totalFrames) / fps
        return Result(compositeVideoPath: finalURL.path, totalFrames: actualFrames, duration: duration)
    }

    // MARK: - 私有

    /// 把变体切片规整到目标帧数（多退少补）。
    private func normalizeVariant(_ path: String, targetFrames: Int, fps: Double, to out: String) async throws {
        let actual = try await probeFrameCount(path)
        switch FrameCountAligner.plan(actualFrames: actual, targetFrames: targetFrames) {
        case .none:
            // 帧数已一致，仍统一像素格式/时间戳
            _ = try await ffmpeg.run(arguments: [
                "-i", path, "-vf", "setpts=PTS-STARTPTS", "-an",
                "-c:v", "h264_videotoolbox", "-b:v", "8000k", "-pix_fmt", "yuv420p",
                "-y", out
            ], timeoutSeconds: 600)
        case .trim(let drop):
            let keep = max(1, actual - drop)
            _ = try await ffmpeg.run(arguments: [
                "-i", path,
                "-vf", "trim=end_frame=\(keep),setpts=PTS-STARTPTS", "-an",
                "-c:v", "h264_videotoolbox", "-b:v", "8000k", "-pix_fmt", "yuv420p",
                "-y", out
            ], timeoutSeconds: 600)
        case .pad(let repeatLast):
            let stopDur = Double(repeatLast) / fps
            _ = try await ffmpeg.run(arguments: [
                "-i", path,
                "-vf", "tpad=stop_mode=clone:stop_duration=\(String(format: "%.4f", stopDur)),setpts=PTS-STARTPTS", "-an",
                "-c:v", "h264_videotoolbox", "-b:v", "8000k", "-pix_fmt", "yuv420p",
                "-y", out
            ], timeoutSeconds: 600)
        }
    }

    /// 精确帧数（-count_frames，短切片可接受）
    private func probeFrameCount(_ path: String) async throws -> Int {
        let out = try await ffmpeg.runProbe(arguments: [
            "-v", "error", "-count_frames", "-select_streams", "v:0",
            "-show_entries", "stream=nb_read_frames",
            "-of", "default=nokey=1:noprint_wrappers=1", path
        ])
        let n = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return n
    }
}
