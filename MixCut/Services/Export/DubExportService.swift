import Foundation

/// 单分镜导出规格（值类型，可跨 actor 传递）。
struct DubSegmentSpec: Sendable {
    let videoPath: String
    let startFrame: Int
    let endFrame: Int
    let fps: Double
    let captionLines: [CaptionLine]   // 逐句字幕（相对分镜起点秒）；空=不烧字幕
    let hasHardSubtitle: Bool
    let maskStyleRaw: String
    let maskRect: SubtitleMaskRect
    let isVoiceLocked: Bool
    let dubAudioPath: String?      // 配音段 m4a；锁定/回退段为 nil
    let freezePadFrames: Int
    let trailingSilence: Double
    let bgmAudioPath: String?      // 配音镜头的 BGM 源（整轨 bgm.wav）；nil = 不混 BGM
    /// 该分镜自己的字幕字号比例（逐分镜独立，不再读全局设置）
    let subtitleFontRatio: Double
    /// 全局 BGM 模式：原声段改用整轨纯人声 wav（原视频 stems/vocals.wav）；nil = 常规模式
    let vocalsAudioPath: String?
    /// 人声切片窗（**原视频时间轴**，秒）。替换画面段也用原视频时间——替换片音轨本取自原视频同窗口。
    let vocalsStart: Double
    let vocalsEnd: Double

    init(videoPath: String, startFrame: Int, endFrame: Int, fps: Double,
         captionLines: [CaptionLine], hasHardSubtitle: Bool, maskStyleRaw: String,
         maskRect: SubtitleMaskRect, isVoiceLocked: Bool, dubAudioPath: String?,
         freezePadFrames: Int, trailingSilence: Double, bgmAudioPath: String?,
         subtitleFontRatio: Double,
         vocalsAudioPath: String? = nil, vocalsStart: Double = 0, vocalsEnd: Double = 0) {
        self.videoPath = videoPath; self.startFrame = startFrame; self.endFrame = endFrame
        self.fps = fps; self.captionLines = captionLines; self.hasHardSubtitle = hasHardSubtitle
        self.maskStyleRaw = maskStyleRaw; self.maskRect = maskRect; self.isVoiceLocked = isVoiceLocked
        self.dubAudioPath = dubAudioPath; self.freezePadFrames = freezePadFrames
        self.trailingSilence = trailingSilence; self.bgmAudioPath = bgmAudioPath
        self.subtitleFontRatio = subtitleFontRatio
        self.vocalsAudioPath = vocalsAudioPath; self.vocalsStart = vocalsStart; self.vocalsEnd = vocalsEnd
    }
}

/// 全局 BGM 铺底参数（导出时用户在导出页选中的 BGM）。
struct GlobalBGMSpec: Sendable {
    let audioPath: String
    /// BGM 音量 0…1（UI 默认 0.6）
    let volume: Double
}

/// 配音导出输入（整条成片）。
struct DubExportInput: Sendable {
    let segments: [DubSegmentSpec]
    let maxWidth: Int
    let maxHeight: Int

    /// 从某方案解析出导出输入（必须在 @MainActor 调用）。
    /// - Parameter combo: 每槽选定的变体 dubId（与 orderedSegments 对齐，nil=原声）。
    ///   传 nil 时退回按 SchemeSegment.selectedSegmentDubId 取定（单条/预览一致）。
    ///   nil/锁定/找不到/无音频 → 原声回退。配音段会自动混入分离出的 BGM。
    /// - Parameter useVocalsOnly: 全局 BGM 模式——原声段改用纯人声切片、配音段不混原分离 BGM。
    ///   任一分镜缺 vocals.wav 时返回 nil（预检阶段已保证分离成功；这里是兜底防御，
    ///   绝不静默回退成混音原声——那会悄悄给用户一条 BGM 没去干净的片子）。
    @MainActor
    static func from(scheme: MixScheme, combo: [UUID?]? = nil, useVocalsOnly: Bool = false) -> DubExportInput? {
        let ordered = scheme.orderedSegments
        guard !ordered.isEmpty else { return nil }

        var specs: [DubSegmentSpec] = []
        var maxW = 0, maxH = 0
        for (idx, schemeSeg) in ordered.enumerated() {
            guard let segment = schemeSeg.segment,
                  let video = segment.video else { continue }
            // 走"当前生效画面"：替换版=合成片整段(0..frameCount)；原版=源视频帧区间。音频/字幕仍属分镜本身。
            let ep = segment.effectivePicture
            guard !ep.videoPath.isEmpty, FileManager.default.fileExists(atPath: ep.videoPath) else { continue }

            let fps = ep.fps > 0 ? ep.fps : 30
            maxW = max(maxW, video.width)
            maxH = max(maxH, video.height)

            // 全局 BGM 模式：所有原声段都必须能拿到纯人声源，缺一即整条成片不可导
            var vocalsPath: String? = nil
            if useVocalsOnly {
                guard let vp = Self.vocalsPath(for: video) else {
                    MixLog.error("[Export] 全局 BGM 模式缺少 vocals.wav：\(video.name)")
                    return nil
                }
                vocalsPath = vp
            }

            // 该槽选定的变体：combo 指定优先，否则用 selectedSegmentDubId；nil 或找不到 → 原声
            let chosenId: UUID? = combo != nil ? (idx < combo!.count ? combo![idx] : nil)
                                               : schemeSeg.selectedSegmentDubId
            let chosen: SegmentDub? = chosenId.flatMap { dubId in
                segment.effectiveDubVariants.first { $0.id == dubId }
            }

            if segment.isVoiceLocked || chosen == nil {
                specs.append(DubSegmentSpec(
                    videoPath: ep.videoPath, startFrame: ep.startFrame, endFrame: ep.endFrame,
                    fps: fps, captionLines: [], hasHardSubtitle: false, maskStyleRaw: segment.maskStyleRaw,
                    maskRect: segment.maskRect, isVoiceLocked: true, dubAudioPath: nil,
                    freezePadFrames: 0, trailingSilence: 0, bgmAudioPath: nil,
                    subtitleFontRatio: segment.subtitleFontRatio,
                    vocalsAudioPath: vocalsPath, vocalsStart: segment.startTime, vocalsEnd: segment.endTime))
            } else if let dub = chosen,
                      let audioPath = dub.audioFilePath,
                      FileManager.default.fileExists(atPath: audioPath) {
                // 逐句字幕：优先用对齐好的 captionLines；旧数据无对齐 → 整段一条兜底（等价旧整段烧法，防止老数据丢字幕）
                let capLines: [CaptionLine] = {
                    let lines = dub.captionLines
                    if !lines.isEmpty { return lines }
                    let whole = dub.rewrittenText.isEmpty ? segment.text : dub.rewrittenText
                    return whole.isEmpty ? [] : [CaptionLine(text: whole, start: 0, end: segment.duration)]
                }()
                specs.append(DubSegmentSpec(
                    videoPath: ep.videoPath, startFrame: ep.startFrame, endFrame: ep.endFrame,
                    fps: fps, captionLines: capLines, hasHardSubtitle: segment.hasHardSubtitle, maskStyleRaw: segment.maskStyleRaw,
                    maskRect: segment.maskRect, isVoiceLocked: false, dubAudioPath: audioPath,
                    freezePadFrames: dub.freezePadFrames, trailingSilence: dub.trailingSilence,
                    // 全局 BGM 模式下配音段不再混原视频分离 BGM（配音本身就是纯人声，BGM 最后整片统一铺）
                    bgmAudioPath: useVocalsOnly ? nil : Self.bgmPath(for: video),
                    subtitleFontRatio: segment.subtitleFontRatio))
            } else {
                // 非锁定但无已生成配音 → 回退保留原声原字幕，保证导出不中断
                MixLog.info("分镜 \(segment.segmentIndex) 无已生成配音，回退原声导出")
                // 故意写死 hasHardSubtitle: false：回退段不重配也不烧新字幕，
                // 因此不能遮挡旧硬字幕（否则会把要保留的原字幕也遮掉）。勿改回 segment.hasHardSubtitle。
                specs.append(DubSegmentSpec(
                    videoPath: ep.videoPath, startFrame: ep.startFrame, endFrame: ep.endFrame,
                    fps: fps, captionLines: [], hasHardSubtitle: false, maskStyleRaw: segment.maskStyleRaw,
                    maskRect: segment.maskRect, isVoiceLocked: true, dubAudioPath: nil,
                    freezePadFrames: 0, trailingSilence: 0, bgmAudioPath: nil,
                    subtitleFontRatio: segment.subtitleFontRatio,
                    vocalsAudioPath: vocalsPath, vocalsStart: segment.startTime, vocalsEnd: segment.endTime))
            }
        }
        guard !specs.isEmpty else { return nil }
        return DubExportInput(segments: specs, maxWidth: maxW, maxHeight: maxH)
    }

    /// 配音段的 BGM 源：demucs 分离出的整轨 bgm.wav（按视频内容哈希定位）；不存在 → nil（不混 BGM）。
    private static func bgmPath(for video: Video) -> String? {
        guard let hash = video.contentHash else { return nil }
        let path = FileHelper.stemsDirectory(videoHash: hash).appendingPathComponent("bgm.wav").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// 原声段的纯人声源：demucs 分离出的整轨 vocals.wav；不存在 → nil。
    /// 调用方（全局 BGM 模式）需已在预检阶段完成分离。
    private static func vocalsPath(for video: Video) -> String? {
        guard let hash = video.contentHash else { return nil }
        let path = FileHelper.stemsDirectory(videoHash: hash).appendingPathComponent("vocals.wav").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}

/// 把一个方案展开成「全部配音组合」：每个非锁定分镜可选「原声 + 各已生成改写版」，锁定分镜恒原声。
/// 用于导出时按笛卡尔积一次性导出多条视频。
@MainActor
enum SchemeComboPlanner {
    /// 单方案最多展开的组合数（防爆炸）。
    static let maxCombos = 256

    struct Combo: Sendable {
        let choices: [UUID?]     // 每槽选定 dubId（与 orderedSegments 对齐，nil=原声）
        let nameSuffix: String   // 文件名后缀，如 "[原·A·原·B·A]"
    }

    struct Plan {
        let combos: [Combo]
        let feasibleCount: Int   // 理论组合总数（笛卡尔积）
        let truncated: Bool      // feasibleCount > maxCombos（实际只取了前 maxCombos 条）
    }

    /// 理论组合总数（不真正生成；用于 UI 显示「将生成 N 条」）。
    static func feasibleCount(for scheme: MixScheme) -> Int {
        scheme.orderedSegments.reduce(1) { acc, ss in
            guard let seg = ss.segment else { return acc }
            return acc * seg.combinationSlotCount   // 单一真源（含锁定/兜底/参与过滤）
        }
    }

    static func plan(for scheme: MixScheme) -> Plan {
        let ordered = scheme.orderedSegments
        guard !ordered.isEmpty else { return Plan(combos: [], feasibleCount: 0, truncated: false) }

        let slots: [SlotOptions] = ordered.map { ss in
            guard let seg = ss.segment else { return SlotOptions(isLocked: true, includeOriginal: true, dubIds: []) }
            return SlotOptions(
                isLocked: seg.isVoiceLocked,
                includeOriginal: seg.isVoiceLocked ? true : seg.originalParticipatesInCombination,
                dubIds: seg.isVoiceLocked ? [] : seg.combinationDubVariants.map { $0.id })
        }
        let result = VariantCombinationGenerator.generate(slots: slots, limit: maxCombos)

        let combos: [Combo] = result.combinations.map { choices in
            let parts: [String] = choices.enumerated().map { idx, dubId in
                guard let dubId,
                      idx < ordered.count,
                      let seg = ordered[idx].segment,
                      let dub = seg.effectiveDubVariants.first(where: { $0.id == dubId }) else { return "原" }
                return Self.letter(dub.textVariantIndex)
            }
            return Combo(choices: choices, nameSuffix: "[" + parts.joined(separator: "·") + "]")
        }
        return Plan(combos: combos, feasibleCount: result.feasibleCount, truncated: result.truncated)
    }

    /// 改写版字母：0→A、1→B…
    private static func letter(_ index: Int) -> String {
        guard let scalar = UnicodeScalar(65 + index) else { return "\(index + 1)" }
        return String(Character(scalar))
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
        globalBGM: GlobalBGMSpec? = nil,
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

        // 阶段二：concat 解复用器无损拼接。选了全局 BGM 时先落中间片，再铺底 BGM 到最终输出。
        onProgress?(ExportProgress(phase: .concatenating, progress: 0.88, description: "拼接成片…"))
        let concatTarget = globalBGM == nil
            ? outputPath
            : workDir.appendingPathComponent("voiced.mp4").path
        try await concatCopy(paths: intermediatePaths, workDir: workDir, outputPath: concatTarget)

        if let bgm = globalBGM {
            onProgress?(ExportProgress(phase: .concatenating, progress: 0.95, description: "铺底背景音乐…"))
            try await mixGlobalBGM(voicedPath: concatTarget, bgm: bgm, outputPath: outputPath)
        }

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
        // 逐句字幕：每句一张 PNG，全部先 append（占 input 1..K），dub/bgm 序号随之自动后移。
        var captions: [CaptionOverlay] = []
        var dubAudioInputIndex = 1
        var bgmInputIndex: Int? = nil
        var extraInputs: [String] = []

        let keepOriginalAudio = spec.isVoiceLocked || spec.dubAudioPath == nil

        // 烧录逐句字幕：标点→空格；字号 = 成片宽度 × 该分镜自己的比例。锁定段不烧。
        if !spec.isVoiceLocked, !spec.captionLines.isEmpty {
            let canvasW = max(120, maskPixel.width)      // 字幕画布宽=遮挡区宽（下限 120px 防御逐字竖排）
            // 用**该分镜自己的**字号比例（以前读的是全局设置，界面调了导出却不跟随）
            let fontSize = max(12, Double(outW) * SubtitleFontSize.clamp(spec.subtitleFontRatio))
            let withBackdrop = (mode != .solid)
            for (li, line) in spec.captionLines.enumerated() {
                let burnText = CaptionRenderer.stripPunctuation(line.text)
                guard !burnText.isEmpty else { continue }
                let pngURL = workDir.appendingPathComponent(String(format: "cap_%03d_%02d.png", index, li))
                let img = try CaptionRenderer.renderToFile(
                    text: burnText, canvasWidth: canvasW, withBackdrop: withBackdrop,
                    fontSize: fontSize, to: pngURL)
                let origin = CaptionLayout.overlayOrigin(
                    outputWidth: outW, outputHeight: outH, maskRect: spec.maskRect,
                    captionWidth: img.pixelWidth, captionHeight: img.pixelHeight)
                extraInputs.append(pngURL.path)
                captions.append(CaptionOverlay(inputIndex: extraInputs.count, x: origin.x, y: origin.y,
                                               start: line.start, end: line.end))
            }
        }

        if !keepOriginalAudio, let dubPath = spec.dubAudioPath {
            extraInputs.append(dubPath)
            dubAudioInputIndex = extraInputs.count
            if let bgmPath = spec.bgmAudioPath, FileManager.default.fileExists(atPath: bgmPath) {
                extraInputs.append(bgmPath)
                bgmInputIndex = extraInputs.count
            }
        }

        // 全局 BGM 模式：原声段音频改取整轨纯人声切片。
        // 文件缺失 = 结果达不到「去原 BGM」的承诺，直接报错，绝不回退混音原声。
        var vocalsSource: VocalsSource? = nil
        if keepOriginalAudio, let vocPath = spec.vocalsAudioPath {
            guard FileManager.default.fileExists(atPath: vocPath) else {
                throw ExportError.missingVocals(vocPath)
            }
            extraInputs.append(vocPath)
            vocalsSource = VocalsSource(inputIndex: extraInputs.count,
                                        start: spec.vocalsStart, end: spec.vocalsEnd)
        }

        let graph = DubSegmentGraphBuilder.build(
            mode: mode,
            startFrame: spec.startFrame, endFrame: spec.endFrame, fps: spec.fps,
            outputWidth: outW, outputHeight: outH,
            maskPixel: maskPixel,
            captions: captions,
            keepOriginalAudio: keepOriginalAudio,
            dubAudioInputIndex: dubAudioInputIndex,
            freezePadFrames: spec.freezePadFrames,
            trailingSilence: spec.trailingSilence,
            bgmInputIndex: bgmInputIndex,
            vocalsSource: vocalsSource)

        var args: [String] = ["-y", "-i", spec.videoPath]
        for input in extraInputs { args += ["-i", input] }
        args += ["-filter_complex", graph.filterComplex,
                 "-map", graph.videoMapLabel, "-map", graph.audioMapLabel]

        // 统一硬件编码（中间片参数必须一致，阶段二才能 -c copy）。
        // 配音版导出固定走 h264_videotoolbox，故码率按 .h264Hardware 基准取，
        // 忽略 config.codec——否则软件编码档会落到 videoBitrateKbps 的 default(8000k) 与实际 h264 不匹配。
        let bitrate = config.quality.videoBitrateKbps(for: .h264Hardware)
        // -ac 2：强制所有中间片统一为立体声。否则原声段(立体声)与配音段(人声单声道/amix立体声)
        // 声道数不一致，阶段二 concat -c copy 会以首段为准，声道不符的段被播成静音（原声段无声 bug）。
        args += ["-c:v", "h264_videotoolbox", "-b:v", "\(bitrate)k", "-maxrate", "\(bitrate * 2)k",
                 "-tag:v", "avc1", "-allow_sw", "1", "-pix_fmt", "yuv420p",
                 "-c:a", "aac", "-b:a", "192k", "-ar", "44100", "-ac", "2",
                 "-movflags", "+faststart", outputPath]

        _ = try await ffmpeg.run(arguments: args, totalDuration: nil, onProgress: nil)
    }

    // MARK: - 全局 BGM 铺底

    /// 把选中的 BGM 铺到纯口播成片上：视频流直拷（不重编码），音频 = 口播 + BGM 混音。
    /// BGM 短于成片由 -stream_loop 循环补齐，长于成片由滤镜 atrim 截断，结尾 1 秒淡出。
    private func mixGlobalBGM(voicedPath: String, bgm: GlobalBGMSpec, outputPath: String) async throws {
        guard FileManager.default.fileExists(atPath: bgm.audioPath) else {
            throw ExportError.encodingFailed(
                "背景音乐文件不存在：\((bgm.audioPath as NSString).lastPathComponent)，请回「BGM 库」检查")
        }
        let duration = await probeDuration(voicedPath)
        guard duration > 0 else {
            throw ExportError.encodingFailed("无法读取成片时长，背景音乐铺底失败")
        }
        let graph = GlobalBGMMixGraphBuilder.filterComplex(pieceDuration: duration, bgmVolume: bgm.volume)
        let args = ["-y", "-i", voicedPath,
                    "-stream_loop", "-1", "-i", bgm.audioPath,
                    "-filter_complex", graph,
                    "-map", "0:v", "-map", "[aout]",
                    "-c:v", "copy",
                    "-c:a", "aac", "-b:a", "192k", "-ar", "44100", "-ac", "2",
                    "-movflags", "+faststart", outputPath]
        _ = try await ffmpeg.run(arguments: args, totalDuration: nil, onProgress: nil)
    }

    /// 读容器时长（秒）；失败返回 0。
    private func probeDuration(_ path: String) async -> Double {
        let out = try? await ffmpeg.runProbe(arguments: [
            "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path])
        return Double((out ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    // MARK: - 阶段二拼接

    private func concatCopy(paths: [String], workDir: URL, outputPath: String) async throws {
        let listURL = workDir.appendingPathComponent("list.txt")
        let body = paths.map { "file '\($0)'" }.joined(separator: "\n") + "\n"
        try body.write(to: listURL, atomically: true, encoding: .utf8)

        // 阶段二a：concat 无损拼接到临时文件
        let joined = workDir.appendingPathComponent("joined.mp4")
        let concatArgs = ["-y", "-f", "concat", "-safe", "0", "-i", listURL.path,
                          "-c", "copy", "-movflags", "+faststart", joined.path]
        _ = try await ffmpeg.run(arguments: concatArgs, totalDuration: nil, onProgress: nil)

        // 阶段二b：concat 会把首段 AAC 编码 priming 延迟转成视频起始时间偏移（start_time≈0.023s）。
        // 后果：t=0 处无帧 → QuickTime/各平台上传时截「首帧做封面」会得到黑图（实测 AVFoundation
        // 在 t=0 直接报 -11832 取不到帧）。这里把视频起始时间整体平移回 0，封面即为真实首帧。
        let startTime = await probeVideoStartTime(joined.path)
        if startTime > 0.001 {
            let fixArgs = ["-y", "-i", joined.path, "-c", "copy",
                           "-output_ts_offset", String(format: "%.6f", -startTime),
                           "-movflags", "+faststart", outputPath]
            _ = try await ffmpeg.run(arguments: fixArgs, totalDuration: nil, onProgress: nil)
            try? FileManager.default.removeItem(at: joined)
        } else {
            try? FileManager.default.removeItem(atPath: outputPath)
            try FileManager.default.moveItem(at: joined, to: URL(fileURLWithPath: outputPath))
        }
    }

    /// 读取视频流起始时间（秒）；失败返回 0。
    private func probeVideoStartTime(_ path: String) async -> Double {
        let out = try? await ffmpeg.runProbe(arguments: [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=start_time", "-of", "csv=p=0", path])
        return Double((out ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
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
