import Foundation

/// 场景边界（画面切换点）
struct SceneBoundary: Sendable {
    let time: Double        // 场景切换时间点（秒）
    let confidence: Double  // 置信度 0-1
}

/// 静音段
struct SilencePeriod: Sendable {
    let start: Double
    let end: Double
    var duration: Double { end - start }
    var midpoint: Double { (start + end) / 2 }
}

/// I-frame 关键帧位置
struct KeyframePosition: Sendable {
    let time: Double        // I-frame 精确时间（秒）
}

/// 视频本地分析完整结果（传给 AI 之前的所有本地数据）
struct VideoLocalAnalysis: Sendable {
    let sceneBoundaries: [SceneBoundary]    // 画面切换点
    let silencePeriods: [SilencePeriod]     // 静音/停顿段
    let iframePositions: [Double]           // I-frame 时间点
    let videoDuration: Double
    let fps: Double
}

/// 视频本地分析服务（场景检测 + 静音检测 + I-frame 提取）
actor SceneDetectionService {

    private let ffmpeg: FFmpegRunner

    init(ffmpeg: FFmpegRunner = FFmpegRunner()) {
        self.ffmpeg = ffmpeg
    }

    // MARK: - 场景切换检测

    /// 使用 FFmpeg scene filter 检测镜头切换点
    func detectScenes(in videoPath: String, threshold: Double = 0.3) async throws -> [SceneBoundary] {
        let args = [
            "-i", videoPath,
            "-vf", "select='gt(scene,\(threshold))',showinfo",
            "-f", "null",
            "-"
        ]

        let stderr = try await ffmpeg.runForStderr(arguments: args)
        return parseSceneBoundaries(from: stderr)
    }

    // MARK: - 音频静音检测

    /// 使用 FFmpeg silencedetect 检测静音/停顿段
    /// - Parameters:
    ///   - videoPath: 视频文件路径
    ///   - noiseThreshold: 静音判定噪声阈值（默认 -30dB）
    ///   - minDuration: 最短静音时长（秒，默认 0.3）
    func detectSilence(
        in videoPath: String,
        noiseThreshold: String = "-30dB",
        minDuration: Double = 0.3
    ) async throws -> [SilencePeriod] {
        let args = [
            "-i", videoPath,
            "-af", "silencedetect=noise=\(noiseThreshold):d=\(minDuration)",
            "-f", "null",
            "-"
        ]

        let stderr = try await ffmpeg.runForStderr(arguments: args)
        return parseSilencePeriods(from: stderr)
    }

    // MARK: - I-frame 关键帧提取

    /// 提取视频中所有 I-frame 的精确时间戳
    /// I-frame 是视频编码中的完整帧，在 I-frame 处切割不会产生花屏
    func extractIFrames(in videoPath: String) async throws -> [Double] {
        // 使用 ffmpeg select I-frame + showinfo 提取时间
        let args = [
            "-i", videoPath,
            "-vf", "select='eq(pict_type\\,I)',showinfo",
            "-f", "null",
            "-"
        ]

        let stderr = try await ffmpeg.runForStderr(arguments: args)
        return parseIFrameTimes(from: stderr)
    }

    // MARK: - 一次性执行所有本地分析

    /// 依次执行所有本地视频分析（场景检测 + 静音检测 + I-frame 提取）
    func analyzeLocally(
        videoPath: String,
        duration: Double,
        fps: Double,
        sceneThreshold: Double = 0.3
    ) async throws -> VideoLocalAnalysis {
        // 三步并行执行（场景检测、静音检测、I-frame 提取互相独立）
        async let scenesTask: [SceneBoundary] = {
            do {
                let result = try await detectScenes(in: videoPath, threshold: sceneThreshold)
                MixLog.info(" 场景检测完成: \(result.count) 个切换点")
                return result
            } catch {
                MixLog.error(" 场景检测失败: \(error.localizedDescription)")
                return []
            }
        }()

        async let silencesTask: [SilencePeriod] = {
            do {
                let result = try await detectSilence(in: videoPath)
                MixLog.info(" 静音检测完成: \(result.count) 个静音段")
                return result
            } catch {
                MixLog.error(" 静音检测失败: \(error.localizedDescription)")
                return []
            }
        }()

        async let iframesTask: [Double] = {
            do {
                let result = try await extractIFrames(in: videoPath)
                MixLog.info(" I-frame 提取完成: \(result.count) 个关键帧")
                return result
            } catch {
                MixLog.error(" I-frame 提取失败: \(error.localizedDescription)")
                return []
            }
        }()

        let (scenes, silences, iframes) = await (scenesTask, silencesTask, iframesTask)

        return VideoLocalAnalysis(
            sceneBoundaries: scenes,
            silencePeriods: silences,
            iframePositions: iframes,
            videoDuration: duration,
            fps: fps
        )
    }

    // MARK: - 解析方法

    /// 解析场景边界
    private func parseSceneBoundaries(from output: String) -> [SceneBoundary] {
        var boundaries: [SceneBoundary] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            guard line.contains("showinfo") else { continue }

            if let range = line.range(of: #"pts_time:\s*([\d.]+)"#, options: .regularExpression) {
                let match = String(line[range])
                let timeStr = match.replacingOccurrences(of: "pts_time:", with: "").trimmingCharacters(in: .whitespaces)
                if let time = Double(timeStr) {
                    var confidence = 0.5
                    if let scoreRange = line.range(of: #"scene_score=([\d.]+)"#, options: .regularExpression) {
                        let scoreStr = String(line[scoreRange])
                            .replacingOccurrences(of: "scene_score=", with: "")
                        confidence = Double(scoreStr) ?? 0.5
                    }
                    boundaries.append(SceneBoundary(time: time, confidence: confidence))
                }
            }
        }

        return boundaries.sorted { $0.time < $1.time }
    }

    /// 解析静音段
    /// FFmpeg 输出格式:
    /// [silencedetect] silence_start: 2.10000
    /// [silencedetect] silence_end: 2.30000 | silence_duration: 0.20000
    private func parseSilencePeriods(from output: String) -> [SilencePeriod] {
        var periods: [SilencePeriod] = []
        var currentStart: Double?
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            guard line.contains("silencedetect") else { continue }

            if let range = line.range(of: #"silence_start:\s*([\d.]+)"#, options: .regularExpression) {
                let str = String(line[range])
                    .replacingOccurrences(of: "silence_start:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                currentStart = Double(str)
            }

            if let range = line.range(of: #"silence_end:\s*([\d.]+)"#, options: .regularExpression) {
                let str = String(line[range])
                    .replacingOccurrences(of: "silence_end:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if let end = Double(str), let start = currentStart {
                    periods.append(SilencePeriod(start: start, end: end))
                    currentStart = nil
                }
            }
        }

        return periods.sorted { $0.start < $1.start }
    }

    /// 解析 I-frame 时间戳
    /// showinfo 输出格式: [Parsed_showinfo_1 ...] n:0 pts:0 pts_time:0.000000 ...
    private func parseIFrameTimes(from output: String) -> [Double] {
        var times: [Double] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            guard line.contains("showinfo") else { continue }

            if let range = line.range(of: #"pts_time:\s*([\d.]+)"#, options: .regularExpression) {
                let str = String(line[range])
                    .replacingOccurrences(of: "pts_time:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if let time = Double(str) {
                    times.append(time)
                }
            }
        }

        return times.sorted()
    }
}
