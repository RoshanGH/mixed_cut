import Foundation

/// 人声分离产物：纯人声 + 纯背景音乐（两条 wav 的本地路径）。
struct SeparatedStems: Sendable {
    let vocalsPath: String
    let bgmPath: String
}

/// 用内置 demucs.cpp 把一条视频的整轨音频分离成「人声 / 背景音乐」。
/// 整轨只分离一次并缓存（键 = videoHash）；导出按分镜切片，克隆用人声做参考。
actor VocalSeparationService {
    enum SepError: Error, LocalizedError {
        case binaryNotFound
        case modelUnavailable
        case separateFailed

        var errorDescription: String? {
            switch self {
            case .binaryNotFound: return "未找到人声分离组件（demucs）"
            case .modelUnavailable: return "人声分离模型下载失败，请检查网络后重试"
            case .separateFailed: return "人声分离失败"
            }
        }
    }

    private static let modelFileName = "ggml-htdemucs-4s.bin"
    /// 下载兜底源（优先国内可达，再退原站）。正常情况走 bundle 内置模型，根本不会下载；
    /// 仅当 bundle 缺失（异常）时才用到这些源。国内镜像对该冷门 repo 会 308 跳回原站，
    /// 故同时给到原站，并配合超时/重试，避免裸 download 永久卡死。
    private static let modelURLs: [URL] = [
        URL(string: "https://hf-mirror.com/datasets/Retrobear/demucs.cpp/resolve/main/ggml-model-htdemucs-4s-f16.bin")!,
        URL(string: "https://huggingface.co/datasets/Retrobear/demucs.cpp/resolve/main/ggml-model-htdemucs-4s-f16.bin")!,
    ]

    /// 整轨分离（已缓存直接返回）。onProgress 回调进度文案。
    func separate(videoPath: String, videoHash: String,
                  onProgress: (@Sendable (String) -> Void)? = nil) async throws -> SeparatedStems {
        let dir = FileHelper.stemsDirectory(videoHash: videoHash)
        let vocals = dir.appendingPathComponent("vocals.wav")
        let bgm = dir.appendingPathComponent("bgm.wav")
        let fm = FileManager.default
        if fm.fileExists(atPath: vocals.path), fm.fileExists(atPath: bgm.path) {
            return SeparatedStems(vocalsPath: vocals.path, bgmPath: bgm.path)
        }

        guard let binary = Self.findDemucsBinary() else {
            MixLog.error("[Sep] 未找到 demucs 二进制")
            throw SepError.binaryNotFound
        }
        MixLog.info("[Sep] demucs 二进制: \(binary)")
        let model = try await ensureModel(onProgress: onProgress)
        MixLog.info("[Sep] 模型: \(model)")

        let ff = FFmpegRunner()
        let tmp = FileHelper.tempDirectory

        // 1) 抽整轨音频为 44.1k 立体声 wav（demucs.cpp 输入要求）
        onProgress?("提取原始音频…")
        let inputWav = tmp.appendingPathComponent("sep-in-\(UUID().uuidString).wav")
        _ = try await ff.run(arguments: ["-y", "-i", videoPath, "-ac", "2", "-ar", "44100",
                                         "-c:a", "pcm_s16le", inputWav.path])

        // 2) demucs 分离到临时目录（4 stems）
        onProgress?("AI 分离人声与背景音乐（较慢，请稍候）…")
        let outDir = tmp.appendingPathComponent("sep-out-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        MixLog.info("[Sep] 开始 demucs 分离…")
        try await Self.runDemucs(binary: binary, model: model, input: inputWav.path, outDir: outDir.path)
        MixLog.info("[Sep] demucs 分离结束")

        let drums = outDir.appendingPathComponent("target_0_drums.wav").path
        let bass = outDir.appendingPathComponent("target_1_bass.wav").path
        let other = outDir.appendingPathComponent("target_2_other.wav").path
        let voc = outDir.appendingPathComponent("target_3_vocals.wav").path
        guard fm.fileExists(atPath: voc) else { throw SepError.separateFailed }

        // 3) BGM = drums + bass + other（不归一化，保持原响度）；vocals 直接取
        onProgress?("合成背景音乐轨…")
        _ = try await ff.run(arguments: ["-y", "-i", drums, "-i", bass, "-i", other,
                                         "-filter_complex", "amix=inputs=3:normalize=0",
                                         "-c:a", "pcm_s16le", bgm.path])
        try? fm.removeItem(at: vocals)
        try fm.copyItem(atPath: voc, toPath: vocals.path)

        // 清理临时
        try? fm.removeItem(at: inputWav)
        try? fm.removeItem(at: outDir)

        return SeparatedStems(vocalsPath: vocals.path, bgmPath: bgm.path)
    }

    /// 从分离出的人声里取一段做克隆参考（默认 ≤6s，转 mp3 便于 base64）。
    /// 必须短而干净：参考太长(含多句原话)会让 qwen 克隆 TTS 间歇性"续读参考内容"，配音混进别段。
    func referenceClip(fromVocals vocalsPath: String, maxSeconds: Double = 6) async throws -> String {
        let ff = FFmpegRunner()
        let out = FileHelper.tempDirectory.appendingPathComponent("clone-ref-\(UUID().uuidString).mp3")
        _ = try await ff.run(arguments: ["-y", "-i", vocalsPath, "-t", String(maxSeconds),
                                         "-c:a", "libmp3lame", "-b:a", "128k", out.path])
        return out.path
    }

    // MARK: - 模型与二进制

    private func ensureModel(onProgress: (@Sendable (String) -> Void)?) async throws -> String {
        // 1) bundle 内置模型（开箱即用，国内用户零下载）—— 正常路径
        if let bundled = Self.findBundledModel() {
            return bundled
        }
        // 2) 之前下载过的缓存
        let dest = FileHelper.demucsModelsDirectory.appendingPathComponent(Self.modelFileName)
        if FileManager.default.fileExists(atPath: dest.path) { return dest.path }
        // 3) 兜底下载（仅当 bundle 异常缺失时）：多源 + 超时 + 重试
        return try await downloadModel(to: dest, onProgress: onProgress)
    }

    /// 查 bundle 内置的 demucs 模型（与 demucs 二进制同放 `Resources/bin/`，随 folder reference 打包）。
    static func findBundledModel() -> String? {
        if let url = Bundle.main.resourceURL?
            .appendingPathComponent("bin").appendingPathComponent(Self.modelFileName),
           FileManager.default.fileExists(atPath: url.path) {
            return url.path
        }
        if let path = Bundle.main.path(forResource: "ggml-htdemucs-4s", ofType: "bin", inDirectory: "bin") {
            return path
        }
        return nil
    }

    /// 兜底下载：多源（国内镜像优先）+ 单次 60s 超时 + 每源 2 次尝试。
    private func downloadModel(to dest: URL,
                              onProgress: (@Sendable (String) -> Void)?) async throws -> String {
        onProgress?("下载人声分离模型（约 80MB，仅首次）…")
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 1800
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        var lastError: Error?
        for url in Self.modelURLs {
            let source = url.host?.contains("hf-mirror") == true ? "国内镜像" : "HuggingFace"
            for attempt in 0..<2 {
                try Task.checkCancellation()
                do {
                    let (tmpURL, resp) = try await session.download(from: url)
                    guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw SepError.modelUnavailable
                    }
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tmpURL, to: dest)
                    return dest.path
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                    MixLog.error("[Sep][\(source) attempt \(attempt + 1)] 模型下载失败: \(error.localizedDescription)")
                }
            }
        }
        throw lastError ?? SepError.modelUnavailable
    }

    /// 查 bundle 内 demucs 二进制（folder reference）。
    static func findDemucsBinary() -> String? {
        if let binURL = Bundle.main.resourceURL?.appendingPathComponent("bin").appendingPathComponent("demucs"),
           FileManager.default.fileExists(atPath: binURL.path) {
            return binURL.path
        }
        if let path = Bundle.main.path(forResource: "demucs", ofType: nil, inDirectory: "bin") {
            return path
        }
        return nil
    }

    /// 运行 demucs.cpp：`demucs <model> <input.wav> <outDir>`。
    nonisolated private static func runDemucs(binary: String, model: String,
                                              input: String, outDir: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: binary)
            p.arguments = [model, input, outDir]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: SepError.separateFailed)
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
