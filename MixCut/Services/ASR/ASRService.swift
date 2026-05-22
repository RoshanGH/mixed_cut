import Foundation

/// Whisper 模型下载进度（真实字节数 + 速度）
struct DownloadProgress: Sendable {
    let receivedBytes: Int64
    let totalBytes: Int64
    let bytesPerSecond: Double

    var fraction: Double {
        totalBytes > 0 ? Double(receivedBytes) / Double(totalBytes) : 0
    }
}

/// ASR 识别结果
struct TranscriptionResult: Sendable {
    let text: String                      // 完整转录文本
    let words: [ASRWord]                  // 字级时间戳
    let rawSentences: [ASRSentence]       // Whisper 原生句子（segment 级）
    let language: String                  // 检测到的语言
    let duration: Double                  // 音频时长

    /// 空结果
    static func empty(language: String = "zh") -> TranscriptionResult {
        TranscriptionResult(text: "", words: [], rawSentences: [], language: language, duration: 0)
    }

    /// 句子列表：3 级降级，确保任何情况下都能拿到合理粒度的句子。
    ///
    /// 关键防御：Whisper 在「短视频 + 一气呵成的口播」下经常把整段压成 1 个长 segment，
    /// 导致下游所有依赖句级时间戳的功能（AI 分镜、UI 显示、台词编辑）全部失效。
    /// 因此即使有 rawSentences，也要先检测异常 → 异常时强制重切。
    var sentences: [TranscriptionSentence] {
        // ⚠️ 修复（v0.2.4 第二版）：禁止用 buildSentencesFromWords 做整体替换。
        // whisper.cpp 的 words 输出会丢失部分 token（特殊字符 / 控制 token），拼接会丢字。
        // 只有「单 segment 且 >8s 且 >30 字」时才走 textFallback（按标点重切，文字完整）。
        let isSingleLongSegment: Bool = {
            guard rawSentences.count == 1 else { return false }
            let s = rawSentences[0]
            return (s.end - s.start) > 8.0 && s.text.count > 30
        }()

        if !rawSentences.isEmpty && !isSingleLongSegment {
            // 正常路径：用 whisper 原生切分（多 segment 永远走这里，文字 100% 完整）
            return rawSentences.map { s in
                let sentenceWords = words.filter { w in
                    w.start < s.end && w.end > s.start
                }
                return TranscriptionSentence(
                    text: s.text,
                    startTime: s.start,
                    endTime: s.end,
                    words: sentenceWords
                )
            }
        }

        // 单 segment 整段压成一行 → 按标点重切（文字完整，只重切粒度）
        if !rawSentences.isEmpty {
            return buildSentencesFromTextFallback()
        }

        return []
    }

    /// 降级方案：从 words 聚合句子
    private func buildSentencesFromWords() -> [TranscriptionSentence] {
        guard !words.isEmpty else { return [] }

        var sentences: [TranscriptionSentence] = []
        var currentWords: [ASRWord] = []
        let pauseThreshold: Double = 0.5

        for (index, word) in words.enumerated() {
            currentWords.append(word)

            let isSentenceEnd = word.word.hasSuffix("。") ||
                                word.word.hasSuffix("！") ||
                                word.word.hasSuffix("？") ||
                                word.word.hasSuffix(".") ||
                                word.word.hasSuffix("!") ||
                                word.word.hasSuffix("?")

            let hasLongPause: Bool
            if index + 1 < words.count {
                hasLongPause = words[index + 1].start - word.end >= pauseThreshold
            } else {
                hasLongPause = false
            }

            // 兜底：累积超过 30 字且遇到逗号或顿号时也断句
            let currentText = currentWords.map(\.word).joined()
            let isLongWithComma = currentText.count > 30 && (
                word.word.hasSuffix("，") || word.word.hasSuffix("、") || word.word.hasSuffix(",")
            )

            if (isSentenceEnd || hasLongPause || isLongWithComma) && !currentWords.isEmpty {
                let text = currentWords.map(\.word).joined()
                guard let first = currentWords.first, let last = currentWords.last else { continue }
                let start = first.start
                let end = last.end
                sentences.append(TranscriptionSentence(
                    text: text,
                    startTime: start,
                    endTime: end,
                    words: currentWords
                ))
                currentWords = []
            }
        }

        if let first = currentWords.first, let last = currentWords.last {
            let text = currentWords.map(\.word).joined()
            let start = first.start
            let end = last.end
            sentences.append(TranscriptionSentence(
                text: text,
                startTime: start,
                endTime: end,
                words: currentWords
            ))
        }

        return sentences
    }

    /// 终极兜底：rawSentences 太粗 + 没有 words 时，用标点切分 + 按字符比例均分时间
    /// 用例：whisper.cpp 没启用 word timestamps，只有 1 个长 segment
    private func buildSentencesFromTextFallback() -> [TranscriptionSentence] {
        guard let raw = rawSentences.first else { return [] }
        let totalStart = rawSentences.first?.start ?? 0
        let totalEnd = rawSentences.last?.end ?? 0
        let fullText = rawSentences.map(\.text).joined()
        let totalDuration = max(0.1, totalEnd - totalStart)

        // 按标点切（句号/问号/感叹号/逗号/分号都算）
        let separators: Set<Character> = ["。", "！", "？", "，", "、", ";", "；", ".", "!", "?", ","]
        var pieces: [String] = []
        var current = ""
        for ch in fullText {
            current.append(ch)
            if separators.contains(ch) && current.count >= 8 {
                pieces.append(current)
                current = ""
            }
        }
        let remainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty { pieces.append(remainder) }

        // 没标点的极端情况：按 15 字硬切
        if pieces.count <= 1 {
            pieces = []
            var buf = ""
            for ch in fullText {
                buf.append(ch)
                if buf.count >= 15 {
                    pieces.append(buf)
                    buf = ""
                }
            }
            if !buf.isEmpty { pieces.append(buf) }
        }

        guard !pieces.isEmpty else {
            return [TranscriptionSentence(text: raw.text, startTime: totalStart, endTime: totalEnd, words: [])]
        }

        // 按字数比例分配时间戳
        let totalChars = pieces.reduce(0) { $0 + $1.count }
        var t = totalStart
        var result: [TranscriptionSentence] = []
        for piece in pieces {
            let ratio = totalChars > 0 ? Double(piece.count) / Double(totalChars) : 0
            let segDur = totalDuration * ratio
            let segEnd = min(t + segDur, totalEnd)
            result.append(TranscriptionSentence(
                text: piece,
                startTime: t,
                endTime: segEnd,
                words: []
            ))
            t = segEnd
        }
        return result
    }
}

/// 转录句子
struct TranscriptionSentence: Sendable {
    let text: String
    let startTime: Double
    let endTime: Double
    let words: [ASRWord]

    var duration: Double { endTime - startTime }
}

/// ASR 语音识别服务
/// 支持 Python openai-whisper CLI 和 whisper.cpp
actor ASRService {

    private let ffmpeg: FFmpegRunner

    init(ffmpeg: FFmpegRunner = FFmpegRunner()) {
        self.ffmpeg = ffmpeg
    }

    /// 检查 whisper 是否可用
    static var isAvailable: Bool {
        findWhisperBinaryStatic() != nil
    }

    /// 对视频进行语音识别
    func transcribe(
        videoPath: String,
        language: String = "zh",
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        // Step 1: 提取音频为 16kHz mono WAV
        onProgress?(0.1)
        let tempWavPath = FileHelper.tempDirectory
            .appendingPathComponent("audio_\(UUID().uuidString).wav").path

        try await ffmpeg.extractAudio(from: videoPath, to: tempWavPath)
        onProgress?(0.3)

        defer {
            try? FileManager.default.removeItem(atPath: tempWavPath)
        }

        // Step 2: 检测 whisper 类型并调用
        guard let whisperPath = ASRService.findWhisperBinaryStatic() else {
            MixLog.error("Whisper 未找到，语音识别跳过")
            throw ASRError.whisperNotFound
        }

        onProgress?(0.4)

        let whisperType = detectWhisperType(path: whisperPath)
        let result: TranscriptionResult

        switch whisperType {
        case .python:
            result = try await runPythonWhisper(
                whisperPath: whisperPath,
                audioPath: tempWavPath,
                language: language,
                onProgress: onProgress
            )
        case .cpp:
            result = try await runWhisperCpp(
                whisperPath: whisperPath,
                audioPath: tempWavPath,
                language: language,
                onProgress: onProgress
            )
        }

        onProgress?(1.0)

        // 健康指标埋点：ASR 输出粒度异常告警
        let sentencesCount = result.sentences.count
        let rawCount = result.rawSentences.count
        let wordsCount = result.words.count
        let duration = result.duration
        if rawCount == 1 && duration > 8.0 {
            MixLog.error("⚠️ ASR 输出粒度异常：rawSentences=1（全文一段），时长 \(String(format: "%.1f", duration))s，已自动二次切分为 \(sentencesCount) 句")
        }
        MixLog.info("ASR 完成：原生 \(rawCount) segments / words \(wordsCount) / 最终 \(sentencesCount) 句")
        return result
    }

    // MARK: - Whisper 类型检测

    private enum WhisperType {
        case python
        case cpp
    }

    private func detectWhisperType(path: String) -> WhisperType {
        // 检查文件内容：Python whisper 是脚本，whisper.cpp 是二进制
        if let data = FileManager.default.contents(atPath: path),
           let header = String(data: data.prefix(256), encoding: .utf8),
           header.contains("python") {
            return .python
        }
        return .cpp
    }

    // MARK: - Python openai-whisper

    /// 使用 Python openai-whisper CLI 进行识别
    private func runPythonWhisper(
        whisperPath: String,
        audioPath: String,
        language: String,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> TranscriptionResult {
        let outputDir = FileHelper.tempDirectory
            .appendingPathComponent("whisper_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: outputDir)
        }

        // Python whisper CLI:
        // whisper audio.wav --model small --language zh --output_format json
        //   --output_dir /tmp/xxx --word_timestamps True
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        // ⚠️ 同样不用 --max_line_count/--max_line_width 强制切段
        // 原因见 runWhisperCpp 注释。粒度问题完全由 TranscriptionResult.sentences 二次切分解决。
        process.arguments = [
            audioPath,
            "--model", "small",
            "--language", language,
            "--output_format", "json",
            "--output_dir", outputDir.path,
            "--word_timestamps", "True"
        ]
        process.qualityOfService = .userInitiated
        let binDir = (whisperPath as NSString).deletingLastPathComponent
        process.environment = ["PATH": "\(binDir):/usr/bin:/bin", "HOME": NSHomeDirectory()]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let jsonData: Data? = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { @Sendable _ in
                    // Python whisper 输出文件名 = 输入文件名.json
                    let audioFileName = URL(fileURLWithPath: audioPath).deletingPathExtension().lastPathComponent
                    let jsonPath = outputDir.appendingPathComponent("\(audioFileName).json").path
                    let data = FileManager.default.contents(atPath: jsonPath)
                    continuation.resume(returning: data)
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // 超时保护：5 分钟后终止进程
                DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
                    if process.isRunning {
                        MixLog.error("Python Whisper 进程超时（5分钟），强制终止")
                        process.terminate()
                    }
                }
            }
        }, onCancel: {
            if process.isRunning {
                MixLog.info("Python Whisper 进程因 Task 取消被终止")
                process.terminate()
            }
        })

        onProgress?(0.9)

        guard let jsonData else {
            return .empty(language: language)
        }

        return try parsePythonWhisperOutput(jsonData: jsonData, language: language)
    }

    /// 解析 Python whisper JSON 输出
    private func parsePythonWhisperOutput(jsonData: Data, language: String) throws -> TranscriptionResult {
        // Python whisper JSON 格式:
        // { "text": "...", "segments": [{ "start": 0.0, "end": 5.0, "text": "...",
        //   "words": [{"word": "...", "start": 0.0, "end": 0.5, "probability": 0.99}] }] }
        struct PythonWhisperOutput: Decodable {
            let text: String
            let segments: [Segment]
            let language: String?

            struct Segment: Decodable {
                let start: Double
                let end: Double
                let text: String
                let words: [Word]?
            }

            struct Word: Decodable {
                let word: String
                let start: Double
                let end: Double
                let probability: Double?
            }
        }

        let output = try JSONDecoder().decode(PythonWhisperOutput.self, from: jsonData)

        // 提取字级时间戳
        var words: [ASRWord] = []
        for segment in output.segments {
            if let segWords = segment.words {
                for w in segWords {
                    let cleaned = Self.cleanWhisperToken(w.word)
                    guard !cleaned.isEmpty else { continue }
                    words.append(ASRWord(
                        word: cleaned,
                        start: w.start,
                        end: w.end
                    ))
                }
            }
        }

        // 保存 Whisper 原生 segments 作为句子（这才是准确的句子划分）
        let rawSentences = output.segments.compactMap { seg -> ASRSentence? in
            let cleaned = Self.cleanWhisperText(seg.text)
            guard !cleaned.isEmpty else { return nil }
            return ASRSentence(
                text: cleaned,
                start: seg.start,
                end: seg.end
            )
        }

        let duration = output.segments.last?.end ?? 0
        return TranscriptionResult(
            text: output.text,
            words: words,
            rawSentences: rawSentences,
            language: output.language ?? language,
            duration: duration
        )
    }

    // MARK: - whisper.cpp

    /// 使用 whisper.cpp CLI 进行识别
    private func runWhisperCpp(
        whisperPath: String,
        audioPath: String,
        language: String,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> TranscriptionResult {
        var modelPath = findWhisperCppModel()
        if modelPath == nil {
            // 模型不存在，尝试自动下载
            MixLog.info("Whisper 模型未找到，开始自动下载 ggml-large-v3-turbo...")
            modelPath = try? await downloadModelIfNeeded(modelName: "ggml-large-v3-turbo")
        }
        guard let modelPath else {
            MixLog.error("Whisper 模型下载失败或未找到")
            throw ASRError.modelNotFound
        }

        let outputPath = FileHelper.tempDirectory
            .appendingPathComponent("whisper_\(UUID().uuidString)").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        // ⚠️ 关键决定：不使用 -ml 强制切段。
        // 之前尝试过 -ml 60 + -sow + --word-thold，结果是 whisper 在每个 60 token 边界强制
        // 切换上下文，导致长上下文的识别能力被破坏，识别内容大量错误。
        //
        // 正确做法：让 whisper 保持默认 30s 大段识别（最佳识别质量），
        // 然后依赖 TranscriptionResult.sentences 的二次切分逻辑（防御层 2）
        // 根据 words 时间戳重新切句子。
        process.arguments = [
            "-m", modelPath,
            "-f", audioPath,
            "-l", language,
            "--output-json-full",
            "-of", outputPath
        ]
        process.qualityOfService = .userInitiated
        let binDir = (whisperPath as NSString).deletingLastPathComponent
        process.environment = ["PATH": "\(binDir):/usr/bin:/bin", "HOME": NSHomeDirectory()]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let jsonData: Data? = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { @Sendable _ in
                    let jsonPath = outputPath + ".json"
                    let data = FileManager.default.contents(atPath: jsonPath)
                    try? FileManager.default.removeItem(atPath: jsonPath)
                    continuation.resume(returning: data)
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }

                // 超时保护：5 分钟后终止进程
                DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
                    if process.isRunning {
                        MixLog.error("Whisper 进程超时（5分钟），强制终止")
                        process.terminate()
                    }
                }
            }
        }, onCancel: {
            // Task 被取消（用户删除视频等场景）→ 立即终止 Whisper 进程
            if process.isRunning {
                MixLog.info("Whisper 进程因 Task 取消被终止")
                process.terminate()
            }
        })

        onProgress?(0.9)

        guard let jsonData else {
            return .empty(language: language)
        }

        return try parseWhisperCppOutput(jsonData: jsonData, language: language)
    }

    /// 解析 whisper.cpp JSON 输出
    private func parseWhisperCppOutput(jsonData: Data, language: String) throws -> TranscriptionResult {
        struct WhisperCppOutput: Decodable {
            struct Segment: Decodable {
                struct Token: Decodable {
                    let text: String
                    let timestamps: Timestamps?

                    struct Timestamps: Decodable {
                        let from: String
                        let to: String
                    }
                }
                let text: String
                let tokens: [Token]?
                let timestamps: TokenTimestamps?

                struct TokenTimestamps: Decodable {
                    let from: String
                    let to: String
                }
            }
            let transcription: [Segment]
        }

        // whisper.cpp 输出可能包含非 UTF-8 字节（中文分词截断），需要先清洗
        let cleanedData: Data
        if let str = String(data: jsonData, encoding: .utf8) {
            // 移除 U+FFFD 替换字符（UTF-8 解码失败的残留）
            let cleaned = str.replacingOccurrences(of: "\u{FFFD}", with: "")
            cleanedData = cleaned.data(using: .utf8) ?? jsonData
        } else {
            // 强制替换无效字节，然后移除 U+FFFD
            let str = String(decoding: jsonData, as: UTF8.self)
                .replacingOccurrences(of: "\u{FFFD}", with: "")
            cleanedData = str.data(using: .utf8) ?? jsonData
        }
        let output = try JSONDecoder().decode(WhisperCppOutput.self, from: cleanedData)

        var words: [ASRWord] = []

        for segment in output.transcription {
            if let tokens = segment.tokens {
                for token in tokens {
                    let text = Self.cleanWhisperToken(token.text)
                    // 过滤特殊 token 和空内容
                    if text.isEmpty { continue }
                    guard let ts = token.timestamps else { continue }
                    let start = parseTimestamp(ts.from)
                    let end = parseTimestamp(ts.to)
                    guard end > start else { continue }
                    words.append(ASRWord(word: text, start: start, end: end))
                }
            }
        }

        // whisper.cpp 的 transcription 段也作为原生句子
        let rawSentences = output.transcription.compactMap { seg -> ASRSentence? in
            let cleaned = Self.cleanWhisperText(seg.text)
            guard !cleaned.isEmpty else { return nil }
            return ASRSentence(
                text: cleaned,
                start: parseTimestamp(seg.timestamps?.from ?? "00:00:00.000"),
                end: parseTimestamp(seg.timestamps?.to ?? "00:00:00.000")
            )
        }

        let fullText = rawSentences.map(\.text).joined()
        let duration = words.last?.end ?? 0

        return TranscriptionResult(text: fullText, words: words, rawSentences: rawSentences, language: language, duration: duration)
    }

    // MARK: - 文本清洗

    /// 清洗 whisper.cpp 单个 token 文本
    /// - 过滤特殊控制标记（[_BEG_], [BLANK_AUDIO], <|endoftext|> 等）
    /// - 移除前后空白
    /// - 移除 U+FFFD 替换字符
    private static func cleanWhisperToken(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // 过滤 whisper.cpp 特殊 token
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("<|") { return "" }
        // 移除 U+FFFD 替换字符（UTF-8 解码失败的残留，显示为乱码 �）
        let cleaned = trimmed.replacingOccurrences(of: "\u{FFFD}", with: "")
        // 过滤纯空白或纯标点
        if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        return cleaned
    }

    /// 清洗 whisper.cpp segment 级文本
    /// - trim 空白和换行
    /// - 移除 U+FFFD 替换字符
    /// - 合并连续空格为单个空格
    private static func cleanWhisperText(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 移除 U+FFFD
        text = text.replacingOccurrences(of: "\u{FFFD}", with: "")
        // 合并连续空格
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 解析时间戳字符串 "00:00:01.234" 或 "00:00:01,234" -> 秒
    private func parseTimestamp(_ str: String) -> Double {
        // whisper.cpp --output-json-full 用逗号分隔毫秒: "00:00:01,234"
        let normalized = str.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":")
        guard parts.count == 3 else { return 0 }
        let hours = Double(parts[0]) ?? 0
        let minutes = Double(parts[1]) ?? 0
        let seconds = Double(parts[2]) ?? 0
        return hours * 3600 + minutes * 60 + seconds
    }

    // MARK: - 查找二进制和模型

    /// 当前是否为 Intel Mac
    private static let isIntelMac: Bool = {
        #if arch(x86_64)
        return true
        #else
        return false
        #endif
    }()

    /// 查找 whisper 二进制（静态方法，供外部检测用）
    static func findWhisperBinaryStatic() -> String? {
        // 优先 bundle 内的 whisper（使用 resourceURL 拼接，folder reference 下最可靠）
        let bundledPath = findBundledBinary("whisper")

        // 系统路径仅作为开发期 fallback（whisper-cli 是 homebrew whisper-cpp 的 CLI 名称）
        let candidates = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper-cpp",
            "/opt/homebrew/bin/whisper",
            "/usr/local/bin/whisper"
        ]
        let systemPath = candidates.first { FileManager.default.fileExists(atPath: $0) }

        if let bundledPath {
            return bundledPath
        }
        return systemPath
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

    /// 从 Bundle 中查找模型文件（兼容 folder reference）
    private static func findBundledModel(_ name: String) -> String? {
        if let binURL = Bundle.main.resourceURL?.appendingPathComponent("bin").appendingPathComponent("\(name).bin"),
           FileManager.default.fileExists(atPath: binURL.path) {
            return binURL.path
        }
        if let path = Bundle.main.path(forResource: name, ofType: "bin", inDirectory: "bin") {
            return path
        }
        if let path = Bundle.main.path(forResource: name, ofType: "bin") {
            return path
        }
        return nil
    }

    /// 查找 whisper.cpp 模型文件（优先大模型，准确率更高）
    private nonisolated func findWhisperCppModel() -> String? {
        let modelNames = ["ggml-large-v3-turbo", "ggml-medium", "ggml-small", "ggml-base"]

        // 优先 bundle 内
        for name in modelNames {
            if let path = Self.findBundledModel(name) {
                return path
            }
        }

        // 应用缓存目录
        if let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let appModelDir = cacheDir.appendingPathComponent("com.mixcut.app/whisper-models").path
            for name in modelNames {
                let path = "\(appModelDir)/\(name).bin"
                if FileManager.default.fileExists(atPath: path) {
                    return path
                }
            }
        }

        // 系统目录（兼容旧版本和手动安装）
        let systemDirs = [
            NSHomeDirectory() + "/.cache/mixcut/models",
            NSHomeDirectory() + "/.cache/whisper",
            "/opt/homebrew/share/whisper/models"
        ]
        for dir in systemDirs {
            for name in modelNames {
                let path = "\(dir)/\(name).bin"
                if FileManager.default.fileExists(atPath: path) {
                    return path
                }
            }
        }

        return nil
    }

    /// 模型下载 URL（优先国内镜像，fallback 到 Hugging Face 原站）
    private static let modelDownloadURLs: [String: [String]] = [
        "ggml-large-v3-turbo": [
            "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
        ],
        "ggml-small": [
            "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-small.bin",
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin",
        ],
        "ggml-base": [
            "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-base.bin",
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin",
        ],
    ]

    /// 下载 whisper 模型到应用缓存目录
    /// - 真实字节数进度（流式读，每 250ms 回调一次）
    /// - HTTP Range 断点续传（partial 文件保留，下次接着下）
    /// - 每个镜像源重试 3 次（指数退避），失败再切下一个源
    /// - 可中断（响应 Task 取消）
    func downloadModelIfNeeded(
        modelName: String = "ggml-large-v3-turbo",
        onProgress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws -> String {
        if let existing = findWhisperCppModel() {
            return existing
        }

        guard let urls = Self.modelDownloadURLs[modelName], !urls.isEmpty else {
            throw ASRError.modelNotFound
        }

        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw ASRError.modelNotFound
        }
        let modelDir = cacheDir.appendingPathComponent("com.mixcut.app/whisper-models")
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        let destPath = modelDir.appendingPathComponent("\(modelName).bin").path
        let partialPath = destPath + ".partial"

        // 单次请求 60s 超时（卡住的连接快速失败切重试）；整体允许 2 小时（够续传多次）
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7200
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        var lastError: Error?

        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }
            let source = urlString.contains("hf-mirror") ? "国内镜像" : "HuggingFace"

            for attempt in 0..<3 {
                try Task.checkCancellation()

                if attempt > 0 {
                    let delaySec = UInt64(1) << UInt64(attempt) // 2s, 4s
                    MixLog.info("[\(source)] 第 \(attempt) 次重试（等 \(delaySec)s）...")
                    try await Task.sleep(nanoseconds: delaySec * 1_000_000_000)
                }

                MixLog.info("开始下载 Whisper 模型: \(modelName)（\(source) · attempt \(attempt + 1)/3）")

                do {
                    try await downloadOneAttempt(
                        url: url,
                        partialPath: partialPath,
                        session: session,
                        onProgress: onProgress
                    )

                    // 成功：move partial → dest
                    if FileManager.default.fileExists(atPath: destPath) {
                        try FileManager.default.removeItem(atPath: destPath)
                    }
                    try FileManager.default.moveItem(atPath: partialPath, toPath: destPath)
                    MixLog.info("Whisper 模型下载完成: \(modelName)")
                    return destPath
                } catch is CancellationError {
                    MixLog.info("Whisper 模型下载被用户取消")
                    throw CancellationError()
                } catch {
                    lastError = error
                    MixLog.error("[\(source) attempt \(attempt + 1)] 下载失败: \(error.localizedDescription)")
                    // 不删除 partial：下次（即使切换源）也能续传
                }
            }
        }

        throw lastError ?? ASRError.modelNotFound
    }

    /// 单次下载尝试（支持 Range 续传，流式写入 partial 文件，250ms 回调一次进度）
    private func downloadOneAttempt(
        url: URL,
        partialPath: String,
        session: URLSession,
        onProgress: (@Sendable (DownloadProgress) -> Void)?
    ) async throws {
        let fm = FileManager.default
        let existingSize: Int64 = ((try? fm.attributesOfItem(atPath: partialPath))?[.size] as? NSNumber)?.int64Value ?? 0

        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        if existingSize > 0 {
            req.setValue("bytes=\(existingSize)-", forHTTPHeaderField: "Range")
            MixLog.info("Range 续传: 已下载 \(existingSize) bytes")
        }

        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        // 416 Range Not Satisfiable：通常意味着 partial 已经下完了
        if http.statusCode == 416, existingSize > 0 {
            MixLog.info("服务器返回 416，假定 partial 文件已完整")
            return
        }
        guard (200...299).contains(http.statusCode) else {
            throw URLError(URLError.Code(rawValue: http.statusCode))
        }

        // 服务器是否真的接受了 Range（206 Partial Content）
        let appendMode = (http.statusCode == 206 && existingSize > 0)
        if !appendMode && existingSize > 0 {
            // 服务器不支持 Range 或忽略了 Range，丢弃旧 partial 重新下
            MixLog.info("服务器未支持 Range（status=\(http.statusCode)），从头开始")
            try? fm.removeItem(atPath: partialPath)
        }

        // total = existing + remaining，Content-Range 优先
        let remaining = http.expectedContentLength
        let total: Int64 = {
            if let cr = http.value(forHTTPHeaderField: "Content-Range"),
               let slashPart = cr.split(separator: "/").last,
               let n = Int64(slashPart) {
                return n
            }
            if remaining > 0 { return (appendMode ? existingSize : 0) + remaining }
            return 0
        }()

        if !fm.fileExists(atPath: partialPath) {
            fm.createFile(atPath: partialPath, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: partialPath))
        if appendMode {
            try handle.seekToEnd()
        } else {
            try handle.truncate(atOffset: 0)
        }
        defer { try? handle.close() }

        var written: Int64 = appendMode ? existingSize : 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var lastReportTime = Date()
        var lastReportBytes = written
        // 立即报一次起始进度
        onProgress?(DownloadProgress(receivedBytes: written, totalBytes: total, bytesPerSecond: 0))

        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                let now = Date()
                let elapsed = now.timeIntervalSince(lastReportTime)
                if elapsed >= 0.25 {
                    let bps = Double(written - lastReportBytes) / elapsed
                    onProgress?(DownloadProgress(receivedBytes: written, totalBytes: total, bytesPerSecond: bps))
                    lastReportTime = now
                    lastReportBytes = written
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        onProgress?(DownloadProgress(receivedBytes: written, totalBytes: max(total, written), bytesPerSecond: 0))
    }

    /// 检查模型是否可用
    nonisolated func isModelAvailable() -> Bool {
        findWhisperCppModel() != nil
    }

    /// ASR 错误类型
    enum ASRError: LocalizedError {
        case modelNotFound
        case whisperNotFound

        var errorDescription: String? {
            switch self {
            case .modelNotFound:
                return "Whisper 模型文件未找到，请在设置中下载模型"
            case .whisperNotFound:
                return "语音识别组件未找到，请重新安装应用或安装 whisper-cpp (brew install whisper-cpp)"
            }
        }
    }
}
