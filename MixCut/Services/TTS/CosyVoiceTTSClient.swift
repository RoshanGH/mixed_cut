import Foundation

/// DashScope cosyvoice-v2 文本转语音客户端（WebSocket duplex 流式）。
/// 复用千问 DashScope key（与文本/qwen 同一把）。原生支持 `rate` 语速。
actor CosyVoiceTTSClient: TTSClient {
    private static let endpoint = URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference/")!
    private let model = CosyVoiceCatalog.model
    private static let sampleRate = 24000
    private static let overallTimeout: TimeInterval = 45
    /// rate 合法区间（基准 1.0）
    private static let rateMin = 0.5
    private static let rateMax = 2.0

    private let apiKeyProvider: @Sendable () -> String?

    init(apiKeyProvider: @escaping @Sendable () -> String? = { KeychainHelper.getAPIKey(for: .qwen) }) {
        self.apiKeyProvider = apiKeyProvider
    }

    func synthesize(text: String, voiceId: String, languageType: String = "Chinese", rate: Double = 1.0) async throws -> TTSResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TTSError.emptyText }
        guard let key = apiKeyProvider(), !key.isEmpty else { throw TTSError.missingAPIKey }

        let clampedRate = min(max(rate, Self.rateMin), Self.rateMax)
        let taskId = UUID().uuidString

        var request = URLRequest(url: Self.endpoint)
        request.setValue("bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-DataInspection")

        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: request)
        ws.resume()
        defer {
            ws.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        // 1) run-task：开启合成会话
        try await ws.send(.string(Self.runTaskJSON(taskId: taskId, model: model, voice: voiceId, rate: clampedRate)))

        var audio = Data()
        var started = false
        let deadline = Date().addingTimeInterval(Self.overallTimeout)

        loop: while true {
            if Date() > deadline { throw TTSError.badResponse("CosyVoice 合成超时（\(Int(Self.overallTimeout))s）") }
            let message = try await ws.receive()
            switch message {
            case .data(let chunk):
                audio.append(chunk)               // 二进制音频帧
            case .string(let json):
                switch Self.parseEvent(json) {
                case "task-started":
                    // 协议要求收到 task-started 后再发文本，然后立即收尾（整段一次性合成）
                    if !started {
                        started = true
                        try await ws.send(.string(Self.continueTaskJSON(taskId: taskId, text: trimmed)))
                        try await ws.send(.string(Self.finishTaskJSON(taskId: taskId)))
                    }
                case "task-finished":
                    break loop
                case "task-failed":
                    throw TTSError.badResponse("CosyVoice 返回错误：\(json.prefix(300))")
                default:
                    break // result-generated 等中间事件忽略
                }
            @unknown default:
                break
            }
        }

        guard !audio.isEmpty else { throw TTSError.noAudioURL }

        // 拼好的 mp3 写本地 → ffprobe 测时长（ffmpeg 自动识别格式，后续 finalizer 转 m4a）
        let dest = FileHelper.tempDirectory.appendingPathComponent("cosyvoice-\(UUID().uuidString).mp3")
        try? FileManager.default.removeItem(at: dest)
        try audio.write(to: dest)

        let probe = FFmpegRunner()
        let out = try await probe.runProbe(arguments: [
            "-v", "error", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", dest.path
        ])
        let duration = Double(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        return TTSResult(wavPath: dest.path, rawDuration: duration)
    }

    // MARK: - 协议消息构建（用 JSONSerialization 避免台词内引号转义问题）

    private static func runTaskJSON(taskId: String, model: String, voice: String, rate: Double) -> String {
        jsonString([
            "header": ["action": "run-task", "task_id": taskId, "streaming": "duplex"],
            "payload": [
                "task_group": "audio", "task": "tts", "function": "SpeechSynthesizer",
                "model": model,
                "parameters": [
                    "text_type": "PlainText", "voice": voice,
                    "format": "mp3", "sample_rate": sampleRate, "rate": rate
                ],
                "input": [String: Any]()
            ]
        ])
    }

    private static func continueTaskJSON(taskId: String, text: String) -> String {
        jsonString([
            "header": ["action": "continue-task", "task_id": taskId, "streaming": "duplex"],
            "payload": ["input": ["text": text]]
        ])
    }

    private static func finishTaskJSON(taskId: String) -> String {
        jsonString([
            "header": ["action": "finish-task", "task_id": taskId, "streaming": "duplex"],
            "payload": ["input": [String: Any]()]
        ])
    }

    /// 解析服务端事件名（header.event）；解析失败返回空串。
    private static func parseEvent(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = obj["header"] as? [String: Any],
              let event = header["event"] as? String else { return "" }
        return event
    }

    private static func jsonString(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}
