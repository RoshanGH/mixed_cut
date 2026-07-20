import Foundation
import SwiftData
import AVFoundation
import UniformTypeIdentifiers
import CryptoKit

/// 导入阶段
enum ImportPhase: String {
    case idle = "等待导入"
    case copying = "复制文件中"
    case extractingMetadata = "提取元数据"
    case generatingThumbnail = "生成缩略图"
    case detectingScenes = "检测镜头"
    case transcribing = "语音识别"
    case analyzing = "AI 语义分析"
    case optimizing = "优化边界"
    case completed = "完成"
    case failed = "失败"
}

/// 视频导入及分析 ViewModel
@MainActor
@Observable
final class ImportViewModel {
    var phase: ImportPhase = .idle
    var progress: Double = 0
    var progressDescription: String = ""
    var isProcessing = false
    var errorMessage: String?

    /// 已取消的视频 ID（删除视频时加入，用于跳过后续处理）
    private var cancelledVideoIDs: Set<UUID> = []

    private var modelContext: ModelContext?
    private let ffmpeg = FFmpegRunner()
    private let asrAliyun = QwenASRClient()

    /// 正在用阿里整片重识别的视频（控制卡片 loading）。
    var reidentifyingVideoIDs: Set<UUID> = []

    private let sceneDetection = SceneDetectionService()
    private let asrService = ASRService()
    private let aiAnalysis = AIAnalysisService()
    private let boundaryOptimizer = BoundaryOptimizerService()

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    /// 用户主动停止导入。
    ///
    /// ⚠️ 这里**只做提示**，不直接改 isProcessing/phase —— 因为后台流程可能正跑在某一步，
    /// 随后会把这些状态又写回"运行中"，造成"点了停止却还在转"的假象。
    /// 真正的收尾统一由 `importVideos` 内部的取消检查点走 `finishAsCancelled` 完成。
    func markCancelledByUser() {
        progressDescription = "正在停止…"
        ToastCenter.shared.show("正在停止导入，已完成的素材会保留", icon: "stop.circle.fill", style: .info)
    }

    /// 取消后的统一收尾：把状态收回闲置态，项目回到可用状态。
    private func finishAsCancelled(project: Project, context: ModelContext) {
        project.status = .ready
        project.updatedAt = Date()
        context.safeSave()
        isProcessing = false
        phase = .idle
        progress = 0
        progressDescription = ""
        MixLog.info("[Import] 用户停止导入，已完成部分保留")
        ToastCenter.shared.show("已停止导入，已完成的素材已保留", icon: "stop.circle.fill", style: .info)
    }

    /// 导入视频文件列表（全局去重 + 共享引用）
    func importVideos(urls: [URL], to project: Project) async {
        isProcessing = true
        errorMessage = nil

        // 去重：检查该视频是否已在当前项目中
        var dedupedURLs: [URL] = []
        var skippedNames: [String] = []

        for url in urls {
            if isDuplicate(url: url, in: project) {
                skippedNames.append(url.lastPathComponent)
            } else {
                dedupedURLs.append(url)
            }
        }

        if !skippedNames.isEmpty {
            let skippedList = skippedNames.joined(separator: "、")
            if dedupedURLs.isEmpty {
                errorMessage = "所有视频均已导入过：\(skippedList)"
                isProcessing = false
                phase = .completed
                progress = 1.0
                return
            } else {
                errorMessage = "已跳过重复视频：\(skippedList)"
            }
        }

        // 检查磁盘可用空间
        let totalFileSize = dedupedURLs.compactMap { url in
            try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
        }.reduce(0, +)
        let requiredSpace = totalFileSize * 2
        if let availableSpace = try? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage,
           availableSpace < requiredSpace {
            let needed = ByteCountFormatter.string(fromByteCount: requiredSpace, countStyle: .file)
            let available = ByteCountFormatter.string(fromByteCount: availableSpace, countStyle: .file)
            errorMessage = "磁盘空间不足：需要约 \(needed)，当前可用 \(available)"
            isProcessing = false
            return
        }

        guard let context = modelContext else { return }

        project.status = .importing
        context.safeSave()

        // ========== 阶段 1：快速创建/关联视频实体 ==========
        var videosToAnalyze: [Video] = []
        for (index, url) in dedupedURLs.enumerated() {
            // 用户点了「停止导入」：立刻停手，已导入的保留（停止 ≠ 删除）
            if Task.isCancelled { finishAsCancelled(project: project, context: context); return }
            progressDescription = "导入第 \(index + 1)/\(dedupedURLs.count) 个视频..."
            progress = Double(index) / Double(dedupedURLs.count) * 0.2

            do {
                let (video, needsAnalysis) = try await importOrLinkVideo(url: url, to: project)
                if needsAnalysis {
                    videosToAnalyze.append(video)
                } else {
                    MixLog.info(" 视频已存在且已分析，直接关联: \(video.name)")
                }
            } catch {
                let prevError = errorMessage.map { $0 + "\n" } ?? ""
                errorMessage = prevError + "导入 \(url.lastPathComponent) 失败: \(FriendlyError.reason(for: error))"
            }
        }

        // ========== 阶段 2：并行执行视频分析 ==========
        if !videosToAnalyze.isEmpty {
            project.status = .analyzing
            // 先把所有待分析视频标为「等待中」，否则排在 maxConcurrency 之后的视频
            // status 仍是 .imported，UI 会显示成「孤立未分析」并出现错误的「AI 分析」按钮
            // analyzeVideo 入口第一步会把 status 覆盖为 .detectingScenes
            for v in videosToAnalyze {
                v.status = .queued
            }
            context.safeSave()

            let totalVideos = videosToAnalyze.count
            var completedCount = 0
            // 使用 ConcurrencyPolicy 而非硬编码，自动按 Apple Silicon Media Engine 数适配
            let maxConcurrency = min(ConcurrencyPolicy.maxAnalyzeConcurrency(), totalVideos)

            progressDescription = "并行分析 \(totalVideos) 个视频（\(maxConcurrency) 路并发）..."

            await withTaskGroup(of: Void.self) { group in
                var videoIterator = videosToAnalyze.makeIterator()
                var runningCount = 0

                while !Task.isCancelled, runningCount < maxConcurrency, let video = videoIterator.next() {
                    runningCount += 1
                    group.addTask { [weak self] in
                        guard let self else { return }
                        do {
                            try await self.analyzeVideo(video)
                        } catch is CancellationError {
                            // 用户删除视频，跳过
                        } catch {
                            await self.handleAnalyzeFailure(video: video, error: error)
                        }
                    }
                }

                for await _ in group {
                    if Task.isCancelled { break }   // 已停止：不再补新任务，让已在跑的自然收尾
                    completedCount += 1
                    progress = 0.2 + Double(completedCount) / Double(totalVideos) * 0.8
                    progressDescription = "已完成 \(completedCount)/\(totalVideos) 个视频分析"

                    if let nextVideo = videoIterator.next() {
                        group.addTask { [weak self] in
                            guard let self else { return }
                            do {
                                try await self.analyzeVideo(nextVideo)
                            } catch is CancellationError {
                                // 用户删除视频，跳过
                            } catch {
                                await self.handleAnalyzeFailure(video: nextVideo, error: error)
                            }
                        }
                    }
                }
            }
        }

        if Task.isCancelled { finishAsCancelled(project: project, context: context); return }

        project.status = .ready
        project.updatedAt = Date()
        context.safeSave()

        phase = .completed
        progress = 1.0
        isProcessing = false

        let totalDone = videosToAnalyze.count
        if totalDone > 0 {
            ToastCenter.shared.show("已分析完成 \(totalDone) 个视频", icon: "checkmark.seal.fill", style: .success)
        }
    }

    /// 仅重新跑 ASR（用于 ASR 输出粒度异常时用户主动触发）
    /// 重做完后会自动连带重做 AI 分析（因为 sentence 变了 → AI 切分也要变）
    func retryASR(for video: Video, in project: Project) async {
        guard let context = modelContext else { return }
        MixLog.info("retryASR 被调用: video=\(video.name)")

        // 清空旧的 ASR 数据 → analyzeVideo 流程中 retryAIAnalysis 会重新识别
        video.transcript = ""
        video.asrWords = []
        video.asrSentences = []

        // 清空旧分镜（避免 UI 卡在中间态）
        // ⚠️ 必须先 Array(...) 快照再迭代 delete，直接迭代 to-many 关系会行为未定义
        // Segment.schemeSegments 已设 @Relationship(.cascade)，删 Segment 时 SchemeSegment 自动级联删
        for oldSeg in Array(video.segments) {
            context.delete(oldSeg)
        }
        video.status = .transcribing
        video.errorMessage = nil
        errorMessage = nil
        context.safeSave()

        // 跑完整重试链
        await retryAIAnalysis(for: video, in: project)
    }

    /// 重试 AI 分析
    func retryAIAnalysis(for video: Video, in project: Project) async {
        MixLog.info("retryAIAnalysis 被调用: video=\(video.name)")
        guard let context = modelContext else {
            MixLog.error("modelContext 为 nil！无法重试")
            return
        }
        video.status = .analyzing
        video.errorMessage = nil
        errorMessage = nil
        context.safeSave()

        let asrText = video.transcript ?? ""
        let asrWords = video.asrWords

        let asr: TranscriptionResult
        if asrText.isEmpty && asrWords.isEmpty {
            MixLog.info(" ASR 数据为空，重新执行语音识别...")
            phase = .transcribing
            video.status = .transcribing
            context.safeSave()
            do {
                asr = try await asrService.transcribe(videoPath: video.localPath)
                video.transcript = asr.text
                video.asrWords = asr.words
                video.asrSentences = asr.rawSentences
                context.safeSave()
            } catch {
                MixLog.error(" ASR 失败: \(error)")
                video.errorMessage = "语音识别失败: \(FriendlyError.reason(for: error))"
                video.status = .imported
                context.safeSave()
                isProcessing = false
                phase = .idle
                return
            }
        } else {
            asr = TranscriptionResult(
                text: asrText,
                words: asrWords,
                rawSentences: video.asrSentences,
                language: "zh",
                duration: video.duration
            )
        }

        phase = .detectingScenes
        var localAnalysis: VideoLocalAnalysis
        do {
            localAnalysis = try await sceneDetection.analyzeLocally(
                videoPath: video.localPath,
                duration: video.duration,
                fps: video.fps > 0 ? video.fps : 30
            )
        } catch {
            localAnalysis = VideoLocalAnalysis(
                sceneBoundaries: [], silencePeriods: [], iframePositions: [],
                videoDuration: video.duration, fps: video.fps > 0 ? video.fps : 30
            )
        }

        phase = .analyzing
        video.status = .analyzing
        context.safeSave()

        let freshAIAnalysis = AIAnalysisService()
        var analysisResult: AISegmentationResult?
        do {
            analysisResult = try await freshAIAnalysis.analyzeVideo(
                videoId: video.name,
                transcript: asr,
                sceneBoundaries: localAnalysis.sceneBoundaries,
                localAnalysis: localAnalysis
            )
        } catch {
            video.errorMessage = "AI 分析失败: \(FriendlyError.reason(for: error))"
            video.status = .imported
            context.safeSave()
            isProcessing = false
            phase = .idle
            return
        }

        if let analysisResult {
            phase = .optimizing

            for oldSeg in video.segments {
                context.delete(oldSeg)
            }

            createSegments(
                from: analysisResult,
                asr: asr,
                localAnalysis: localAnalysis,
                video: video,
                context: context
            )

            // 台词以「逐分镜各自切音频独立 ASR」为准覆盖：整片流式 ASR 绝对时间戳会漂移、
            // 按整片时间戳切出的分镜台词会错位；单段短音频 ASR 永远准。边界已由本地场景/静音+AI 定好，
            // 这里只重识别各分镜台词（失败段保留 createSegments 给的原文/AI 文本）。
            phase = .transcribing
            await reidentifySegmentTexts(video: video, context: context)

            await generateSegmentThumbnails(
                segments: video.segments,
                videoPath: video.localPath
            )

            video.status = .completed
            video.errorMessage = nil
        }

        context.safeSave()
        phase = .completed
        isProcessing = false
    }

    // MARK: - 核心导入逻辑

    /// 导入或关联视频：先查全局是否已有同一视频，有则直接关联，无则创建新的
    /// 返回 (video, needsAnalysis) — needsAnalysis=false 表示已有完整分析数据
    private func importOrLinkVideo(url: URL, to project: Project) async throws -> (Video, Bool) {
        guard let context = modelContext else {
            throw NSError(domain: "MixCut", code: -1, userInfo: [NSLocalizedDescriptionKey: "数据库未就绪"])
        }

        phase = .copying

        // 先计算文件 hash
        let hash = Self.computeFileHash(path: url.path)

        // 查找全局是否已有同 hash 的视频
        if let hash, let existingVideo = findExistingVideo(hash: hash, context: context) {
            // 已有此视频，直接创建 ProjectVideo 关联
            let pv = ProjectVideo(project: project, video: existingVideo)
            context.insert(pv)
            context.safeSave()
            MixLog.info(" 全局已有视频「\(existingVideo.name)」(hash=\(hash.prefix(8))...)，直接关联到项目")

            let needsAnalysis = existingVideo.status != .completed || existingVideo.segments.isEmpty
            return (existingVideo, needsAnalysis)
        }

        // 全局没有，创建新的
        let destURL: URL
        if let hash {
            destURL = try FileHelper.copyVideoToGlobal(from: url, contentHash: hash)
        } else {
            // hash 计算失败（极端情况），用 UUID 作为目录名
            destURL = try FileHelper.copyVideoToGlobal(from: url, contentHash: UUID().uuidString)
        }

        let video = Video(name: url.lastPathComponent, localPath: destURL.path)
        video.status = .imported
        video.contentHash = hash
        context.insert(video)

        // 创建 ProjectVideo 关联
        let pv = ProjectVideo(project: project, video: video)
        context.insert(pv)
        context.safeSave()

        // 提取元数据（失败不阻塞）
        do {
            try await extractMetadata(for: video, at: destURL)
        } catch {
            video.errorMessage = "元数据提取失败: \(FriendlyError.reason(for: error))"
        }

        // 生成视频缩略图（失败不阻塞）
        do {
            try await generateVideoThumbnail(for: video)
        } catch {
            MixLog.error("缩略图生成失败: video=\(video.name), error=\(error)")
        }

        context.safeSave()
        return (video, true)
    }

    /// 自建分镜单条时长上限（秒）。改这一个常量即可，文案会跟着走。
    static let selfSegmentMaxDuration: Double = 30

    /// 上传自建分镜：每个文件 = 一个分镜（不切分），只做 ASR 台词提取 + AI 只打标。
    /// 处理态用载体视频的 status 驱动占位卡（transcribing/analyzing/completed）。见 PRD/TRD 05。
    func importSelfSegments(urls: [URL], into project: Project, onUpdate: @escaping @MainActor () -> Void = {}) async {
        guard let context = modelContext else { return }
        var skippedLong: [String] = []
        var skippedDup = 0
        // ⚠️ 以下两类失败以前是静默 `continue`，文件会**凭空消失**、用户毫无解释。
        var failedUnreadable: [String] = []   // 读不出时长：文件损坏 / 格式不支持
        var failedCopy: [String] = []         // 落盘失败：磁盘满 / 无权限 / 外接盘拔出
        for url in urls {
            // 1) 时长校验（上限见 selfSegmentMaxDuration）
            let asset = AVURLAsset(url: url)
            let dur = (try? await asset.load(.duration))?.seconds ?? 0
            guard dur > 0 else { failedUnreadable.append(url.lastPathComponent); continue }
            guard dur <= Self.selfSegmentMaxDuration else { skippedLong.append(url.lastPathComponent); continue }

            // 2) 去重
            let hash = Self.computeFileHash(path: url.path)
            if let hash, findExistingVideo(hash: hash, context: context) != nil { skippedDup += 1; continue }

            // 3) 落盘 + 建载体视频（打「自建」标记；status 作处理态）
            guard let destURL = try? FileHelper.copyVideoToGlobal(from: url, contentHash: hash ?? UUID().uuidString) else {
                failedCopy.append(url.lastPathComponent)
                continue
            }
            let video = Video(name: url.lastPathComponent, localPath: destURL.path)
            video.contentHash = hash
            video.isUserUploaded = true
            video.status = .transcribing
            context.insert(video)
            context.insert(ProjectVideo(project: project, video: video))
            context.safeSave()

            // 4) 元数据 + 整片首帧缩略图（失败不阻塞）
            try? await extractMetadata(for: video, at: destURL)
            try? await generateVideoThumbnail(for: video)

            // 5) 建「覆盖整片」的分镜
            let fps = video.fps > 0 ? video.fps : 30
            let endFrame = max(1, Int((video.duration * fps).rounded()))
            let seg = Segment(segmentIndex: "seg_001", startTime: 0, endTime: video.duration,
                              text: "", semanticTypes: [], positionType: .opening)
            seg.video = video
            seg.setFrameRange(startFrame: 0, endFrame: endFrame, fps: fps)
            seg.thumbnailPath = video.thumbnailPath
            context.insert(seg)
            context.safeSave()
            onUpdate()   // 占位卡「识别中…」出现

            // 6) ASR 台词（whisper 整片；失败留空，可后续手填/重识别）
            if let asr = try? await asrService.transcribe(videoPath: destURL.path) {
                seg.text = asr.text
                context.safeSave()
            }

            // 7) AI 只打标（不切分）；失败给默认「过渡」
            video.status = .analyzing
            context.safeSave()
            onUpdate()   // 占位卡切「打标中…」
            if !seg.text.isEmpty, let tags = try? await aiAnalysis.tagSingleSegment(text: seg.text) {
                seg.semanticTypes = tags.types
                seg.positionType = tags.position
                seg.keywords = tags.keywords
            } else if seg.semanticTypes.isEmpty {
                seg.semanticTypes = [.transition]
            }

            // 8) 就绪
            video.status = .completed
            context.safeSave()
            onUpdate()   // 占位卡转正常分镜卡
        }
        if !skippedLong.isEmpty {
            ToastCenter.shared.show("\(skippedLong.count) 个文件超过 \(Int(Self.selfSegmentMaxDuration)) 秒已跳过", icon: "exclamationmark.triangle.fill")
        }
        if skippedDup > 0 {
            ToastCenter.shared.show("\(skippedDup) 个已存在，已跳过", icon: "info.circle.fill")
        }
        // 真失败必须出声，且说明原因与下一步——不能让文件无声无息地消失
        if !failedUnreadable.isEmpty {
            ToastCenter.shared.show("\(failedUnreadable.count) 个文件无法读取（已损坏或格式不支持），未导入：\(failedUnreadable.prefix(3).joined(separator: "、"))",
                                    icon: "exclamationmark.triangle.fill", style: .warning, duration: 5)
        }
        if !failedCopy.isEmpty {
            ToastCenter.shared.show("\(failedCopy.count) 个文件保存失败（磁盘空间不足或无写入权限），未导入：\(failedCopy.prefix(3).joined(separator: "、"))",
                                    icon: "exclamationmark.triangle.fill", style: .warning, duration: 5)
        }
    }

    /// 执行视频分析（场景检测 + ASR + AI 分析 + 边界优化）
    private func analyzeVideo(_ video: Video) async throws {
        guard let context = modelContext else { return }

        try checkCancelled(video)

        // Step 1: 本地视频分析
        video.status = .detectingScenes
        context.safeSave()
        phase = .detectingScenes

        var localAnalysis = VideoLocalAnalysis(
            sceneBoundaries: [], silencePeriods: [], iframePositions: [],
            videoDuration: video.duration, fps: video.fps > 0 ? video.fps : 30
        )
        do {
            localAnalysis = try await sceneDetection.analyzeLocally(
                videoPath: video.localPath,
                duration: video.duration,
                fps: video.fps > 0 ? video.fps : 30
            )
        } catch {
            video.errorMessage = (video.errorMessage ?? "") + "\n本地分析失败: \(FriendlyError.reason(for: error))"
        }

        try checkCancelled(video)

        // Step 2: ASR 语音识别
        phase = .transcribing
        video.status = .transcribing
        context.safeSave()

        var asr: TranscriptionResult = .empty()
        do {
            asr = try await asrService.transcribe(videoPath: video.localPath)
        } catch {
            let detail = "\(error)"
            MixLog.error("ASR 异常: \(detail)")
            video.errorMessage = (video.errorMessage ?? "") + "\n语音识别失败: \(FriendlyError.reason(for: error))"
        }

        video.transcript = asr.text
        video.asrWords = asr.words
        video.asrSentences = asr.rawSentences
        context.safeSave()

        try checkCancelled(video)

        // Step 3: AI 语义分析
        phase = .analyzing
        video.status = .analyzing
        context.safeSave()

        let activeProvider = KeychainHelper.activeProvider
        MixLog.info(" AI 分析开始: provider=\(activeProvider.displayName)")

        var analysisResult: AISegmentationResult?
        do {
            analysisResult = try await aiAnalysis.analyzeVideo(
                videoId: video.name,
                transcript: asr,
                sceneBoundaries: localAnalysis.sceneBoundaries,
                localAnalysis: localAnalysis
            )
        } catch {
            let errMsg = error.localizedDescription
            if errMsg.contains("API Key") || errMsg.contains("api") || errMsg.contains("key") || errMsg.contains("未配置") {
                video.errorMessage = (video.errorMessage ?? "") + "\nAI 分析跳过：请先在「设置」中配置 API Key"
            } else {
                video.errorMessage = (video.errorMessage ?? "") + "\nAI 分析失败: \(errMsg)"
            }
        }

        try checkCancelled(video)

        // Step 4+5: 边界优化 + 创建分镜
        if let analysisResult {
            phase = .optimizing

            createSegments(
                from: analysisResult,
                asr: asr,
                localAnalysis: localAnalysis,
                video: video,
                context: context
            )

            // 台词以「逐分镜各自切音频独立 ASR」为准覆盖：整片流式 ASR 绝对时间戳会漂移、
            // 按整片时间戳切出的分镜台词会错位；单段短音频 ASR 永远准。边界已由本地场景/静音+AI 定好，
            // 这里只重识别各分镜台词（失败段保留 createSegments 给的原文/AI 文本）。
            phase = .transcribing
            await reidentifySegmentTexts(video: video, context: context)

            await generateSegmentThumbnails(
                segments: video.segments,
                videoPath: video.localPath
            )

            video.status = .completed
        } else {
            video.status = .failed
            video.errorMessage = (video.errorMessage ?? "") + "\nAI 分析未产出有效结果"
        }

        context.safeSave()
        MixLog.info(" 分析完成: video=\(video.name), status=\(video.status)")
    }

    /// 从 AI 结果创建分镜
    private func createSegments(
        from analysisResult: AISegmentationResult,
        asr: TranscriptionResult,
        localAnalysis: VideoLocalAnalysis,
        video: Video,
        context: ModelContext
    ) {
        let boundaries = analysisResult.segments.map(\.endTime)
        let (optimizedBoundaries, _) = boundaryOptimizer.optimize(
            boundaries: boundaries,
            asrSentences: asr.sentences,
            localAnalysis: localAnalysis
        )

        let asrWords = asr.words
        let videoDuration = video.duration
        var createdSegments: [Segment] = []
        for (i, aiSeg) in analysisResult.segments.enumerated() {
            var adjustedEnd = i < optimizedBoundaries.count ? optimizedBoundaries[i] : aiSeg.endTime
            let adjustedStart: Double
            if i == 0 {
                adjustedStart = 0.0
            } else if i - 1 < optimizedBoundaries.count {
                adjustedStart = optimizedBoundaries[i - 1]
            } else {
                adjustedStart = aiSeg.startTime
            }
            if i == analysisResult.segments.count - 1 && videoDuration > 0 {
                adjustedEnd = videoDuration
            }

            let extractedText = Self.extractTextFromASR(
                words: asrWords, startTime: adjustedStart, endTime: adjustedEnd
            )
            let finalText = extractedText.isEmpty ? aiSeg.text : extractedText

            let globalIndex = String(format: "seg_%03d", i + 1)
            let segment = Segment(
                segmentIndex: globalIndex,
                startTime: adjustedStart,
                endTime: adjustedEnd,
                text: finalText,
                semanticTypes: aiSeg.types.map { Self.normalizeSemanticType($0) },
                positionType: Self.normalizePositionType(aiSeg.position),
                qualityScore: aiSeg.dataQuality.score
            )
            segment.qualityReasoning = aiSeg.dataQuality.reasoning
            segment.keywords = aiSeg.keywords
            segment.video = video
            context.insert(segment)
            // 帧化：把秒边界 round 成帧号作为真相（永不差帧）
            if video.fps > 0 {
                segment.setFrameRange(
                    startFrame: FrameTime.frame(seconds: adjustedStart, fps: video.fps),
                    endFrame: FrameTime.frame(seconds: adjustedEnd, fps: video.fps),
                    fps: video.fps
                )
            }
            createdSegments.append(segment)
        }

        Self.mergeShortSegments(&createdSegments, minDuration: 2.0, context: context)
    }

    // MARK: - 视频删除（解除关联 vs 真删除）

    /// 从项目中移除视频（解除关联）
    /// 仅当视频不被任何项目引用时，才真正删除 Video + Segment + 磁盘文件
    /// 删除视频（延迟删除 + 撤销浮条）
    func deleteVideo(_ video: Video, from project: Project) {
        guard modelContext != nil else { return }
        let videoID = video.id
        // 立即取消该视频的后台处理（删除意图）
        cancelledVideoIDs.insert(videoID)

        // 界面隐藏：从 project.projectVideos 摘除该视频的关联（ImportView 读 project.videos）。
        // pv 对象此刻不删，到 commit 时再真删。
        let pvsToHide = project.projectVideos.filter { $0.video?.id == videoID }
        let pvIDs = Set(pvsToHide.map(\.id))
        project.projectVideos.removeAll { pvIDs.contains($0.id) }

        PendingDeletionCenter.shared.schedule(
            message: "已删除视频",
            commit: { [weak self] in
                guard let context = self?.modelContext else { return }
                // 先真删关联 pv，再判断该视频是否还被其它项目引用
                for pv in pvsToHide { context.delete(pv) }
                context.safeSave()
                if video.projectVideos.isEmpty {
                    // 无任何项目引用，删除视频 + 分镜 + SchemeSegment「记录」；磁盘文件交孤儿 GC
                    let segmentsToDelete = Array(video.segments)
                    for segment in segmentsToDelete {
                        for ss in Array(segment.schemeSegments) { context.delete(ss) }
                        context.delete(segment)
                    }
                    context.delete(video)
                    context.safeSave()
                    MixLog.info(" 视频无引用，已删除记录: \(video.name)")
                } else {
                    MixLog.info(" 视频仍被其它项目引用，仅解除关联: \(video.name)")
                }
            },
            undo: { [weak self] in
                guard let self else { return }
                self.cancelledVideoIDs.remove(videoID)   // 恢复处理资格
                project.projectVideos.append(contentsOf: pvsToHide)   // 放回关联
            }
        )
    }

    // MARK: - 全局视频查找

    /// 查找全局已有的同 hash 视频
    private func findExistingVideo(hash: String, context: ModelContext) -> Video? {
        let descriptor = FetchDescriptor<Video>(
            predicate: #Predicate<Video> { video in
                video.contentHash == hash
            }
        )
        guard let videos = try? context.fetch(descriptor) else { return nil }
        return videos.first
    }

    /// 检测视频是否已在当前项目中
    private func isDuplicate(url: URL, in project: Project) -> Bool {
        let fileName = url.lastPathComponent

        // 先按文件名检查（最快）
        if project.videos.contains(where: { $0.name == fileName }) {
            return true
        }

        // 再按 hash 检查（最准确）
        if let hash = Self.computeFileHash(path: url.path) {
            return project.videos.contains { $0.contentHash == hash }
        }

        return false
    }

    // MARK: - 工具方法

    /// 归一化 AI 返回的语义类型字符串
    static func normalizeSemanticType(_ raw: String) -> SemanticType {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let exact = SemanticType(rawValue: cleaned) {
            return exact
        }

        let mapping: [(keywords: [String], type: SemanticType)] = [
            (["噱头", "hook", "开场", "引入", "吸引"], .hook),
            (["痛点", "pain", "问题", "烦恼"], .painPoint),
            (["产品方案", "solution", "产品介绍", "成分", "功能"], .solution),
            (["效果展示", "effect", "result", "对比", "变化"], .results),
            (["信任背书", "social proof", "用户评价", "品牌", "背书", "见证"], .socialProof),
            (["价格对比", "price", "性价比", "价格"], .priceAnchor),
            (["活动福利", "promotion", "优惠", "福利", "折扣", "赠品"], .promotion),
            (["行动号召", "call to action", "cta", "购买", "下单", "直播间"], .callToAction),
            (["产品定位", "positioning", "适用", "人群"], .productPositioning),
            (["产品使用教育", "usage", "使用方法", "教育", "使用场景"], .usageEducation),
            (["过渡", "transition", "衔接", "转场"], .transition),
        ]

        let lower = cleaned.lowercased()
        for (keywords, type) in mapping {
            if keywords.contains(where: { lower.contains($0.lowercased()) }) {
                return type
            }
        }

        MixLog.error(" 未识别的语义类型: \"\(raw)\"，降级为 .transition")
        return .transition
    }

    /// 归一化位置类型
    private static func normalizePositionType(_ raw: String) -> PositionType {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = PositionType(rawValue: cleaned) { return exact }
        let lower = cleaned.lowercased()
        if lower.contains("开头") || lower.contains("opening") { return .opening }
        if lower.contains("结尾") || lower.contains("ending") { return .ending }
        return .middle
    }

    /// 合并过短的分镜到相邻分镜
    private static func mergeShortSegments(
        _ segments: inout [Segment],
        minDuration: Double,
        context: ModelContext
    ) {
        var i = 0
        while i < segments.count {
            let seg = segments[i]
            guard seg.duration < minDuration, segments.count > 1 else {
                i += 1
                continue
            }

            if i > 0 {
                let prev = segments[i - 1]
                if let fps = prev.video?.fps, fps > 0 {
                    prev.setFrameRange(startFrame: prev.startFrame, endFrame: seg.endFrame, fps: fps)
                } else {
                    prev.endTime = seg.endTime
                }
                prev.text = prev.text + seg.text
                var kw = prev.keywords
                for k in seg.keywords where !kw.contains(k) { kw.append(k) }
                prev.keywords = kw
                context.delete(seg)
                segments.remove(at: i)
            } else if segments.count > 1 {
                let next = segments[1]
                if let fps = next.video?.fps, fps > 0 {
                    next.setFrameRange(startFrame: seg.startFrame, endFrame: next.endFrame, fps: fps)
                } else {
                    next.startTime = seg.startTime
                }
                next.text = seg.text + next.text
                context.delete(seg)
                segments.remove(at: 0)
            } else {
                i += 1
            }
        }
    }

    /// 根据时间范围从 ASR words 中精确提取台词
    private static func extractTextFromASR(
        words: [ASRWord],
        startTime: Double,
        endTime: Double
    ) -> String {
        let matched = words.filter { w in
            let center = (w.start + w.end) / 2
            return center >= startTime && center < endTime
        }
        let text = matched.map(\.word).joined()
        var cleaned = text
            .replacingOccurrences(of: "\u{FFFD}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }
        return cleaned
    }

    /// 任务组里发生未捕获异常时的兜底：避免视频卡在中间态
    private func handleAnalyzeFailure(video: Video, error: Error) {
        if video.status == .queued || video.status == .detectingScenes || video.status == .transcribing || video.status == .analyzing {
            let detail = error.localizedDescription
            video.errorMessage = (video.errorMessage ?? "") + "\n分析失败: \(detail)"
            video.status = .failed
            modelContext?.safeSave()
            MixLog.error(" 兜底标记失败: video=\(video.name), error=\(detail)")
        }
        let prevError = errorMessage.map { $0 + "\n" } ?? ""
        errorMessage = prevError + "分析 \(video.name) 失败: \(FriendlyError.reason(for: error))"
    }

    private func checkCancelled(_ video: Video) throws {
        if cancelledVideoIDs.contains(video.id) {
            cancelledVideoIDs.remove(video.id)
            throw CancellationError()
        }
    }

    /// 使用 AVFoundation 提取视频元数据
    private func extractMetadata(for video: Video, at url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        video.duration = CMTimeGetSeconds(duration)

        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let transformedSize = size.applying(transform)
            video.width = Int(abs(transformedSize.width))
            video.height = Int(abs(transformedSize.height))

            let rate = try await track.load(.nominalFrameRate)
            video.fps = Double(rate)
        }
    }

    /// 为分镜列表生成缩略图（全局目录）
    private func generateSegmentThumbnails(
        segments: [Segment],
        videoPath: String
    ) async {
        let thumbDir = FileHelper.globalThumbnailDirectory

        // IV-13：返回 segment.id 而非数组 index，避免 SwiftData fault 导致 segments 顺序变动时
        // 把缩略图写到错误的 Segment 上（A 的缩略图变成 B 的画面 → 用户感知最强 bug 之一）
        let segmentByID: [UUID: Segment] = Dictionary(
            segments.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        await withTaskGroup(of: (UUID, String?).self) { group in
            for segment in segments {
                // 已有缩略图则跳过
                if let existing = segment.thumbnailPath,
                   FileManager.default.fileExists(atPath: existing) {
                    continue
                }
                let segID = segment.id
                // 用「分镜首帧」(startTime + 100ms 偏移避免转场/黑帧) 作为缩略图
                let firstFrameTime = max(0, segment.startTime + 0.1)
                let thumbPath = thumbDir.appendingPathComponent("seg_\(segID.uuidString).jpg").path
                group.addTask { [ffmpeg] in
                    do {
                        try await ffmpeg.generateThumbnail(from: videoPath, at: firstFrameTime, to: thumbPath)
                        return (segID, thumbPath)
                    } catch {
                        return (segID, nil)
                    }
                }
            }

            for await (segID, path) in group {
                if let path, let segment = segmentByID[segID] {
                    segment.thumbnailPath = path
                    // 路径是固定的 seg_<uuid>.jpg：之前若因文件缺失被缓存记为「解码失败」，
                    // 这里必须让它失效，否则新生成的缩略图永远显示不出来。
                    ThumbnailCache.shared.invalidate(path: path)
                }
            }
        }
        modelContext?.safeSave()
    }

    /// 生成视频缩略图（全局目录）
    private func generateVideoThumbnail(for video: Video) async throws {
        let thumbDir = FileHelper.globalThumbnailDirectory
        let thumbPath = thumbDir.appendingPathComponent("\(video.id.uuidString).jpg").path

        try await ffmpeg.generateThumbnail(from: video.localPath, to: thumbPath)
        video.thumbnailPath = thumbPath
    }

    /// 计算文件 SHA-256 哈希
    static func computeFileHash(path: String) -> String? {
        do {
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }

            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let fileSize = (attrs[.size] as? Int64) ?? 0

            var hasher = SHA256()
            hasher.update(data: Data(String(fileSize).utf8))

            let chunkSize = 4 * 1024 * 1024
            let headData = handle.readData(ofLength: chunkSize)
            hasher.update(data: headData)

            if fileSize > Int64(chunkSize * 2) {
                handle.seek(toFileOffset: UInt64(fileSize) - UInt64(chunkSize))
                let tailData = handle.readData(ofLength: chunkSize)
                hasher.update(data: tailData)
            }

            let digest = hasher.finalize()
            return digest.map { String(format: "%02x", $0) }.joined()
        } catch {
            MixLog.error(" 计算文件哈希失败: \(error)")
            return nil
        }
    }

    /// 支持的视频文件类型
    static var supportedTypes: [UTType] {
        [.movie, .mpeg4Movie, .quickTimeMovie, .avi]
    }

    /// 重识别该视频各分镜台词：**逐分镜各自切音频独立 ASR**（不动分镜边界）。
    /// 不用整片 ASR 切片——实时流式 ASR 的整片绝对时间戳会漂移、导致台词错位；
    /// 单段短音频 ASR 永远准。每个分镜按自己时间范围切音频、各自识别、写回 segment.text。
    func reidentifyWholeVideo(_ video: Video, context: ModelContext) async {
        guard !video.localPath.isEmpty, FileManager.default.fileExists(atPath: video.localPath) else {
            ToastCenter.shared.show("找不到原视频文件", icon: "exclamationmark.triangle.fill", style: .warning); return
        }
        guard !reidentifyingVideoIDs.contains(video.id) else { return }
        reidentifyingVideoIDs.insert(video.id)
        defer { reidentifyingVideoIDs.remove(video.id) }

        let (ok, fail, reason) = await reidentifySegmentTexts(video: video, context: context)
        if fail == 0 {
            ToastCenter.shared.show("已逐分镜用阿里重识别台词（\(ok) 段）", icon: "checkmark.circle.fill", style: .success)
        } else {
            // 只报"X 成功 / Y 失败"等于没报——用户既不知道为什么失败，也不知道该怎么办。
            // 把第一条真实原因带出来（同一批失败通常同因：欠费 / Key 无效 / 断网）。
            let detail = reason.map { "：\($0)" } ?? ""
            ToastCenter.shared.show("台词重识别 \(ok) 段成功、\(fail) 段失败\(detail)",
                                    icon: "exclamationmark.triangle.fill", style: .warning, duration: 8)
        }
    }

    /// 逐分镜各自切音频独立 ASR，覆盖 segment.text（导入与重识别共用）。
    /// 每段按自己时间范围切音频、各自识别——单段短音频时间戳天生准，不受整片漂移影响。
    /// 失败的分镜保留原 text。返回 (成功段数, 失败段数, 首个失败原因)。
    @discardableResult
    func reidentifySegmentTexts(video: Video, context: ModelContext) async -> (ok: Int, fail: Int, reason: String?) {
        let fps = video.fps > 0 ? video.fps : 30
        let segs = video.segments.sorted { $0.startFrame < $1.startFrame }
        var ok = 0, fail = 0
        var firstFailure: String?
        for seg in segs {
            if cancelledVideoIDs.contains(video.id) { break }
            let start = Double(seg.startFrame) / fps
            let end = Double(seg.endFrame) / fps
            let pcm = FileHelper.tempDirectory.appendingPathComponent("asrseg-\(UUID().uuidString).pcm")
            do {
                try await ffmpeg.extractSegmentPCM(from: video.localPath, start: start, end: end, to: pcm.path)
                let text = try await asrAliyun.transcribe(pcmPath: pcm.path)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    seg.text = trimmed; ok += 1
                } else {
                    fail += 1
                    if firstFailure == nil { firstFailure = "这段音频没有识别出任何文字（可能是纯画面、纯音乐或人声太轻）" }
                }
            } catch {
                fail += 1
                let reason = FriendlyError.reason(for: error)
                if firstFailure == nil { firstFailure = reason }
                MixLog.error("[ASR] 分镜 \(seg.segmentIndex) 重识别失败: \(reason)")
            }
            try? FileManager.default.removeItem(at: pcm)
        }
        // 这一步覆盖整个视频所有分镜的台词，且是付费识别的结果，保存失败必须告知
        context.saveOrWarn("重识别的台词")
        return (ok, fail, firstFailure)
    }

    // MARK: - 分镜拆分（PRD/TRD 06）

    /// 把一个分镜在 `cutFrame` 处拆成前后两段：A 复用原 seg 缩为前段，B 新建后段。
    /// 清空原分镜的衍生物（配音/字幕、画面替换、物理镜头变体），两段各自重抽缩略图 + 阿里重识别台词，
    /// B 继承原语义标签。`onUpdate` 用于刷新分镜库。调用前须保证 `seg.schemeSegments` 为空（拦截见 UI）。
    /// 拆分结果。以前这个方法是 `async` 无返回值且有三处静默 `return`，
    /// 调用方（SplitSegmentSheet）不管成败一律 `dismiss()` —— 用户看到「拆分中…」后弹窗正常关闭，
    /// 但列表毫无变化，完全不知道发生了什么。现在把失败原因带回去，由 UI 如实展示。
    enum SplitOutcome {
        case success
        /// 拆分本体成功，但后续台词重识别失败（台词仍是拆分前的旧内容，需要用户核对）
        case successWithWarning(String)
        case failed(reason: String)
    }

    @discardableResult
    func splitSegment(_ seg: Segment, atFrame cutFrame: Int, onUpdate: @escaping @MainActor () -> Void = {}) async -> SplitOutcome {
        guard let context = modelContext else {
            return .failed(reason: "数据库尚未就绪，请稍后重试。")
        }
        guard let video = seg.video else {
            return .failed(reason: "这个分镜找不到对应的源视频，可能视频已被删除。请重新导入素材。")
        }
        guard seg.schemeSegments.isEmpty else {
            return .failed(reason: "这个分镜已经被混剪方案使用，不能再拆分。请先从方案中移除它，或复制一份再拆。")
        }
        let fps = video.fps > 0 ? video.fps : 30
        let origStart = seg.startFrame
        let origEnd = seg.endFrame
        guard cutFrame > origStart, cutFrame < origEnd else {
            return .failed(reason: "拆分点必须落在分镜内部。当前分镜太短或拆分位置在边缘，无法拆分。")
        }

        // 1) 清空原 seg（将成为 A 段）的衍生物 —— 两段视为全新分镜，不可恢复
        for dub in seg.segmentDubs { context.delete(dub) }          // cascade 删逐句字幕
        for shot in seg.physicalShots { context.delete(shot) }      // cascade 删 ShotVariant
        seg.invalidateReplacedPicture()

        // 2) A = 原 seg 缩为 [origStart, cutFrame]
        seg.setFrameRange(startFrame: origStart, endFrame: cutFrame, fps: fps)

        // 3) B = 新建后段 [cutFrame, origEnd]，继承标签
        let b = Segment(segmentIndex: "\(seg.segmentIndex)_\(UUID().uuidString.prefix(4))",
                        startTime: 0, endTime: 0, text: "",
                        semanticTypes: seg.semanticTypes, positionType: seg.positionType,
                        qualityScore: seg.qualityScore)
        b.video = video
        b.setFrameRange(startFrame: cutFrame, endFrame: origEnd, fps: fps)
        b.keywords = seg.keywords
        context.insert(b)
        context.safeSave()
        onUpdate()   // 两段先出现

        // 4) 缩略图各自重生（各自首帧）
        await regenSegmentThumbnail(seg, in: video, fps: fps)
        await regenSegmentThumbnail(b, in: video, fps: fps)
        context.safeSave(); onUpdate()

        // 5) 各自阿里重识别台词（复用单段 ASR 模式）
        let okA = await reASRSegment(seg, in: video, fps: fps)
        let okB = await reASRSegment(b, in: video, fps: fps)
        context.safeSave(); onUpdate()

        // 台词重识别失败时**必须说出来**：拆分本体是成功的，但两段的台词还停留在拆分前的旧内容，
        // 用户如果不知道，会拿着错误台词去配音、去导出。
        if !okA || !okB {
            let which = (!okA && !okB) ? "两段" : (okA ? "后一段" : "前一段")
            return .successWithWarning("拆分已完成，但\(which)的台词重新识别失败，台词仍是拆分前的旧内容。请手动核对并编辑台词。")
        }
        return .success
    }

    /// 重抽某分镜首帧缩略图（拆分后 A/B 各自生成，用 seg.id 命名避免共用）
    private func regenSegmentThumbnail(_ seg: Segment, in video: Video, fps: Double) async {
        let t = Double(seg.startFrame) / fps
        let path = FileHelper.globalThumbnailDirectory
            .appendingPathComponent("seg-\(seg.id.uuidString).jpg").path
        do {
            try await ffmpeg.generateThumbnail(from: video.localPath, at: t, to: path)
            seg.thumbnailPath = path
            // ⚠️ 拆分后 seg.id 不变 → 路径不变但画面已经变了。
            // 不清缓存的话，卡片会一直显示拆分前的旧首帧。
            ThumbnailCache.shared.invalidate(path: path)
        } catch {
            MixLog.error("[Split] 缩略图重生失败 \(seg.segmentIndex): \(error.localizedDescription)")
        }
    }

    /// 对某分镜按自己帧窗切音频 + 阿里 paraformer 重识别台词（失败保留原 text）。
    /// 返回是否成功，供调用方决定要不要提醒用户「台词还是旧的」。
    @discardableResult
    private func reASRSegment(_ seg: Segment, in video: Video, fps: Double) async -> Bool {
        let start = Double(seg.startFrame) / fps
        let end = Double(seg.endFrame) / fps
        let pcm = FileHelper.tempDirectory.appendingPathComponent("asrseg-\(UUID().uuidString).pcm")
        defer { try? FileManager.default.removeItem(at: pcm) }
        do {
            try await ffmpeg.extractSegmentPCM(from: video.localPath, start: start, end: end, to: pcm.path)
            let text = try await asrAliyun.transcribe(pcmPath: pcm.path)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { seg.text = text }
            return true
        } catch {
            MixLog.error("[Split] reASR 失败 \(seg.segmentIndex): \(FriendlyError.reason(for: error))")
            return false
        }
    }
}
