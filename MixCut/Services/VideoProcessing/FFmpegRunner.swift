import Foundation

/// FFmpeg 执行进度回调
struct FFmpegProgress: Sendable {
    let frame: Int
    let fps: Double
    let time: Double      // 当前处理到的秒数
    let speed: Double
    let percentage: Double // 0.0 - 1.0

    static let zero = FFmpegProgress(frame: 0, fps: 0, time: 0, speed: 0, percentage: 0)
}

/// FFmpeg 错误类型
enum FFmpegError: LocalizedError {
    case binaryNotFound
    case executionFailed(exitCode: Int32, stderr: String)
    case outputParsingFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "视频处理组件未找到，请重新安装应用"
        case .executionFailed(let code, let stderr):
            let hint = stderr.suffix(200)
            return "视频处理失败 (exit \(code)): \(hint)"
        case .outputParsingFailed(let detail):
            return "视频分析结果异常: \(detail)"
        case .cancelled:
            return "操作已取消"
        }
    }
}

/// 线程安全的字符串收集器（用于跨闭包收集 stderr 输出）
private final class ThreadSafeStringBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = ""

    func append(_ text: String) {
        lock.lock()
        _value += text
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
}

/// FFmpeg 命令执行封装
actor FFmpegRunner {

    /// FFmpeg 二进制路径
    private let binaryPath: String

    /// 当前运行中的进程（用于取消）
    private var runningProcess: Process?

    /// 当前系统是否为 Intel Mac（x86_64）
    private static let isIntelMac: Bool = {
        #if arch(x86_64)
        return true
        #else
        return false
        #endif
    }()

    init() {
        // 优先使用 bundle 内的 FFmpeg（开箱即用，用户无需安装任何依赖）
        // 使用 resourceURL 拼接路径（folder reference 下 path(forResource:) 在 Release 构建中不可靠）
        let bundledPath = Self.findBundledBinary("ffmpeg")

        // 系统安装仅作为开发期 fallback
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        let systemPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) })

        if let bundledPath {
            self.binaryPath = bundledPath
        } else if let systemPath {
            self.binaryPath = systemPath
            MixLog.info("使用系统 FFmpeg（开发模式）: \(systemPath)")
        } else {
            self.binaryPath = ""
            MixLog.error("未找到可用的 FFmpeg，视频处理功能不可用")
        }
    }

    /// 从 Bundle 中查找二进制（兼容 folder reference 和 resource group）
    private static func findBundledBinary(_ name: String) -> String? {
        // 方式 1: resourceURL 直接拼接（folder reference 最可靠）
        if let binURL = Bundle.main.resourceURL?.appendingPathComponent("bin").appendingPathComponent(name),
           FileManager.default.fileExists(atPath: binURL.path) {
            return binURL.path
        }
        // 方式 2: path(forResource:) API（resource group 模式）
        if let path = Bundle.main.path(forResource: name, ofType: nil, inDirectory: "bin") {
            return path
        }
        if let path = Bundle.main.path(forResource: name, ofType: nil) {
            return path
        }
        return nil
    }

    init(binaryPath: String) {
        self.binaryPath = binaryPath
    }

    // MARK: - 核心执行

    /// 执行 FFmpeg 命令并返回 stdout
    func run(
        arguments: [String],
        totalDuration: Double? = nil,
        onProgress: (@Sendable (FFmpegProgress) -> Void)? = nil
    ) async throws -> Data {
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            throw FFmpegError.binaryNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments
        process.qualityOfService = .userInitiated
        // 设置最小化环境变量，确保 dylib 能在 bundle 内找到
        let binDir = (binaryPath as NSString).deletingLastPathComponent
        process.environment = [
            "PATH": "\(binDir):/usr/bin:/bin",
            "HOME": NSHomeDirectory()
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // stderr 进度解析（使用线程安全缓冲区）
        let stderrBuffer = ThreadSafeStringBuffer()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            stderrBuffer.append(text)

            // 解析进度
            if let progress = FFmpegRunner.parseProgressStatic(from: text, totalDuration: totalDuration) {
                onProgress?(progress)
            }
        }

        self.runningProcess = process

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: stdoutData)
                } else {
                    continuation.resume(throwing: FFmpegError.executionFailed(
                        exitCode: proc.terminationStatus,
                        stderr: stderrBuffer.value
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            // 超时保护：5 分钟后终止进程（避免永久挂起）
            DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
                if process.isRunning {
                    MixLog.error("FFmpeg 进程超时（5分钟），强制终止")
                    process.terminate()
                }
            }
        }
    }

    /// 执行 FFmpeg 命令并返回 stderr（用于获取元数据、场景检测等）
    func runForStderr(arguments: [String]) async throws -> String {
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            throw FFmpegError.binaryNotFound
        }

        return try await withCheckedThrowingContinuation { [binaryPath] continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binaryPath)
            process.arguments = arguments
            process.qualityOfService = .userInitiated
            let binDir = (binaryPath as NSString).deletingLastPathComponent
            process.environment = ["PATH": "\(binDir):/usr/bin:/bin", "HOME": NSHomeDirectory()]

            let stderrPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderrPipe

            process.terminationHandler = { _ in
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: output)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// 取消当前执行
    func cancel() {
        runningProcess?.terminate()
        runningProcess = nil
    }

    // MARK: - 便捷方法

    /// 提取音频为 16kHz mono WAV（用于 ASR）
    func extractAudio(from videoPath: String, to outputPath: String,
                      onProgress: (@Sendable (FFmpegProgress) -> Void)? = nil) async throws {
        let args = [
            "-i", videoPath,
            "-vn",                  // 不处理视频
            "-acodec", "pcm_s16le", // 16-bit PCM
            "-ar", "16000",         // 16kHz
            "-ac", "1",             // mono
            "-y",                   // 覆盖输出
            outputPath
        ]
        _ = try await run(arguments: args, onProgress: onProgress)
    }

    /// 裁切视频片段（精确裁切，-i 在 -ss 前确保帧精度）
    func cutSegment(from videoPath: String, start: Double, end: Double,
                    to outputPath: String) async throws {
        let args = [
            "-i", videoPath,
            "-ss", String(format: "%.3f", start),
            "-to", String(format: "%.3f", end),
            "-c", "copy",
            "-avoid_negative_ts", "make_zero",
            "-y",
            outputPath
        ]
        _ = try await run(arguments: args)
    }

    /// 探测视频文件是否包含音频轨道（异步，不阻塞 actor 线程）
    private func probeHasAudio(path: String) async -> Bool {
        let ffprobePath = binaryPath.replacingOccurrences(of: "/ffmpeg", with: "/ffprobe")
        guard FileManager.default.fileExists(atPath: ffprobePath) else {
            return true  // 无 ffprobe 时默认有音频
        }

        do {
            // 利用已有的 runForStderr 思路，用 withCheckedContinuation 异步等待
            return await withCheckedContinuation { continuation in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffprobePath)
                process.arguments = [
                    "-v", "quiet",
                    "-select_streams", "a",
                    "-show_entries", "stream=codec_type",
                    "-of", "csv=p=0",
                    path
                ]
                process.qualityOfService = .userInitiated
                let binDir = (ffprobePath as NSString).deletingLastPathComponent
                process.environment = ["PATH": "\(binDir):/usr/bin:/bin", "HOME": NSHomeDirectory()]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                process.terminationHandler = { _ in
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: output.contains("audio"))
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: true) // 出错时默认有音频
                }
            }
        }
    }

    /// 拼接多个视频片段为一个 MP4（统一编码，确保多源视频可混剪）
    /// 使用 filter_complex concat 方式，自动处理不同分辨率/编码/帧率
    func concat(segments: [(path: String, start: Double, end: Double)],
                outputPath: String,
                resolution: String? = nil,
                crf: Int = 18,
                codec: String = "libx264",
                onProgress: (@Sendable (FFmpegProgress) -> Void)? = nil) async throws {
        guard !segments.isEmpty else { return }

        // 并行探测每个输入是否有音频轨道
        let hasAudio: [Bool] = await withTaskGroup(of: (Int, Bool).self) { group in
            for (i, seg) in segments.enumerated() {
                group.addTask { [self] in
                    let has = await self.probeHasAudio(path: seg.path)
                    return (i, has)
                }
            }
            var results = Array(repeating: true, count: segments.count)
            for await (i, has) in group {
                results[i] = has
            }
            return results
        }

        // 构建 FFmpeg 命令：多输入 + filter_complex 统一编码拼接
        var args: [String] = []

        // 添加所有视频输入（精确裁切用 -ss/-to）
        for seg in segments {
            args += ["-ss", String(format: "%.3f", seg.start),
                     "-to", String(format: "%.3f", seg.end),
                     "-i", seg.path]
        }

        // 添加沉默音频生成器作为额外输入（索引 = segments.count）
        // 用于替代无音轨片段的音频
        let silenceInputIndex = segments.count
        args += ["-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo"]

        // 构建 filter_complex：统一缩放到目标分辨率 + concat
        let targetScale = resolution ?? "1080:1920"  // 默认竖屏 1080x1920
        var filterParts: [String] = []

        for i in 0..<segments.count {
            // 统一缩放 + 填充黑边 + 统一帧率 + 时间戳重置
            filterParts.append(
                "[\(i):v]scale=\(targetScale):force_original_aspect_ratio=decrease," +
                "pad=\(targetScale):(ow-iw)/2:(oh-ih)/2:black," +
                "setsar=1,fps=30[v\(i)]"
            )
            // 音频处理：有音轨使用原始音频 + loudnorm；无音轨使用沉默源裁切
            let segDuration = segments[i].end - segments[i].start
            let durStr = String(format: "%.6f", segDuration)
            if hasAudio[i] {
                filterParts.append(
                    "[\(i):a]aresample=44100,loudnorm=I=-16:TP=-1.5:LRA=11,apad=whole_dur=\(durStr)[a\(i)]"
                )
            } else {
                // 无音轨：从沉默源裁切出对应时长的静音
                filterParts.append(
                    "[\(silenceInputIndex):a]atrim=0:\(durStr),asetpts=PTS-STARTPTS[a\(i)]"
                )
            }
        }

        // concat 所有流（FFmpeg concat filter 要求输入按 segment 交替：[v0][a0][v1][a1]...）
        let concatInputs = (0..<segments.count).map { "[v\($0)][a\($0)]" }.joined()
        filterParts.append(
            "\(concatInputs)concat=n=\(segments.count):v=1:a=1[outv][outa]"
        )

        let filterComplex = filterParts.joined(separator: ";")
        args += ["-filter_complex", filterComplex]
        args += ["-map", "[outv]", "-map", "[outa]"]

        // 编码设置：根据质量等级调整 preset
        let preset: String
        switch crf {
        case 0...10:  preset = "slower"   // 无损/极高质量
        case 11...20: preset = "slow"     // 高质量
        case 21...25: preset = "medium"   // 中等质量
        default:      preset = "fast"     // 快速导出
        }
        args += ["-c:v", codec, "-crf", "\(crf)", "-preset", preset]
        args += ["-c:a", "aac", "-b:a", "192k"]
        args += ["-movflags", "+faststart"]  // 支持网络流式播放（信息流广告必须）
        args += ["-y", outputPath]

        let totalDuration = segments.reduce(0.0) { $0 + ($1.end - $1.start) }
        _ = try await run(arguments: args, totalDuration: totalDuration, onProgress: onProgress)
    }

    /// 生成视频缩略图
    func generateThumbnail(from videoPath: String, at time: Double = 1.0,
                           to outputPath: String) async throws {
        let args = [
            "-ss", String(format: "%.3f", time),
            "-i", videoPath,
            "-frames:v", "1",
            "-update", "1",
            "-q:v", "2",
            "-y",
            outputPath
        ]
        _ = try await run(arguments: args)
    }

    // MARK: - 进度解析

    /// 从 FFmpeg stderr 输出中解析进度信息
    private static func parseProgressStatic(from text: String, totalDuration: Double?) -> FFmpegProgress? {
        // FFmpeg 输出格式: frame=  123 fps= 60 ... time=00:01:30.00 speed=1.2x
        guard let timeMatch = text.range(of: #"time=(\d{2}):(\d{2}):(\d{2}\.\d+)"#,
                                         options: .regularExpression) else {
            return nil
        }

        let timeStr = String(text[timeMatch])
        let components = timeStr.replacingOccurrences(of: "time=", with: "").split(separator: ":")
        guard components.count == 3,
              let hours = Double(components[0]),
              let minutes = Double(components[1]),
              let seconds = Double(components[2]) else {
            return nil
        }

        let currentTime = hours * 3600 + minutes * 60 + seconds

        // 解析 frame
        let frame: Int
        if let frameMatch = text.range(of: #"frame=\s*(\d+)"#, options: .regularExpression) {
            let frameStr = String(text[frameMatch]).replacingOccurrences(of: "frame=", with: "").trimmingCharacters(in: .whitespaces)
            frame = Int(frameStr) ?? 0
        } else {
            frame = 0
        }

        // 解析 fps
        let fps: Double
        if let fpsMatch = text.range(of: #"fps=\s*([\d.]+)"#, options: .regularExpression) {
            let fpsStr = String(text[fpsMatch]).replacingOccurrences(of: "fps=", with: "").trimmingCharacters(in: .whitespaces)
            fps = Double(fpsStr) ?? 0
        } else {
            fps = 0
        }

        // 解析 speed
        let speed: Double
        if let speedMatch = text.range(of: #"speed=\s*([\d.]+)x"#, options: .regularExpression) {
            let speedStr = String(text[speedMatch]).replacingOccurrences(of: "speed=", with: "").replacingOccurrences(of: "x", with: "").trimmingCharacters(in: .whitespaces)
            speed = Double(speedStr) ?? 0
        } else {
            speed = 0
        }

        let percentage: Double
        if let total = totalDuration, total > 0 {
            percentage = min(currentTime / total, 1.0)
        } else {
            percentage = 0
        }

        return FFmpegProgress(
            frame: frame,
            fps: fps,
            time: currentTime,
            speed: speed,
            percentage: percentage
        )
    }
}
