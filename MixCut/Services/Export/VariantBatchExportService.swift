import Foundation

/// 单个导出任务（值类型，可跨 actor 传递）。
enum VariantExportJob: Sendable {
    /// 原版：流复制切片。
    case original(sourcePath: String, startTime: Double, endTime: Double, fps: Double, fileName: String)
    /// 变体：dub 渲染（含 BGM）。
    case variant(spec: DubSegmentSpec, videoWidth: Int, videoHeight: Int, fileName: String)

    var fileName: String {
        switch self {
        case let .original(_, _, _, _, name): return name
        case let .variant(_, _, _, name): return name
        }
    }
}

/// 导出进度（纯值，不耦合 SwiftData）。
struct VariantExportProgress: Sendable {
    let total: Int
    let completed: Int
    let currentName: String?
    let failed: [(String, String)]   // (文件名, 错误)
    var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
}

/// 从选中分镜解析出导出任务（@MainActor：读 SwiftData）。
enum VariantExportInput {
    @MainActor
    static func from(segments: [Segment], numberProvider: (Segment) -> Int) -> [VariantExportJob] {
        // 1) 构造展开来源（仅含已生成音频的变体）
        var segByKey: [String: Segment] = [:]
        var dubByKey: [String: SegmentDub] = [:]
        var sources: [SegmentExportSource] = []

        for seg in segments {
            guard let video = seg.video else { continue }
            let key = seg.id.uuidString
            segByKey[key] = seg
            let stem = (video.name as NSString).deletingPathExtension
            // 只填"参与组合"的变体（combinationDubVariants），原版是否参与由 includeOriginal 决定
            let variants: [VariantRef] = seg.combinationDubVariants.map { dub in
                dubByKey[dub.id.uuidString] = dub
                return VariantRef(dubKey: dub.id.uuidString, textVariantIndex: dub.textVariantIndex)
            }
            sources.append(SegmentExportSource(
                segmentKey: key, sequenceNumber: numberProvider(seg),
                videoName: stem, isVoiceLocked: seg.isVoiceLocked,
                includeOriginal: seg.originalParticipatesInCombination, variants: variants))
        }

        // 2) 展开
        let items = SegmentExportExpander.expand(sources)

        // 3) 解析成可执行任务
        var jobs: [VariantExportJob] = []
        for item in items {
            guard let seg = segByKey[item.segmentKey], let video = seg.video else { continue }
            // 走"当前生效画面"（替换版=合成片整段；原版=源视频帧区间）
            let ep = seg.effectivePicture
            let fps = ep.fps > 0 ? ep.fps : 30
            if let dubKey = item.dubKey, let dub = dubByKey[dubKey],
               let audioPath = dub.audioFilePath {
                // BGM 切片源（整轨 bgm.wav），不存在则 nil（回退纯人声）
                let bgmPath: String? = {
                    guard let hash = video.contentHash, !hash.isEmpty else { return nil }
                    let p = FileHelper.stemsDirectory(videoHash: hash).appendingPathComponent("bgm.wav").path
                    return FileManager.default.fileExists(atPath: p) ? p : nil
                }()
                let caption = dub.rewrittenText.isEmpty ? seg.text : dub.rewrittenText
                let spec = DubSegmentSpec(
                    videoPath: ep.videoPath, startFrame: ep.startFrame, endFrame: ep.endFrame,
                    fps: fps, captionText: caption, hasHardSubtitle: seg.hasHardSubtitle,
                    maskStyleRaw: seg.maskStyleRaw, maskRect: seg.maskRect, isVoiceLocked: false,
                    dubAudioPath: audioPath, freezePadFrames: dub.freezePadFrames,
                    trailingSilence: dub.trailingSilence, bgmAudioPath: bgmPath)
                jobs.append(.variant(spec: spec, videoWidth: video.width, videoHeight: video.height,
                                     fileName: item.fileName))
            } else {
                jobs.append(.original(sourcePath: ep.videoPath, startTime: ep.startTime,
                                      endTime: ep.endTime, fps: fps, fileName: item.fileName))
            }
        }
        return jobs
    }
}

/// 变体感知批量导出：原版走流复制，变体走 dub 渲染。
actor VariantBatchExportService {
    private let ffmpeg: FFmpegRunner
    private let dubExport: DubExportService

    init(ffmpeg: FFmpegRunner = FFmpegRunner(), dubExport: DubExportService = DubExportService()) {
        self.ffmpeg = ffmpeg
        self.dubExport = dubExport
    }

    func exportAll(
        jobs: [VariantExportJob],
        outputDirectory: URL,
        config: ExportConfig = ExportConfig(),
        onProgress: @Sendable @MainActor (VariantExportProgress) -> Void
    ) async -> (succeeded: Int, failed: [(String, String)]) {
        var succeeded = 0
        var failed: [(String, String)] = []
        var usedNames: Set<String> = []
        let total = jobs.count

        for (idx, job) in jobs.enumerated() {
            await onProgress(VariantExportProgress(total: total, completed: idx,
                                                   currentName: job.fileName, failed: failed))
            let outURL = Self.uniqueDestination(directory: outputDirectory,
                                                preferredName: job.fileName, usedInBatch: &usedNames)
            do {
                switch job {
                case let .original(sourcePath, startTime, endTime, fps, _):
                    try await ffmpeg.cutSegment(from: sourcePath, start: startTime, end: endTime,
                                                fps: fps, to: outURL.path)
                case let .variant(spec, w, h, _):
                    try await dubExport.exportSingleSegment(spec: spec, videoWidth: w, videoHeight: h,
                                                            outputPath: outURL.path, config: config)
                }
                succeeded += 1
            } catch {
                failed.append((job.fileName, error.localizedDescription))
                MixLog.error("变体导出失败 \(job.fileName): \(error)")
            }
            if Task.isCancelled { break }
        }

        await onProgress(VariantExportProgress(total: total, completed: succeeded + failed.count,
                                               currentName: nil, failed: failed))
        return (succeeded, failed)
    }

    /// 同名冲突 → 加 (1)(2)（与 BatchSegmentExportService 同策略）。
    private static func uniqueDestination(directory: URL, preferredName: String,
                                          usedInBatch: inout Set<String>) -> URL {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool {
            usedInBatch.contains(name) || fm.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
        var candidate = preferredName
        if !exists(candidate) { usedInBatch.insert(candidate); return directory.appendingPathComponent(candidate) }
        let url = URL(fileURLWithPath: preferredName)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 1
        while exists(candidate) {
            candidate = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            counter += 1
            if counter > 9999 { break }
        }
        usedInBatch.insert(candidate)
        return directory.appendingPathComponent(candidate)
    }
}
