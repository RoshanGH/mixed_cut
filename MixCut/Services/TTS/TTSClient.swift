import Foundation

/// TTS 合成结果：本地 wav 文件路径 + 原始时长（秒，由 ffprobe 探得）。
struct TTSResult: Sendable {
    let wavPath: String
    let rawDuration: Double
}

/// 文本转语音客户端协议（千问/CosyVoice 各自实现，与 AIProvider 平行）。
protocol TTSClient: Sendable {
    /// - Parameter rate: 语速（基准 1.0；CosyVoice 原生支持，qwen 实现忽略）。
    /// - Returns: 下载到本地的音频文件 + 其时长；调用方负责后续对齐/转码/清理。
    func synthesize(text: String, voiceId: String, languageType: String, rate: Double) async throws -> TTSResult
}

/// 千问 DashScope TTS 响应（非流式：output.audio.url 指向 .wav）。
struct QwenTTSResponse: Decodable {
    struct Output: Decodable {
        struct Audio: Decodable { let url: String? }
        let audio: Audio?
    }
    let output: Output?
}

enum TTSError: Error, Equatable, LocalizedError {
    case emptyText
    case noAudioURL
    case badResponse(String)
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "台词为空，无法合成语音"
        case .noAudioURL:
            return "TTS 服务返回结果异常（没有音频地址），请稍后重试"
        case .badResponse(let detail):
            return "TTS 服务返回错误：\(detail)"
        case .missingAPIKey:
            return "尚未配置千问 API Key，请到「设置」里填写千问 Key（配音与文本改写共用同一把）后重试"
        }
    }
}
