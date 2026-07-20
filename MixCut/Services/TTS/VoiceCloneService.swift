import Foundation

/// 用 DashScope qwen 声音克隆：拿一段参考音频(mp3) 注册出一个克隆音色 voice_id。
/// 合成时用 QwenTTSClient(model: VoiceCloneService.targetModel) + 该 voice_id。
actor VoiceCloneService {
    enum CloneError: Error, LocalizedError {
        case missingAPIKey
        case badResponse(String)
        case noVoiceId

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "尚未配置千问 API Key，请到「设置」里填写后重试"
            case .badResponse(let d): return "声音克隆失败：\(d)"
            case .noVoiceId: return "声音克隆未返回音色 ID"
            }
        }
    }

    /// 克隆音色绑定的合成模型；注册与合成必须用同一个。
    static let targetModel = "qwen3-tts-vc-2026-01-22"
    private static let endpoint = URL(string: "https://dashscope.aliyuncs.com/api/v1/services/audio/tts/customization")!

    private let apiKeyProvider: @Sendable () -> String?

    init(apiKeyProvider: @escaping @Sendable () -> String? = { KeychainHelper.getAPIKey(for: .qwen) }) {
        self.apiKeyProvider = apiKeyProvider
    }

    /// 用参考音频注册克隆音色，返回 voice_id。
    func enroll(referenceAudioPath: String, preferredName: String) async throws -> String {
        guard let key = apiKeyProvider(), !key.isEmpty else { throw CloneError.missingAPIKey }
        // 同 Wan25：映射只覆盖 base64 编码，不跨越后面的网络请求（避免文件被清理时 SIGBUS）
        let b64: String = try {
            let data = try Data(contentsOf: URL(fileURLWithPath: referenceAudioPath), options: .mappedIfSafe)
            MixLog.info("[VoiceClone] 参考音频 \(data.count / 1024) KB")
            return data.base64EncodedString()
        }()

        let body: [String: Any] = [
            "model": "qwen-voice-enrollment",
            "input": [
                "action": "create",
                "target_model": Self.targetModel,
                "preferred_name": Self.sanitizedName(preferredName),
                "audio": ["data": "data:audio/mpeg;base64,\(b64)"]
            ]
        ]

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let snippet = String(data: respData, encoding: .utf8)?.prefix(300) ?? ""
            throw CloneError.badResponse("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1): \(snippet)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let output = obj["output"] as? [String: Any],
              let voice = output["voice"] as? String, !voice.isEmpty else {
            throw CloneError.noVoiceId
        }
        return voice
    }

    /// preferred_name 仅允许小写字母/数字，长度受限；做个稳妥清洗。
    private static func sanitizedName(_ raw: String) -> String {
        let lowered = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        let trimmed = String(lowered.prefix(20))
        return trimmed.isEmpty ? "mixcut" : trimmed
    }
}
