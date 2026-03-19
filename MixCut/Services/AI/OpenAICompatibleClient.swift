import Foundation

/// 简单文件日志
enum MixLog {
    private static let logPath: String = {
        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("com.mixcut.app/logs")
            try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            return fallback.appendingPathComponent("mixcut.log").path
        }
        let dir = cacheDir.appendingPathComponent("com.mixcut.app/logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mixcut.log").path
    }()

    static func info(_ msg: String) {
        write("ℹ️", msg)
    }

    static func error(_ msg: String) {
        write("❌", msg)
    }

    private static func write(_ level: String, _ msg: String) {
        let line = "[\(Date())] \(level) \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logPath) {
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: logPath, contents: data)
        }
    }
}

/// OpenAI 兼容 API 客户端（支持千问、MiniMax 等）
actor OpenAICompatibleClient: AIProvider {

    private var providerType: AIProviderType
    private var baseURL: String
    private var apiKey: String
    private var modelName: String
    private var maxRetries = 3
    private var baseRetryDelay: UInt64 = 2_000_000_000 // 2秒
    private var requestTimeout: TimeInterval = 300 // 5分钟（批量组合生成需要较长时间）

    init(providerType: AIProviderType, apiKey: String, modelName: String? = nil) {
        self.providerType = providerType
        self.apiKey = apiKey
        self.modelName = modelName ?? providerType.defaultModel
        self.baseURL = Self.resolveBaseURL(for: providerType)
    }

    private static func resolveBaseURL(for provider: AIProviderType) -> String {
        switch provider {
        case .qwen:
            return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .minimax:
            return "https://api.minimax.chat/v1"
        case .claude:
            return "https://api.anthropic.com/v1"
        case .claudeRelay:
            return "https://apicn.unifyllm.top/v1"
        case .custom:
            let url = KeychainHelper.customBaseURL
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return url.isEmpty ? "https://api.openai.com/v1" : url
        }
    }

    func generateJSON<T: Decodable>(prompt: String, responseType: T.Type) async throws -> T {
        let text = try await sendRequest(prompt: prompt)
        let jsonStr = extractJSON(from: text)

        guard let jsonData = jsonStr.data(using: .utf8) else {
            MixLog.error("JSON 编码失败, text: \(jsonStr.prefix(200))")
            throw AIProviderError.jsonParsingFailed("无法编码为 UTF-8")
        }

        do {
            return try JSONDecoder().decode(T.self, from: jsonData)
        } catch let decodingError as DecodingError {
            let detail: String
            switch decodingError {
            case .keyNotFound(let key, _):
                detail = "缺少字段: \(key.stringValue)"
            case .typeMismatch(let type, let context):
                detail = "字段类型错误: \(context.codingPath.map(\.stringValue).joined(separator: "."))，期望 \(type)"
            case .valueNotFound(_, let context):
                detail = "字段值为空: \(context.codingPath.map(\.stringValue).joined(separator: "."))"
            case .dataCorrupted(let context):
                detail = "数据损坏: \(context.debugDescription)"
            @unknown default:
                detail = "\(decodingError)"
            }
            MixLog.error("JSON 解析失败: \(detail)")
            MixLog.error("原始 JSON 前500字符: \(jsonStr.prefix(500))")
            throw AIProviderError.jsonParsingFailed(detail)
        } catch {
            MixLog.error("JSON 解析失败: \(error)")
            MixLog.error("原始 JSON 前500字符: \(jsonStr.prefix(500))")
            throw AIProviderError.jsonParsingFailed("\(error)")
        }
    }

    func generateText(prompt: String) async throws -> String {
        try await sendRequest(prompt: prompt)
    }

    // MARK: - 内部实现

    private func sendRequest(prompt: String) async throws -> String {
        guard !apiKey.isEmpty else {
            MixLog.error("API Key 为空！provider=\(self.providerType.displayName)")
            throw AIProviderError.apiKeyNotConfigured(providerType)
        }

        MixLog.info("发送请求: provider=\(self.providerType.displayName), model=\(self.modelName), prompt长度=\(prompt.count)")

        var lastError: Error?

        for attempt in 0..<maxRetries {
            do {
                if attempt > 0 {
                    let delay = baseRetryDelay * UInt64(1 << attempt)
                    try await Task.sleep(nanoseconds: delay)
                    MixLog.info("重试第 \(attempt) 次...")
                }

                let isClaudeAPI = providerType.isClaudeNative
                let url: URL
                var request: URLRequest

                if isClaudeAPI {
                    guard let u = URL(string: "\(baseURL)/messages") else {
                        throw AIProviderError.requestFailed("无效的 API 地址: \(baseURL)/messages")
                    }
                    url = u
                    request = URLRequest(url: url)
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                } else {
                    guard let u = URL(string: "\(baseURL)/chat/completions") else {
                        throw AIProviderError.requestFailed("无效的 API 地址: \(baseURL)/chat/completions")
                    }
                    url = u
                    request = URLRequest(url: url)
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }

                request.httpMethod = "POST"
                request.timeoutInterval = requestTimeout
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                let body: [String: Any]
                if isClaudeAPI {
                    body = [
                        "model": modelName,
                        "max_tokens": 8192,
                        "messages": [
                            ["role": "user", "content": prompt]
                        ]
                    ]
                } else {
                    body = [
                        "model": modelName,
                        "messages": [
                            ["role": "user", "content": prompt]
                        ],
                        "temperature": 0.7
                    ]
                }
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw AIProviderError.requestFailed("无效的 HTTP 响应")
                }

                if httpResponse.statusCode == 429 {
                    lastError = AIProviderError.rateLimited
                    continue
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    let errorBody = String(data: data, encoding: .utf8) ?? ""
                    MixLog.error("HTTP \(httpResponse.statusCode): \(errorBody.prefix(500))")
                    throw AIProviderError.requestFailed("HTTP \(httpResponse.statusCode): \(String(errorBody.prefix(200)))")
                }

                let content: String

                if isClaudeAPI {
                    // 解析 Claude Messages API 响应
                    // 格式: {"content": [{"type": "text", "text": "..."}], ...}
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let contentArray = json["content"] as? [[String: Any]],
                          let firstBlock = contentArray.first,
                          let text = firstBlock["text"] as? String else {
                        let rawBody = String(data: data, encoding: .utf8) ?? "(empty)"
                        MixLog.error("无法解析 Claude 响应: \(rawBody.prefix(500))")
                        throw AIProviderError.invalidResponse("无法解析 Claude 响应")
                    }
                    content = text
                } else {
                    // 解析 OpenAI 兼容格式响应
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choices = json["choices"] as? [[String: Any]],
                          let firstChoice = choices.first,
                          let message = firstChoice["message"] as? [String: Any],
                          let text = message["content"] as? String else {
                        let rawBody = String(data: data, encoding: .utf8) ?? "(empty)"
                        MixLog.error("无法解析响应: \(rawBody.prefix(500))")
                        throw AIProviderError.invalidResponse("无法解析 \(providerType.displayName) 响应")
                    }
                    content = text
                }

                MixLog.info("AI 响应成功: \(content.count) 字符")
                return content
            } catch let error as AIProviderError {
                lastError = error
                if case .apiKeyNotConfigured = error { throw error }
            } catch {
                lastError = error
                if "\(error)".contains("429") || "\(error)".lowercased().contains("rate") {
                    lastError = AIProviderError.rateLimited
                    continue
                }
            }
        }

        throw lastError ?? AIProviderError.requestFailed("未知错误")
    }

    /// 从响应中提取 JSON 字符串（去除 markdown 代码块包裹及前后说明文字）
    private func extractJSON(from text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 方式 1: 从 ```json ... ``` 代码块中提取
        if let jsonBlockRange = cleaned.range(of: "```json\\s*\\n", options: .regularExpression),
           let endRange = cleaned.range(of: "```", options: .backwards, range: jsonBlockRange.upperBound..<cleaned.endIndex) {
            cleaned = String(cleaned[jsonBlockRange.upperBound..<endRange.lowerBound])
            return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 方式 2: 从 ``` ... ``` 代码块中提取
        if let startRange = cleaned.range(of: "```\\s*\\n", options: .regularExpression),
           let endRange = cleaned.range(of: "```", options: .backwards, range: startRange.upperBound..<cleaned.endIndex) {
            cleaned = String(cleaned[startRange.upperBound..<endRange.lowerBound])
            return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 方式 3: 简单去掉首尾 ``` 标记
        if cleaned.hasPrefix("```json") {
            cleaned = String(cleaned.dropFirst(7))
        } else if cleaned.hasPrefix("```") {
            cleaned = String(cleaned.dropFirst(3))
        }
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }

        // 方式 4: 找第一个 { 和最后一个 } 之间的内容（兜底）
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.hasPrefix("{"), let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}") {
            cleaned = String(trimmed[firstBrace...lastBrace])
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
