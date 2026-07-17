import Foundation

/// 分镜头变体生成编排：切分镜头切片 → 调 wan2.7-videoedit（提交 + 轮询）→ 下载 → 生成缩略图。
/// 落库（写 ShotVariant 字段）由调用方在 @MainActor 完成。
///
/// 防重复扣费：`generate` 提交成功后**立即回调 taskId**（`onTaskCreated`）让调用方落库；
/// 本地轮询到点仍未出结果时返回 `.timedOut`（**不是失败**，任务可能仍在云端跑）。
/// 之后「重试」用 `resume(taskId:)` 只查旧任务，绝不重复提交。
actor ShotVariantService {
    private let ffmpeg: FFmpegRunner
    private let client: Wan25VideoEditClient
    private let pollInterval: UInt64
    private let maxPolls: Int

    /// - Parameters:
    ///   - pollIntervalSeconds: 轮询间隔（秒）
    ///   - maxPolls: 单次轮询上限（80 × 15s = 20 分钟；到点转 `.timedOut`，不空耗）
    init(ffmpeg: FFmpegRunner = FFmpegRunner(),
         client: Wan25VideoEditClient = Wan25VideoEditClient(),
         pollIntervalSeconds: UInt64 = 15,
         maxPolls: Int = 80) {
        self.ffmpeg = ffmpeg
        self.client = client
        self.pollInterval = pollIntervalSeconds * 1_000_000_000
        self.maxPolls = maxPolls
    }

    struct Result: Sendable {
        let resultVideoPath: String
        let thumbnailPath: String
    }

    /// 轮询终局（均已带 taskId，非异常态）。
    enum Outcome: Sendable {
        case completed(Result)   // SUCCEEDED 且结果已下载落地
        case failed(String)      // 阿里 FAILED / CANCELED，带原因
        case expired             // UNKNOWN：结果已过期(超24h)/不存在
        case timedOut            // 本地轮询到点仍在跑，云端可能仍会成功
    }

    // MARK: - 首次生成（提交 + 轮询）

    /// 切片 → 提交（回调 taskId）→ 轮询到终局。
    /// - throws: 仅在**提交阶段失败**（切片失败 / 提交 HTTP 失败 / 缺 key）时抛出——
    ///           这类情况**没有 taskId、阿里没扣费**，调用方可安全重新提交。
    ///           拿到 taskId 之后的一切都以 `Outcome` 返回（不抛），避免误判为「没扣费可重提」。
    func generate(sourceVideoPath: String,
                  videoHash: String,
                  shotId: UUID,
                  variantId: UUID,
                  startFrame: Int,
                  endFrame: Int,
                  fps: Double,
                  prompt: String,
                  onTaskCreated: @Sendable (String) -> Void = { _ in },
                  onStatus: @Sendable (String) -> Void = { _ in }) async throws -> Outcome {
        guard fps > 0 else { throw NSError(domain: "ShotVariant", code: -1, userInfo: [NSLocalizedDescriptionKey: "缺少有效帧率"]) }

        // 1) 切出分镜头切片（帧精确，setpts 重置时间戳避免首帧黑屏）
        let clipURL = FileHelper.tempDirectory
            .appendingPathComponent("shotclip-\(variantId.uuidString).mp4")
        try? FileManager.default.removeItem(at: clipURL)
        let start = Double(startFrame) / fps
        let end = Double(endFrame) / fps
        onStatus("准备切片")
        try await ffmpeg.cutSegment(from: sourceVideoPath, start: start, end: end, fps: fps, to: clipURL.path)
        defer { try? FileManager.default.removeItem(at: clipURL) }

        // 2) 提交拿 taskId —— 成功即回调落库（此后断电/超时/崩溃都不丢）
        onStatus("上传中")
        let taskId = try await client.submit(videoFileURL: clipURL, prompt: prompt)
        onTaskCreated(taskId)
        onStatus("生成中")

        // 3) 轮询到终局
        return try await pollToOutcome(taskId: taskId, videoHash: videoHash,
                                       shotId: shotId, variantId: variantId, onStatus: onStatus)
    }

    // MARK: - 重试拉取（只查旧任务，绝不重复提交/扣费）

    /// 用已有 taskId 继续轮询旧任务（超时占位点「重试」走这里）。
    /// 查到仍在跑会自动续查到本轮上限；不产生任何新任务、不扣费。
    func resume(taskId: String,
                videoHash: String,
                shotId: UUID,
                variantId: UUID,
                onStatus: @Sendable (String) -> Void = { _ in }) async throws -> Outcome {
        onStatus("生成中")
        return try await pollToOutcome(taskId: taskId, videoHash: videoHash,
                                       shotId: shotId, variantId: variantId, onStatus: onStatus)
    }

    // MARK: - 内部：轮询循环 + 成功后下载落地

    private func pollToOutcome(taskId: String,
                               videoHash: String,
                               shotId: UUID,
                               variantId: UUID,
                               onStatus: @Sendable (String) -> Void) async throws -> Outcome {
        for _ in 0..<maxPolls {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: pollInterval)
            switch try await client.poll(taskId: taskId) {
            case .succeeded(let url):
                onStatus("下载结果")
                let result = try await downloadAndThumbnail(from: url, videoHash: videoHash,
                                                            shotId: shotId, variantId: variantId)
                return .completed(result)
            case .failed(let reason):
                return .failed(reason)
            case .expired:
                return .expired
            case .running:
                onStatus("生成中")
            }
        }
        return .timedOut
    }

    /// 下载结果视频（URL 24h 过期，立即下载）+ 抽首帧缩略图。
    private func downloadAndThumbnail(from resultURL: URL,
                                      videoHash: String,
                                      shotId: UUID,
                                      variantId: UUID) async throws -> Result {
        let destURL = FileHelper.shotVariantURL(videoHash: videoHash, shotId: shotId, variantId: variantId)
        let (tmp, _) = try await URLSession.shared.download(from: resultURL)
        try? FileManager.default.removeItem(at: destURL)
        try FileManager.default.moveItem(at: tmp, to: destURL)

        let thumbURL = FileHelper.shotVariantThumbnailURL(videoHash: videoHash, shotId: shotId, variantId: variantId)
        try? await ffmpeg.generateThumbnail(from: destURL.path, at: 0.0, to: thumbURL.path)

        return Result(resultVideoPath: destURL.path, thumbnailPath: thumbURL.path)
    }
}
