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
            // 先尝试识别确切原因（欠费/无效 Key/未开通模型/限流），识别不出才退回「网络」兜底——
            // 否则会把欠费、无效 Key 等都误报成「请检查网络」，误导排查方向。
            if let hint = APIErrorClassifier.hint(msg) {
                return "\(hint)（接口返回：\(msg.prefix(200)))"
            }
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

/// 把第三方 API（DashScope/千问等 OpenAI 兼容、TTS）返回的原始错误文本，识别成用户能看懂的中文原因。
/// AI 改写与 TTS 配音共用一套，避免各处重复翻译。识别不出返回 nil，由调用方兜底（保留原文）。
enum APIErrorClassifier {

    /// 识别原始错误文本的友好中文原因；无法识别返回 nil。
    static func hint(_ raw: String) -> String? {
        let l = raw.lowercased()

        // 欠费 / 余额不足（阿里云 Arrearage）—— 与网络无关，必须单独识别
        if l.contains("arrearage") || l.contains("overdue") || l.contains("欠费")
            || l.contains("good standing") {
            return "账户已欠费或余额不足：请到阿里云百炼（DashScope）控制台充值/检查额度后重试。"
        }
        // 克隆音色失效（多因更换 API Key，旧克隆音色绑定原账户）
        if l.contains("tts speak request failed")
            || (l.contains("invalidparameter") && l.contains("voice")) {
            return "克隆音色在当前 API Key 下不可用——通常是更换了千问 API Key（克隆音色绑定原账户）。请重新「一键改写」自动用当前 Key 重克隆原声；若仍失败，请确认该 Key 已开通 qwen3-tts-vc 声音克隆。"
        }
        // API Key 无效 / 未授权
        if l.contains("invalidapikey") || l.contains("invalid api key")
            || l.contains("invalid_api_key") || l.contains("incorrect api key")
            || l.contains("unauthorized") || l.contains("http 401") {
            return "API Key 无效或未授权：请到「设置」检查 API Key 是否填写正确、是否已开通对应服务（DashScope/百炼）。"
        }
        // 模型未开通 / 无权限
        if l.contains("accessdenied") || l.contains("model.access")
            || l.contains("http 403") || (l.contains("model") && l.contains("denied")) {
            return "该 API Key 未开通所需模型权限，请在控制台开通对应模型后重试（声音克隆需 qwen-voice-enrollment 与 qwen3-tts-vc）。"
        }
        // 限流
        if l.contains("throttl") || l.contains("ratelimit") || l.contains("rate limit")
            || l.contains("requests rate") || l.contains("http 429") {
            return "请求过于频繁（限流），请稍后再试。"
        }
        // 真正的网络问题
        if l.contains("timed out") || l.contains("timeout") || l.contains("offline")
            || l.contains("network connection") || l.contains("could not connect")
            || l.contains("connection lost") || l.contains("not connect to the internet") {
            return "网络异常或超时，请检查网络后重试。"
        }
        return nil
    }

    /// 带兜底：识别不出时返回原文（截断）。
    static func friendly(_ error: Error, maxRawLen: Int = 200) -> String {
        let raw = error.localizedDescription
        if let hint = hint(raw) {
            return "\(hint)\n（接口返回：\(raw.prefix(maxRawLen)))"
        }
        return raw
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
    case deepseek = "deepseek"
    case claude = "claude"
    /// 国内转发网关（要求 OpenAI 兼容协议，下面再选具体平台 Claude / Gemini / OpenAI）
    /// rawValue 保留为 `claude_relay` 以兼容历史用户配置
    case claudeRelay = "claude_relay"
    case custom = "custom"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .qwen: return "千问"
        case .minimax: return "MiniMax"
        case .deepseek: return "DeepSeek"
        case .claude: return "Claude"
        case .claudeRelay: return "国内转发网关"
        case .custom: return "自定义"
        }
    }

    var models: [String] {
        switch self {
        case .qwen:
            // 阿里云通义千问 — DashScope OpenAI 兼容接口
            return [
                "qwen3-max",
                "qwen-max-latest",
                "qwen3-coder-plus",
                "qwen-plus-latest",
                "qwen-flash",
                "qwen-turbo-latest",
            ]
        case .minimax:
            return [
                "MiniMax-M2.7",
                "MiniMax-M2.5",
                "MiniMax-M2.1",
                "MiniMax-M2.7-highspeed",
                "MiniMax-M2.5-highspeed",
            ]
        case .deepseek:
            return [
                "deepseek-v4-pro",
                "deepseek-v4-flash",
                "deepseek-chat",
                "deepseek-reasoner",
            ]
        case .claude:
            return [
                "claude-opus-4-7",
                "claude-sonnet-4-6",
                "claude-haiku-4-5-20251001",
                "claude-opus-4-6",
                "claude-sonnet-4-5-20250929",
            ]
        case .claudeRelay:
            // 国内转发网关：模型列表取决于二级选择的平台
            return KeychainHelper.relayPlatform.models
        case .custom:
            let name = KeychainHelper.customModelName
            return name.isEmpty ? ["custom-model"] : [name]
        }
    }

    var defaultModel: String {
        switch self {
        case .qwen: return "qwen-plus-latest"
        case .minimax: return "MiniMax-M2.5"
        case .deepseek: return "deepseek-v4-flash"
        case .claude: return "claude-sonnet-4-6"
        case .claudeRelay: return KeychainHelper.relayPlatform.defaultModel
        case .custom:
            let name = KeychainHelper.customModelName
            return name.isEmpty ? "custom-model" : name
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
            case "qwen3-max": return "Qwen3 Max (旗舰)"
            case "qwen-max-latest": return "Qwen Max (稳定旗舰)"
            case "qwen3-coder-plus": return "Qwen3 Coder Plus (代码强化)"
            case "qwen-plus-latest": return "Qwen Plus (主力 · 推荐)"
            case "qwen-flash": return "Qwen Flash (快/高性价比)"
            case "qwen-turbo-latest": return "Qwen Turbo (极速)"
            default: return model
            }
        case .minimax:
            switch model {
            case "MiniMax-M2.7": return "MiniMax M2.7 (最新旗舰)"
            case "MiniMax-M2.5": return "MiniMax M2.5 (稳定主力 · 推荐)"
            case "MiniMax-M2.1": return "MiniMax M2.1 (编程强化)"
            case "MiniMax-M2.7-highspeed": return "MiniMax M2.7 高速版"
            case "MiniMax-M2.5-highspeed": return "MiniMax M2.5 高速版"
            default: return model
            }
        case .deepseek:
            switch model {
            case "deepseek-v4-pro": return "DeepSeek V4 Pro (旗舰 · 1M ctx)"
            case "deepseek-v4-flash": return "DeepSeek V4 Flash (推荐 · 1M ctx)"
            case "deepseek-chat": return "DeepSeek Chat (兼容别名 · 2026-07 废弃)"
            case "deepseek-reasoner": return "DeepSeek Reasoner (兼容别名 · 2026-07 废弃)"
            default: return model
            }
        case .claude:
            switch model {
            case "claude-opus-4-7": return "Claude Opus 4.7 (最强)"
            case "claude-sonnet-4-6": return "Claude Sonnet 4.6 (推荐)"
            case "claude-haiku-4-5-20251001": return "Claude Haiku 4.5 (快速)"
            case "claude-opus-4-6": return "Claude Opus 4.6"
            case "claude-sonnet-4-5-20250929": return "Claude Sonnet 4.5"
            default: return model
            }
        case .claudeRelay:
            return KeychainHelper.relayPlatform.modelDisplayName(model)
        case .custom:
            return model
        }
    }
}

/// 国内转发网关支持的二级平台
/// 网关要求兼容 OpenAI 协议，model 名按各家平台规范填写
enum RelayPlatform: String, CaseIterable, Identifiable, Codable {
    case claude
    case gemini
    case openai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude (Anthropic)"
        case .gemini: return "Gemini (Google)"
        case .openai: return "OpenAI / GPT"
        }
    }

    var models: [String] {
        switch self {
        case .claude:
            return [
                "claude-opus-4-7",
                "claude-sonnet-4-6",
                "claude-haiku-4-5-20251001",
                "claude-opus-4-6",
                "claude-sonnet-4-5-20250929",
            ]
        case .gemini:
            return [
                "gemini-3.1-pro-preview",
                "gemini-2.5-pro",
                "gemini-3-flash-preview",
                "gemini-2.5-flash",
                "gemini-3.1-flash-lite",
            ]
        case .openai:
            return [
                "gpt-5.5",
                "gpt-5.4-mini",
                "gpt-5-mini",
                "o3",
                "gpt-5-nano",
                "gpt-4o",
            ]
        }
    }

    var defaultModel: String {
        switch self {
        case .claude: return "claude-sonnet-4-6"
        case .gemini: return "gemini-2.5-flash"
        case .openai: return "gpt-5.4-mini"
        }
    }

    func modelDisplayName(_ model: String) -> String {
        switch self {
        case .claude:
            switch model {
            case "claude-opus-4-7": return "Claude Opus 4.7 (最强)"
            case "claude-sonnet-4-6": return "Claude Sonnet 4.6 (推荐)"
            case "claude-haiku-4-5-20251001": return "Claude Haiku 4.5 (快速)"
            case "claude-opus-4-6": return "Claude Opus 4.6"
            case "claude-sonnet-4-5-20250929": return "Claude Sonnet 4.5"
            default: return model
            }
        case .gemini:
            switch model {
            case "gemini-3.1-pro-preview": return "Gemini 3.1 Pro (旗舰 · 预览)"
            case "gemini-2.5-pro": return "Gemini 2.5 Pro (稳定旗舰)"
            case "gemini-3-flash-preview": return "Gemini 3 Flash (新一代主力)"
            case "gemini-2.5-flash": return "Gemini 2.5 Flash (推荐)"
            case "gemini-3.1-flash-lite": return "Gemini 3.1 Flash Lite (快/廉价)"
            default: return model
            }
        case .openai:
            switch model {
            case "gpt-5.5": return "GPT-5.5 (旗舰)"
            case "gpt-5.4-mini": return "GPT-5.4 mini (推荐)"
            case "gpt-5-mini": return "GPT-5 mini"
            case "o3": return "o3 (深度推理)"
            case "gpt-5-nano": return "GPT-5 nano (快/廉价)"
            case "gpt-4o": return "GPT-4o (兼容)"
            default: return model
            }
        }
    }
}
