import Foundation

/// 千问 DashScope qwen3-tts-flash 文本转语音客户端（真实 HTTP）。
/// 复用现有千问 DashScope key（与文本同一把）。
actor QwenTTSClient: TTSClient {
    private static let endpoint = URL(string: "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")!
    private static let model = "qwen3-tts-flash"

    private let apiKeyProvider: @Sendable () -> String?

    init(apiKeyProvider: @escaping @Sendable () -> String? = { KeychainHelper.getAPIKey(for: .qwen) }) {
        self.apiKeyProvider = apiKeyProvider
    }

    func synthesize(text: String, voiceId: String, languageType: String = "Chinese") async throws -> TTSResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TTSError.emptyText }
        guard let key = apiKeyProvider(), !key.isEmpty else { throw TTSError.missingAPIKey }

        // 1) 请求合成
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": Self.model,
            "input": ["text": trimmed, "voice": voiceId, "language_type": languageType]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            throw TTSError.badResponse("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1): \(snippet)")
        }
        let decoded = try JSONDecoder().decode(QwenTTSResponse.self, from: data)
        guard let urlStr = decoded.output?.audio?.url, let audioURL = URL(string: urlStr) else {
            throw TTSError.noAudioURL
        }

        // 2) 下载 wav 到临时目录
        let (tmpFile, _) = try await URLSession.shared.download(from: audioURL)
        let dest = FileHelper.tempDirectory.appendingPathComponent("tts-\(UUID().uuidString).wav")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmpFile, to: dest)

        // 3) 探测时长
        let probe = FFmpegRunner()
        let out = try await probe.runProbe(arguments: [
            "-v", "error", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", dest.path
        ])
        let duration = Double(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        return TTSResult(wavPath: dest.path, rawDuration: duration)
    }
}
