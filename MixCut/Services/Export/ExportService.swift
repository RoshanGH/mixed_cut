import Foundation

/// 导出配置
struct ExportConfig {
    var resolution: ExportResolution = .original
    var codec: ExportCodec = .h264Hardware    // 默认硬件加速：5-10× 速度
    var quality: ExportQuality = .high

    enum ExportResolution: String, CaseIterable, Identifiable {
        case original = "原始分辨率"
        case p1080 = "1080p"
        case p720 = "720p"
        case p480 = "480p"

        var id: String { rawValue }

        var scaleFilter: String? {
            switch self {
            case .original: return nil
            case .p1080: return "scale=-2:1080"
            case .p720: return "scale=-2:720"
            case .p480: return "scale=-2:480"
            }
        }
    }

    enum ExportCodec: String, CaseIterable, Identifiable {
        case h264Hardware = "H.264（硬件加速・推荐）"
        case h265Hardware = "H.265 / HEVC（硬件加速）"
        case h264 = "H.264（CPU 软件编码・最佳画质）"
        case h265 = "H.265 / HEVC（CPU 软件编码）"

        var id: String { rawValue }

        var ffmpegCodec: String {
            switch self {
            case .h264:         return "libx264"
            case .h265:         return "libx265"
            case .h264Hardware: return "h264_videotoolbox"
            case .h265Hardware: return "hevc_videotoolbox"
            }
        }

        /// 是否使用 Apple VideoToolbox 硬件编码（M 系列 Media Engine / Intel Quick Sync）
        var isHardware: Bool {
            switch self {
            case .h264Hardware, .h265Hardware: return true
            case .h264, .h265:                 return false
            }
        }
    }

    enum ExportQuality: String, CaseIterable, Identifiable {
        case low = "低质量（文件小）"
        case medium = "中等质量"
        case high = "高质量"
        case lossless = "无损"

        var id: String { rawValue }

        /// 软件编码用的 CRF 值（H.265 同等视觉质量 CRF 更高）
        func crf(for codec: ExportCodec = .h264) -> Int {
            switch (self, codec) {
            case (.low, .h264), (.low, .h264Hardware):     return 28
            case (.low, .h265), (.low, .h265Hardware):     return 30
            case (.medium, .h264), (.medium, .h264Hardware): return 23
            case (.medium, .h265), (.medium, .h265Hardware): return 26
            case (.high, .h264), (.high, .h264Hardware):   return 18
            case (.high, .h265), (.high, .h265Hardware):   return 22
            case (.lossless, _):                            return 0
            }
        }

        /// 硬件编码用的目标比特率（kbps，按 1080p 估算；FFmpeg 会按实际分辨率扩缩）
        /// VideoToolbox 不支持 CRF，用比特率控质量。
        func videoBitrateKbps(for codec: ExportCodec) -> Int {
            switch (self, codec) {
            case (.low, .h264Hardware):    return 3_000
            case (.medium, .h264Hardware): return 6_000
            case (.high, .h264Hardware):   return 10_000
            case (.low, .h265Hardware):    return 1_800
            case (.medium, .h265Hardware): return 3_500
            case (.high, .h265Hardware):   return 6_500
            case (.lossless, _):           return 50_000   // 硬件不支持真无损，给极高比特率近似
            default:                        return 8_000
            }
        }
    }

    /// 用户可读的质量说明（含码率/CRF + 文件大小估算）
    /// 在 UI 下方显示，让用户知道选择对应的画质和文件大小
    var qualityHint: String {
        if codec.isHardware {
            let kbps = quality.videoBitrateKbps(for: codec)
            let mbps = Double(kbps) / 1000.0
            let mbpsStr = mbps >= 10 ? String(format: "%.0f", mbps) : String(format: "%.1f", mbps)
            // 30 秒视频文件大小估算 = bitrate × duration / 8
            let sizeMB = mbps * 30 / 8
            let sizeStr = sizeMB >= 10 ? String(format: "%.0f", sizeMB) : String(format: "%.1f", sizeMB)
            return "目标码率 \(mbpsStr) Mbps（1080p 基准）· 30 秒视频约 \(sizeStr) MB"
        } else {
            let crf = quality.crf(for: codec)
            let approxMbps: String
            // CRF 与视觉等效码率的经验对照（H.264 1080p）
            switch (codec, quality) {
            case (.h264, .low):    approxMbps = "约 2-4 Mbps"
            case (.h264, .medium): approxMbps = "约 5-8 Mbps"
            case (.h264, .high):   approxMbps = "约 12-20 Mbps"
            case (.h264, .lossless): approxMbps = "无损（极大文件）"
            case (.h265, .low):    approxMbps = "约 1-2 Mbps"
            case (.h265, .medium): approxMbps = "约 2-4 Mbps"
            case (.h265, .high):   approxMbps = "约 6-12 Mbps"
            case (.h265, .lossless): approxMbps = "无损（极大文件）"
            default:               approxMbps = ""
            }
            return "CRF \(crf)（数值越小画质越好）· 实际码率 \(approxMbps)"
        }
    }
}

/// 导出进度
struct ExportProgress: Sendable {
    let phase: Phase
    let progress: Double    // 0.0 - 1.0
    let description: String

    enum Phase: Sendable {
        case cutting        // 裁切片段
        case concatenating  // 拼接
        case encoding       // 编码
        case completed      // 完成
        case failed         // 失败
    }
}

/// 导出任务的输入数据（值类型，可安全跨 actor 传递）
struct ExportInput: Sendable {
    let segments: [(path: String, start: Double, end: Double)]
    let maxWidth: Int
    let maxHeight: Int

    /// 从 MixScheme 提取导出数据（必须在 @MainActor 上调用）
    @MainActor
    static func from(scheme: MixScheme) -> ExportInput? {
        let orderedSegments = scheme.orderedSegments
        guard !orderedSegments.isEmpty else { return nil }

        var segments: [(path: String, start: Double, end: Double)] = []
        var maxWidth = 0
        var maxHeight = 0
        for schemeSeg in orderedSegments {
            guard let segment = schemeSeg.segment,
                  let video = segment.video else { continue }
            // 走"当前生效画面"（替换版=合成片整段；原版=源视频帧区间）
            let ep = segment.effectivePicture
            guard !ep.videoPath.isEmpty, FileManager.default.fileExists(atPath: ep.videoPath) else { continue }
            segments.append((path: ep.videoPath, start: ep.startTime, end: ep.endTime))
            maxWidth = max(maxWidth, video.width)
            maxHeight = max(maxHeight, video.height)
        }
        guard !segments.isEmpty else { return nil }
        return ExportInput(segments: segments, maxWidth: maxWidth, maxHeight: maxHeight)
    }
}

/// 视频导出服务
actor ExportService {

    private let ffmpeg: FFmpegRunner

    init(ffmpeg: FFmpegRunner = FFmpegRunner()) {
        self.ffmpeg = ffmpeg
    }

    /// 导出混剪方案为 MP4
    func export(
        input: ExportInput,
        outputPath: String,
        config: ExportConfig = ExportConfig(),
        onProgress: (@Sendable (ExportProgress) -> Void)? = nil
    ) async throws {
        let segmentInfos = input.segments
        let maxWidth = input.maxWidth
        let maxHeight = input.maxHeight

        // 确定输出分辨率
        let resolution: String
        switch config.resolution {
        case .original:
            let w = maxWidth > 0 ? (maxWidth + 1) / 2 * 2 : 1080
            let h = maxHeight > 0 ? (maxHeight + 1) / 2 * 2 : 1920
            resolution = "\(w):\(h)"
        case .p1080:
            resolution = maxWidth > maxHeight ? "1920:1080" : "1080:1920"
        case .p720:
            resolution = maxWidth > maxHeight ? "1280:720" : "720:1280"
        case .p480:
            resolution = maxWidth > maxHeight ? "854:480" : "480:854"
        }

        onProgress?(ExportProgress(
            phase: .encoding,
            progress: 0.05,
            description: "正在编码拼接 \(segmentInfos.count) 个片段..."
        ))

        try await ffmpeg.concat(
            segments: segmentInfos,
            outputPath: outputPath,
            resolution: resolution,
            crf: config.quality.crf(for: config.codec),
            codec: config.codec.ffmpegCodec,
            isHardware: config.codec.isHardware,
            videoBitrateKbps: config.quality.videoBitrateKbps(for: config.codec),
            onProgress: { ffmpegProgress in
                onProgress?(ExportProgress(
                    phase: .encoding,
                    progress: 0.05 + ffmpegProgress.percentage * 0.9,
                    description: "正在编码... \(Int(ffmpegProgress.percentage * 100))%"
                ))
            }
        )

        onProgress?(ExportProgress(
            phase: .completed,
            progress: 1.0,
            description: "导出完成"
        ))
    }
}

/// 导出错误
enum ExportError: LocalizedError {
    case noSegments
    case noValidSegments
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSegments:
            return "方案中没有任何分镜"
        case .noValidSegments:
            return "方案中没有有效的分镜（可能视频文件不存在）"
        case .encodingFailed(let detail):
            return "编码失败: \(detail)"
        }
    }
}
