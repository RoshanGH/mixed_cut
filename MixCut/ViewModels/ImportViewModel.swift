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
    private let sceneDetection = SceneDetectionService()
    private let asrService = ASRService()
    private let aiAnalysis = AIAnalysisService()
    private let boundaryOptimizer = BoundaryOptimizerService()

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
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
                errorMessage = prevError + "导入 \(url.lastPathComponent) 失败: \(error.localizedDescription)"
            }
        }

        // ========== 阶段 2：并行执行视频分析 ==========
        if !videosToAnalyze.isEmpty {
            project.status = .analyzing
            context.safeSave()

            let totalVideos = videosToAnalyze.count
            var completedCount = 0
            let cores = ProcessInfo.processInfo.activeProcessorCount
            let maxConcurrency = min(max(1, cores / 2), min(6, totalVideos))

            progressDescription = "并行分析 \(totalVideos) 个视频（\(maxConcurrency) 路并发）..."

            await withTaskGroup(of: Void.self) { group in
                var videoIterator = videosToAnalyze.makeIterator()
                var runningCount = 0

                while runningCount < maxConcurrency, let video = videoIterator.next() {
                    runningCount += 1
                    group.addTask { [weak self] in
                        guard let self else { return }
                        do {
                            try await self.analyzeVideo(video)
                        } catch is CancellationError {
                            // 跳过
                        } catch {
                            await MainActor.run {
                                let prevError = self.errorMessage.map { $0 + "\n" } ?? ""
                                self.errorMessage = prevError + "分析 \(video.name) 失败: \(error.localizedDescription)"
                            }
                        }
                    }
                }

                for await _ in group {
                    completedCount += 1
                    progress = 0.2 + Double(completedCount) / Double(totalVideos) * 0.8
                    progressDescription = "已完成 \(completedCount)/\(totalVideos) 个视频分析"

                    if let nextVideo = videoIterator.next() {
                        group.addTask { [weak self] in
                            guard let self else { return }
                            do {
                                try await self.analyzeVideo(nextVideo)
                            } catch is CancellationError {
                                // 跳过
                            } catch {
                                await MainActor.run {
                                    let prevError = self.errorMessage.map { $0 + "\n" } ?? ""
                                    self.errorMessage = prevError + "分析 \(nextVideo.name) 失败: \(error.localizedDescription)"
                                }
                            }
                        }
                    }
                }
            }
        }

        project.status = .ready
        project.updatedAt = Date()
        context.safeSave()

        phase = .completed
        progress = 1.0
        isProcessing = false
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
                video.errorMessage = "语音识别失败: \(error.localizedDescription)"
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
            video.errorMessage = "AI 分析失败: \(error.localizedDescription)"
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
            video.errorMessage = "元数据提取失败: \(error.localizedDescription)"
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
            video.errorMessage = (video.errorMessage ?? "") + "\n本地分析失败: \(error.localizedDescription)"
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
            video.errorMessage = (video.errorMessage ?? "") + "\n语音识别失败: \(error.localizedDescription)"
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
            createdSegments.append(segment)
        }

        Self.mergeShortSegments(&createdSegments, minDuration: 2.0, context: context)
    }

    // MARK: - 视频删除（解除关联 vs 真删除）

    /// 从项目中移除视频（解除关联）
    /// 仅当视频不被任何项目引用时，才真正删除 Video + Segment + 磁盘文件
    func deleteVideo(_ video: Video, from project: Project) {
        guard let context = modelContext else { return }
        cancelledVideoIDs.insert(video.id)

        // 删除当前项目与该视频的关联
        let videoID = video.id
        for pv in project.projectVideos where pv.video?.id == videoID {
            context.delete(pv)
        }
        context.safeSave()

        // 检查视频是否还被其他项目引用
        let remainingRefs = video.projectVideos.count
        if remainingRefs == 0 {
            // 无任何项目引用，真正删除
            let localPath = video.localPath
            let thumbnailPath = video.thumbnailPath

            // 删除所有 Segment 及其 SchemeSegment 引用
            for segment in video.segments {
                for ss in segment.schemeSegments {
                    context.delete(ss)
                }
                context.delete(segment)
            }

            context.delete(video)
            context.safeSave()

            // 清理磁盘文件
            FileHelper.deleteGlobalVideoFiles(localPath: localPath, thumbnailPath: thumbnailPath)
            // 清理分镜缩略图
            for segment in video.segments {
                if let thumbPath = segment.thumbnailPath {
                    try? FileManager.default.removeItem(atPath: thumbPath)
                }
            }
            MixLog.info(" 视频无引用，已彻底删除: \(video.name)")
        } else {
            MixLog.info(" 视频仍被 \(remainingRefs) 个项目引用，仅解除关联: \(video.name)")
        }
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
                prev.endTime = seg.endTime
                prev.text = prev.text + seg.text
                var kw = prev.keywords
                for k in seg.keywords where !kw.contains(k) { kw.append(k) }
                prev.keywords = kw
                context.delete(seg)
                segments.remove(at: i)
            } else if segments.count > 1 {
                let next = segments[1]
                next.startTime = seg.startTime
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

        await withTaskGroup(of: (Int, String?).self) { group in
            for (i, segment) in segments.enumerated() {
                // 已有缩略图则跳过
                if let existing = segment.thumbnailPath,
                   FileManager.default.fileExists(atPath: existing) {
                    continue
                }
                let midTime = (segment.startTime + segment.endTime) / 2
                let thumbPath = thumbDir.appendingPathComponent("seg_\(segment.id.uuidString).jpg").path
                group.addTask { [ffmpeg] in
                    do {
                        try await ffmpeg.generateThumbnail(from: videoPath, at: midTime, to: thumbPath)
                        return (i, thumbPath)
                    } catch {
                        return (i, nil)
                    }
                }
            }

            for await (index, path) in group {
                if let path, index < segments.count {
                    segments[index].thumbnailPath = path
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
}
