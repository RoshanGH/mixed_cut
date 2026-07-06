import Foundation

/// 分镜头变体生成编排：切分镜头切片 → 调 wan2.7-videoedit → 下载 → 生成缩略图。
/// 落库（写 ShotVariant 字段）由调用方在 @MainActor 完成。
actor ShotVariantService {
    private let ffmpeg: FFmpegRunner
    private let client: Wan25VideoEditClient

    init(ffmpeg: FFmpegRunner = FFmpegRunner(),
         client: Wan25VideoEditClient = Wan25VideoEditClient()) {
        self.ffmpeg = ffmpeg
        self.client = client
    }

    struct Result: Sendable {
        let resultVideoPath: String
        let thumbnailPath: String
    }

    /// - Parameters:
    ///   - sourceVideoPath: 源视频
    ///   - videoHash: 源视频 hash（落盘目录键）
    ///   - shotId/variantId: 目标分镜头 / 变体 id（落盘命名）
    ///   - startFrame/endFrame/fps: 分镜头帧区间
    ///   - prompt: 提示词
    func generate(sourceVideoPath: String,
                  videoHash: String,
                  shotId: UUID,
                  variantId: UUID,
                  startFrame: Int,
                  endFrame: Int,
                  fps: Double,
                  prompt: String,
                  onStatus: @Sendable (String) -> Void = { _ in }) async throws -> Result {
        guard fps > 0 else { throw NSError(domain: "ShotVariant", code: -1, userInfo: [NSLocalizedDescriptionKey: "缺少有效帧率"]) }

        // 1) 切出分镜头切片（帧精确，setpts 重置时间戳避免首帧黑屏）
        let clipURL = FileHelper.tempDirectory
            .appendingPathComponent("shotclip-\(variantId.uuidString).mp4")
        try? FileManager.default.removeItem(at: clipURL)
        let start = Double(startFrame) / fps
        let end = Double(endFrame) / fps
        onStatus("准备切片")
        try await ffmpeg.cutSegment(from: sourceVideoPath, start: start, end: end, fps: fps, to: clipURL.path)

        // 2) 调 VACE 拿结果 URL
        let resultURL = try await client.edit(videoFileURL: clipURL, prompt: prompt, onStatus: onStatus)

        // 3) 下载到变体目录（URL 24h 过期，立即下载）
        onStatus("下载结果")
        let destURL = FileHelper.shotVariantURL(videoHash: videoHash, shotId: shotId, variantId: variantId)
        let (tmp, _) = try await URLSession.shared.download(from: resultURL)
        try? FileManager.default.removeItem(at: destURL)
        try FileManager.default.moveItem(at: tmp, to: destURL)

        // 4) 缩略图（首帧）
        let thumbURL = FileHelper.shotVariantThumbnailURL(videoHash: videoHash, shotId: shotId, variantId: variantId)
        try? await ffmpeg.generateThumbnail(from: destURL.path, at: 0.0, to: thumbURL.path)

        // 5) 清理临时切片
        try? FileManager.default.removeItem(at: clipURL)

        return Result(resultVideoPath: destURL.path, thumbnailPath: thumbURL.path)
    }
}
