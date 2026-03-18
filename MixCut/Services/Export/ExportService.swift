import Foundation

/// 导出配置
struct ExportConfig {
    var resolution: ExportResolution = .original
    var codec: ExportCodec = .h264
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
        case h264 = "H.264"
        case h265 = "H.265 (HEVC)"

        var id: String { rawValue }

        var ffmpegCodec: String {
            switch self {
            case .h264: return "libx264"
            case .h265: return "libx265"
            }
        }
    }

    enum ExportQuality: String, CaseIterable, Identifiable {
        case low = "低质量（文件小）"
        case medium = "中等质量"
        case high = "高质量"
        case lossless = "无损"

        var id: String { rawValue }

        /// 根据编码器返回合适的 CRF 值（H.265 同等视觉质量 CRF 更高）
        func crf(for codec: ExportCodec = .h264) -> Int {
            switch (self, codec) {
            case (.low, .h264): return 28
            case (.low, .h265): return 30
            case (.medium, .h264): return 23
            case (.medium, .h265): return 26
            case (.high, .h264): return 18
            case (.high, .h265): return 22
            case (.lossless, _): return 0
            }
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
                  let video = segment.video,
                  FileManager.default.fileExists(atPath: video.localPath) else { continue }
            segments.append((path: video.localPath, start: segment.startTime, end: segment.endTime))
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
