import Foundation

/// TTS 合成结果：本地 wav 文件路径 + 原始时长（秒，由 ffprobe 探得）。
struct TTSResult: Sendable {
    let wavPath: String
    let rawDuration: Double
}

/// 文本转语音客户端协议（千问/MiniMax 各自实现，与 AIProvider 平行）。
protocol TTSClient: Sendable {
    /// - Returns: 下载到本地的 wav + 其时长；调用方负责后续对齐/转码/清理。
    func synthesize(text: String, voiceId: String, languageType: String) async throws -> TTSResult
}

/// 千问 DashScope TTS 响应（非流式：output.audio.url 指向 .wav）。
struct QwenTTSResponse: Decodable {
    struct Output: Decodable {
        struct Audio: Decodable { let url: String? }
        let audio: Audio?
    }
    let output: Output?
}

enum TTSError: Error, Equatable {
    case emptyText
    case noAudioURL
    case badResponse(String)
    case missingAPIKey
}
