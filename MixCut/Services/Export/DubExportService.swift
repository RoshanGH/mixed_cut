import Foundation

/// 单分镜导出规格（值类型，可跨 actor 传递）。
struct DubSegmentSpec: Sendable {
    let videoPath: String
    let startFrame: Int
    let endFrame: Int
    let fps: Double
    let captionText: String
    let hasHardSubtitle: Bool
    let maskStyleRaw: String
    let maskRect: SubtitleMaskRect
    let isVoiceLocked: Bool
    let dubAudioPath: String?      // 配音段 m4a；锁定/回退段为 nil
    let freezePadFrames: Int
    let trailingSilence: Double
    let bgmAudioPath: String?      // 配音镜头的 BGM 源（整轨 bgm.wav）；nil = 不混 BGM
}

/// 配音导出输入（整条成片）。
struct DubExportInput: Sendable {
    let segments: [DubSegmentSpec]
    let maxWidth: Int
    let maxHeight: Int

    /// 从某方案解析出导出输入（必须在 @MainActor 调用）。
    /// 每槽按 SchemeSegment.selectedSegmentDubId 取定变体；nil/锁定/无音频 → 原声回退。
    @MainActor
    static func from(scheme: MixScheme) -> DubExportInput? {
        let ordered = scheme.orderedSegments
        guard !ordered.isEmpty else { return nil }

        var specs: [DubSegmentSpec] = []
        var maxW = 0, maxH = 0
        for schemeSeg in ordered {
            guard let segment = schemeSeg.segment,
                  let video = segment.video,
                  FileManager.default.fileExists(atPath: video.localPath) else { continue }

            let fps = video.fps > 0 ? video.fps : 30
            maxW = max(maxW, video.width)
            maxH = max(maxH, video.height)

            // 该槽选定的变体（nil 或找不到 → 原声）
            let chosen: SegmentDub? = schemeSeg.selectedSegmentDubId.flatMap { dubId in
                segment.segmentDubs.first { $0.id == dubId }
            }

            if segment.isVoiceLocked || chosen == nil {
                specs.append(DubSegmentSpec(
                    videoPath: video.localPath, startFrame: segment.startFrame, endFrame: segment.endFrame,
                    fps: fps, captionText: segment.text, hasHardSubtitle: false, maskStyleRaw: segment.maskStyleRaw,
                    maskRect: segment.maskRect, isVoiceLocked: true, dubAudioPath: nil,
                    freezePadFrames: 0, trailingSilence: 0, bgmAudioPath: nil))
            } else if let dub = chosen,
                      let audioPath = dub.audioFilePath,
                      FileManager.default.fileExists(atPath: audioPath) {
                let caption = dub.rewrittenText.isEmpty ? segment.text : dub.rewrittenText
                specs.append(DubSegmentSpec(
                    videoPath: video.localPath, startFrame: segment.startFrame, endFrame: segment.endFrame,
                    fps: fps, captionText: caption, hasHardSubtitle: segment.hasHardSubtitle, maskStyleRaw: segment.maskStyleRaw,
                    maskRect: segment.maskRect, isVoiceLocked: false, dubAudioPath: audioPath,
                    freezePadFrames: dub.freezePadFrames, trailingSilence: dub.trailingSilence, bgmAudioPath: nil))
            } else {
                // 非锁定但无已生成配音 → 回退保留原声原字幕，保证导出不中断
                MixLog.info("分镜 \(segment.segmentIndex) 无已生成配音，回退原声导出")
                // 故意写死 hasHardSubtitle: false：回退段不重配也不烧新字幕，
                // 因此不能遮挡旧硬字幕（否则会把要保留的原字幕也遮掉）。勿改回 segment.hasHardSubtitle。
                specs.append(DubSegmentSpec(
                    videoPath: video.localPath, startFrame: segment.startFrame, endFrame: segment.endFrame,
                    fps: fps, captionText: segment.text, hasHardSubtitle: false, maskStyleRaw: segment.maskStyleRaw,
                    maskRect: segment.maskRect, isVoiceLocked: true, dubAudioPath: nil,
                    freezePadFrames: 0, trailingSilence: 0, bgmAudioPath: nil))
            }
        }
        guard !specs.isEmpty else { return nil }
        return DubExportInput(segments: specs, maxWidth: maxW, maxHeight: maxH)
    }
}

/// 两阶段配音导出：逐分镜中间片 → concat 拼接。现有普通导出 ExportService 不受影响。
actor DubExportService {
    private let ffmpeg: FFmpegRunner

    init(ffmpeg: FFmpegRunner = FFmpegRunner()) {
        self.ffmpeg = ffmpeg
    }

    func export(
        input: DubExportInput,
        outputPath: String,
        config: ExportConfig = ExportConfig(),
        onProgress: (@Sendable (ExportProgress) -> Void)? = nil
    ) async throws {
        guard !input.segments.isEmpty else { throw ExportError.noSegments }

        // 输出分辨率（9:16，偶数）
        let (outW, outH) = Self.resolution(config: config, maxWidth: input.maxWidth, maxHeight: input.maxHeight)

        // 临时工作目录
        let workDir = FileHelper.tempDirectory.appendingPathComponent("dubexport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        var intermediatePaths: [String] = []
        let total = input.segments.count

        // 阶段一：逐分镜中间片
        for (i, spec) in input.segments.enumerated() {
            onProgress?(ExportProgress(phase: .cutting,
                                       progress: Double(i) / Double(total) * 0.85,
                                       description: "处理分镜 \(i + 1)/\(total)…"))

            let interURL = workDir.appendingPathComponent(String(format: "seg_%03d.mp4", i))
            try await renderSegment(spec: spec, index: i, outW: outW, outH: outH,
                                    workDir: workDir, config: config, outputPath: interURL.path)
            intermediatePaths.append(interURL.path)
        }

        // 阶段二：concat 解复用器无损拼接
        onProgress?(ExportProgress(phase: .concatenating, progress: 0.9, description: "拼接成片…"))
        try await concatCopy(paths: intermediatePaths, workDir: workDir, outputPath: outputPath)

        onProgress?(ExportProgress(phase: .completed, progress: 1.0, description: "配音导出完成"))
    }

    // MARK: - 单分镜独立导出（分镜库变体导出用）

    /// 渲染单个分镜为独立 mp4。分辨率按本片自身宽高与 config 计算，不与其他片拼接。
    func exportSingleSegment(
        spec: DubSegmentSpec,
        videoWidth: Int,
        videoHeight: Int,
        outputPath: String,
        config: ExportConfig = ExportConfig()
    ) async throws {
        let (outW, outH) = Self.resolution(config: config, maxWidth: videoWidth, maxHeight: videoHeight)
        let workDir = FileHelper.tempDirectory.appendingPathComponent("dubseg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        try await renderSegment(spec: spec, index: 0, outW: outW, outH: outH,
                                workDir: workDir, config: config, outputPath: outputPath)
    }

    // MARK: - 单分镜中间片

    private func renderSegment(spec: DubSegmentSpec, index: Int, outW: Int, outH: Int,
                               workDir: URL, config: ExportConfig, outputPath: String) async throws {
        let mode: SubtitleMaskMode = spec.isVoiceLocked
            ? .none
            : SubtitleMaskMode.from(hasHardSubtitle: spec.hasHardSubtitle, maskStyleRaw: spec.maskStyleRaw)
        let maskPixel = PixelRect.from(spec.maskRect, outputWidth: outW, outputHeight: outH)

        // 输入按追加顺序编号：input 0 = 源视频，extraInputs 依次为 input 1..N。
        var captionOrigin: (x: Int, y: Int)? = nil
        var captionInputIndex = 1
        var dubAudioInputIndex = 1
        var bgmInputIndex: Int? = nil
        var extraInputs: [String] = []

        let keepOriginalAudio = spec.isVoiceLocked || spec.dubAudioPath == nil

        if !spec.isVoiceLocked, !spec.captionText.isEmpty {
            let canvasW = max(2, Int(Double(outW) * 0.9))
            let withBackdrop = (mode != .solid)
            let pngURL = workDir.appendingPathComponent(String(format: "cap_%03d.png", index))
            let img = try CaptionRenderer.renderToFile(
                text: spec.captionText, canvasWidth: canvasW, withBackdrop: withBackdrop, to: pngURL)
            captionOrigin = CaptionLayout.overlayOrigin(
                outputWidth: outW, outputHeight: outH, maskRect: spec.maskRect,
                captionWidth: img.pixelWidth, captionHeight: img.pixelHeight)
            extraInputs.append(pngURL.path)
            captionInputIndex = extraInputs.count   // 1-based，与 ffmpeg 输入序号一致
        }

        if !keepOriginalAudio, let dubPath = spec.dubAudioPath {
            extraInputs.append(dubPath)
            dubAudioInputIndex = extraInputs.count
            if let bgmPath = spec.bgmAudioPath, FileManager.default.fileExists(atPath: bgmPath) {
                extraInputs.append(bgmPath)
                bgmInputIndex = extraInputs.count
            }
        }

        let graph = DubSegmentGraphBuilder.build(
            mode: mode,
            startFrame: spec.startFrame, endFrame: spec.endFrame, fps: spec.fps,
            outputWidth: outW, outputHeight: outH,
            maskPixel: maskPixel,
            captionOrigin: captionOrigin,
            captionInputIndex: captionInputIndex,
            keepOriginalAudio: keepOriginalAudio,
            dubAudioInputIndex: dubAudioInputIndex,
            freezePadFrames: spec.freezePadFrames,
            trailingSilence: spec.trailingSilence,
            bgmInputIndex: bgmInputIndex)

        var args: [String] = ["-y", "-i", spec.videoPath]
        for input in extraInputs { args += ["-i", input] }
        args += ["-filter_complex", graph.filterComplex,
                 "-map", graph.videoMapLabel, "-map", graph.audioMapLabel]

        // 统一硬件编码（中间片参数必须一致，阶段二才能 -c copy）。
        // 配音版导出固定走 h264_videotoolbox，故码率按 .h264Hardware 基准取，
        // 忽略 config.codec——否则软件编码档会落到 videoBitrateKbps 的 default(8000k) 与实际 h264 不匹配。
        let bitrate = config.quality.videoBitrateKbps(for: .h264Hardware)
        args += ["-c:v", "h264_videotoolbox", "-b:v", "\(bitrate)k", "-maxrate", "\(bitrate * 2)k",
                 "-tag:v", "avc1", "-allow_sw", "1", "-pix_fmt", "yuv420p",
                 "-c:a", "aac", "-b:a", "192k", "-ar", "44100",
                 "-movflags", "+faststart", outputPath]

        _ = try await ffmpeg.run(arguments: args, totalDuration: nil, onProgress: nil)
    }

    // MARK: - 阶段二拼接

    private func concatCopy(paths: [String], workDir: URL, outputPath: String) async throws {
        let listURL = workDir.appendingPathComponent("list.txt")
        let body = paths.map { "file '\($0)'" }.joined(separator: "\n") + "\n"
        try body.write(to: listURL, atomically: true, encoding: .utf8)

        let args = ["-y", "-f", "concat", "-safe", "0", "-i", listURL.path,
                    "-c", "copy", "-movflags", "+faststart", outputPath]
        _ = try await ffmpeg.run(arguments: args, totalDuration: nil, onProgress: nil)
    }

    // MARK: - 分辨率

    private static func resolution(config: ExportConfig, maxWidth: Int, maxHeight: Int) -> (Int, Int) {
        switch config.resolution {
        case .original:
            let w = maxWidth > 0 ? (maxWidth + 1) / 2 * 2 : 1080
            let h = maxHeight > 0 ? (maxHeight + 1) / 2 * 2 : 1920
            return (w, h)
        case .p1080: return (1080, 1920)
        case .p720:  return (720, 1280)
        case .p480:  return (480, 854)
        }
    }
}
