import Foundation

/// AI 提供商通用错误
enum AIProviderError: LocalizedError {
    case apiKeyNotConfigured(AIProviderType)
    case requestFailed(String)
    case invalidResponse(String)
    case rateLimited
    case jsonParsingFailed(String)

    var errorDescription: String? {
        switch self {
        case .apiKeyNotConfigured(let provider):
            return "\(provider.displayName) API Key 未配置，请在设置中添加"
        case .requestFailed(let msg):
            return "AI 服务连接失败，请检查网络后重试。(\(msg))"
        case .invalidResponse(let msg):
            return "AI 返回了无法识别的内容，请重试。(\(msg))"
        case .rateLimited:
            return "AI 请求过于频繁，请等待 1 分钟后重试"
        case .jsonParsingFailed(let msg):
            return "AI 返回的数据格式异常，请重试。(\(msg))"
        }
    }
}

/// AI 提供商协议
protocol AIProvider: Actor {
    func generateJSON<T: Decodable>(prompt: String, responseType: T.Type) async throws -> T
    func generateText(prompt: String) async throws -> String
}

/// 支持的 AI 提供商
enum AIProviderType: String, CaseIterable, Identifiable, Codable {
    case qwen = "qwen"
    case minimax = "minimax"
    case claude = "claude"
    case claudeRelay = "claude_relay"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .qwen: return "千问"
        case .minimax: return "MiniMax"
        case .claude: return "Claude"
        case .claudeRelay: return "Claude (国内转发)"
        }
    }

    var models: [String] {
        switch self {
        case .qwen:
            return ["qwen-max-latest", "qwen-plus-latest", "qwen-turbo-latest"]
        case .minimax:
            return ["MiniMax-M2.5", "MiniMax-M1-80k", "MiniMax-Text-01", "abab6.5s-chat"]
        case .claude:
            return ["claude-sonnet-4-20250514", "claude-haiku-4-20250414"]
        case .claudeRelay:
            return ["claude-sonnet-4-6", "claude-sonnet-4-5-20250929", "claude-haiku-4-5-20251001", "claude-opus-4-6"]
        }
    }

    var defaultModel: String {
        switch self {
        case .qwen: return "qwen-max-latest"
        case .minimax: return "MiniMax-M2.5"
        case .claude: return "claude-sonnet-4-20250514"
        case .claudeRelay: return "claude-sonnet-4-6"
        }
    }

    /// 是否使用 Claude 原生 API（非 OpenAI 兼容格式）
    var isClaudeNative: Bool {
        self == .claude
    }

    /// 模型显示名称
    func modelDisplayName(_ model: String) -> String {
        switch self {
        case .qwen:
            switch model {
            case "qwen-max-latest": return "Qwen Max (最新)"
            case "qwen-plus-latest": return "Qwen Plus (最新)"
            case "qwen-turbo-latest": return "Qwen Turbo (最新)"
            default: return model
            }
        case .minimax:
            switch model {
            case "MiniMax-M2.5": return "MiniMax M2.5 (最新)"
            case "MiniMax-M1-80k": return "MiniMax M1 80K"
            case "MiniMax-Text-01": return "MiniMax Text 01"
            case "abab6.5s-chat": return "abab 6.5s Chat"
            default: return model
            }
        case .claude:
            switch model {
            case "claude-sonnet-4-20250514": return "Claude Sonnet 4"
            case "claude-haiku-4-20250414": return "Claude Haiku 4"
            default: return model
            }
        case .claudeRelay:
            switch model {
            case "claude-sonnet-4-6": return "Claude Sonnet 4.6"
            case "claude-sonnet-4-5-20250929": return "Claude Sonnet 4.5"
            case "claude-haiku-4-5-20251001": return "Claude Haiku 4.5"
            case "claude-opus-4-6": return "Claude Opus 4.6"
            default: return model
            }
        }
    }
}
