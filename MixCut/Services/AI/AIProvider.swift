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
        // 免费额度耗尽 / 需开通付费（DashScope 对付费档模型如 qwen-plus 返回 HTTP 403，
        // message 为 "free quota has been exhausted ... complete your payment information
        // (or disable the \"use free tier only\" mode)"）。
        // 必须放在下面通用 403 分支之前，否则会被误判成「未开通模型权限」，误导用户去开克隆权限。
        if l.contains("free quota") || l.contains("free tier")
            || l.contains("payment information")
            || (l.contains("quota") && l.contains("exhausted")) {
            return "所选模型的免费额度已用完：请到阿里云百炼（DashScope）控制台完成付费开通（或关闭「仅用免费额度 / use free tier only」模式），也可先换用仍有额度的模型（如 qwen-flash / qwen-turbo）后重试。此错误与声音克隆权限无关。"
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
        // 上下文超长（素材太多，一次塞给模型的内容超过窗口）
        if l.contains("context length") || l.contains("context_length")
            || l.contains("maximum context") || l.contains("too many tokens")
            || l.contains("input is too long") || l.contains("prompt is too long") {
            return "本次要分析的内容超出了模型的长度上限。请分批处理（例如一次少导入几个视频），或到「设置」换一个上下文更长的模型。"
        }
        // 内容审核拦截
        if l.contains("content filter") || l.contains("content_filter")
            || l.contains("data_inspection_failed") || l.contains("risk control")
            || l.contains("sensitive") {
            return "内容被服务商的安全审核拦截。通常是素材台词里有被判定为敏感的词。可尝试修改台词后重试，或换一个提供商。"
        }
        // 模型名不存在 / 接口路径不对（自定义与转发网关最常见的配置错误）
        if l.contains("model not found") || l.contains("model_not_found")
            || l.contains("invalid model") || l.contains("unknown model")
            || l.contains("does not exist") || l.contains("http 404") {
            return "接口找不到所选模型。请到「设置」核对模型名称是否正确；若用的是「自定义」或「国内转发网关」，还要确认接口地址填的是根地址（通常以 /v1 结尾，不要带 /chat/completions）。"
        }
        // 请求格式被拒（多为模型名/参数与该平台不匹配）
        if l.contains("http 400") || l.contains("invalid_request") || l.contains("bad request") {
            return "服务商拒绝了这次请求，通常是模型名称或接口地址与该平台不匹配。请到「设置」检查提供商、模型名和接口地址是否配套。"
        }
        // 服务端故障 —— 这不是用户的问题，别让他去查网络
        if l.contains("http 500") || l.contains("http 502") || l.contains("http 503")
            || l.contains("http 504") || l.contains("internal server error")
            || l.contains("bad gateway") || l.contains("service unavailable") {
            return "AI 服务商当前故障或正在维护（服务端错误），这不是你的配置问题。请过几分钟重试；若持续如此，可到「设置」临时换一个提供商。"
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

    /// 该模型是否支持「深度思考」参数开关。
    /// 只对能通过请求参数显式开/关思考的组合返回 true：
    /// - 千问：DashScope 商业版 qwen3-max / qwen-plus / qwen-flash / qwen-turbo 支持 enable_thinking（非流式可用）；
    ///   qwen-max-latest（旧架构）与 coder 系不支持
    /// - Claude 原生：4 系及以上全系支持 extended thinking
    /// - MiniMax / DeepSeek：思考由模型本身决定，无参数可切换；转发网关/自定义后端参数透传不可靠，均不提供开关
    func supportsThinkingToggle(model: String) -> Bool {
        switch self {
        case .qwen:
            return ["qwen3-max", "qwen-plus-latest", "qwen-flash", "qwen-turbo-latest"].contains(model)
        case .claude:
            return true
        case .minimax, .deepseek, .claudeRelay, .custom:
            return false
        }
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

/// 全应用统一的「人话错误」翻译层。
///
/// 设计原则：任何给用户看的错误都要能回答三个问题 ——
/// **发生了什么 / 为什么 / 我该怎么办**。只说「失败」等于没说。
///
/// 分层：
/// - 这里负责**本地**错误：取消、网络、文件系统、解码、外部工具（ffmpeg/whisper/demucs）
/// - 第三方 API 的错误码交给 `APIErrorClassifier`（欠费 / Key 无效 / 限流 / 未开通模型…）
/// - 两边都认不出来时，保留原文（截断），至少让用户能把原文发给我们排查
enum FriendlyError {

    /// 把任意 Error 翻成用户能看懂、能据此行动的中文说明。
    /// - Parameter context: 可选的场景前缀，例如 "AI 语义分析"、"导出"。给出后输出形如「导出失败：…」。
    static func describe(_ error: Error, context: String? = nil) -> String {
        let body = reason(for: error)
        guard let context, !context.isEmpty else { return body }
        return "\(context)失败：\(body)"
    }

    /// 只取原因部分（不带场景前缀）。
    static func reason(for error: Error) -> String {
        // 用户主动取消：不是错误，不该报红
        if error is CancellationError { return "操作已取消。" }

        if let urlError = error as? URLError, let hint = describeURLError(urlError) {
            return hint
        }
        if let hint = describeFileError(error) {
            return hint
        }
        if let decodingError = error as? DecodingError {
            return describeDecodingError(decodingError)
        }
        // 落到第三方 API 错误码识别 + 原文兜底
        return APIErrorClassifier.friendly(error)
    }

    // MARK: - 网络

    /// URLError 有精确的 code，比匹配 localizedDescription 文本可靠得多
    /// （后者会随系统语言变化，中文系统下英文关键词全都匹配不上）。
    private static func describeURLError(_ error: URLError) -> String? {
        switch error.code {
        case .notConnectedToInternet:
            return "设备当前没有网络连接。请检查 Wi-Fi 或网线后重试。"
        case .timedOut:
            return "连接服务器超时。可能是网络不稳定，或所选 AI 服务在国内访问受限——可稍后重试，或在「设置」里换一个国内可直连的提供商（如千问 / MiniMax / DeepSeek）。"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "无法连接到服务器地址。请检查网络；若用的是「自定义」或「国内转发网关」提供商，请到「设置」核对接口地址是否填写正确。"
        case .networkConnectionLost:
            return "网络连接中途断开。请检查网络后重试。"
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return "安全连接建立失败（证书校验未通过）。若处于公司网络或使用了代理/抓包工具，请先关闭后重试。"
        case .userAuthenticationRequired:
            return "服务器要求身份验证。请到「设置」检查 API Key 是否正确。"
        case .badURL, .unsupportedURL:
            return "接口地址格式不合法。请到「设置」检查自定义接口地址（需以 https:// 开头）。"
        default:
            return nil
        }
    }

    // MARK: - 文件系统

    /// 磁盘满 / 没权限 / 文件不存在，是导出与素材处理里最常见的三类失败，
    /// 但系统给的原文往往是英文且不说该怎么办。
    private static func describeFileError(_ error: Error) -> String? {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain || nsError.domain == NSPOSIXErrorDomain else {
            return nil
        }

        // 磁盘空间不足
        if nsError.code == NSFileWriteOutOfSpaceError
            || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC)) {
            return "磁盘空间不足，无法写入文件。请清理磁盘后重试（视频导出通常需要数百 MB 到数 GB 空间）。"
        }
        // 无写入权限
        if nsError.code == NSFileWriteNoPermissionError
            || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EACCES)) {
            return "没有写入该位置的权限。请换一个目录（例如「桌面」或「下载」），或在「系统设置 → 隐私与安全性 → 文件与文件夹」里授予 MixCut 访问权限。"
        }
        // 只读卷
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EROFS) {
            return "目标磁盘是只读的，无法写入。请换一个可写的目录。"
        }
        // 文件/目录不存在
        if nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError
            || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT)) {
            return "找不到需要的文件，它可能已被移动、重命名或删除。请重新导入素材后重试。"
        }
        // 读权限
        if nsError.code == NSFileReadNoPermissionError {
            return "没有读取该文件的权限。请确认文件未被加密或锁定，必要时把它复制到「下载」目录后重新导入。"
        }
        return nil
    }

    // MARK: - 解码

    /// AI 返回的 JSON 结构对不上时，明确指出是哪个字段出了问题，便于我们排查，
    /// 也让用户知道这是「AI 返回内容异常」而不是他自己操作错了。
    private static func describeDecodingError(_ error: DecodingError) -> String {
        let detail: String
        switch error {
        case .keyNotFound(let key, _):
            detail = "缺少字段「\(key.stringValue)」"
        case .typeMismatch(let type, let context):
            detail = "字段「\(path(of: context))」类型不符（期望 \(type)）"
        case .valueNotFound(let type, let context):
            detail = "字段「\(path(of: context))」缺少值（期望 \(type)）"
        case .dataCorrupted(let context):
            detail = context.debugDescription
        @unknown default:
            detail = "结构不符合预期"
        }
        return "AI 返回的内容格式异常（\(detail)），这通常是模型偶发的输出抖动。请重试一次；若反复出现，可到「设置」换一个模型。"
    }

    private static func path(of context: DecodingError.Context) -> String {
        let keys = context.codingPath.map(\.stringValue)
        return keys.isEmpty ? "根" : keys.joined(separator: ".")
    }
}
