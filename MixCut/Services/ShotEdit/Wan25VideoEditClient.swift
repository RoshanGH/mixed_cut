import Foundation

/// 阿里通义万相 `wan2.7-videoedit` 指令式视频编辑客户端（DashScope 异步 task）。
///
/// 流程（Phase 0 已实测）：POST 提交（`X-DashScope-Async: enable`）→ `output.task_id`
/// → 轮询 `GET /tasks/{id}` 看 `output.task_status` → SUCCEEDED 取 `output.video_url`（24h 过期）。
/// `media` 支持 Base64 内联（`data:video/mp4;base64,...`），无需 OSS 上传。
/// 鉴权复用千问 DashScope key（`api_key_qwen`）。
actor Wan25VideoEditClient {
    enum ClientError: LocalizedError {
        case missingAPIKey
        case badResponse(String)
        case taskFailed(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "未配置千问(DashScope) API Key，请在设置中填写"
            case .badResponse(let s): return "接口返回异常：\(s)"
            case .taskFailed(let s): return "生成失败：\(s)"
            case .timeout: return "生成超时（超过 10 分钟）"
            }
        }
    }

    private static let submitURL = URL(string: "https://dashscope.aliyuncs.com/api/v1/services/aigc/video-generation/video-synthesis")!
    private static func taskURL(_ id: String) -> URL {
        URL(string: "https://dashscope.aliyuncs.com/api/v1/tasks/\(id)")!
    }
    private static let model = "wan2.7-videoedit"

    private let apiKeyProvider: @Sendable () -> String?
    private let pollInterval: UInt64
    private let maxPolls: Int

    init(apiKeyProvider: @escaping @Sendable () -> String? = { KeychainHelper.getAPIKey(for: .qwen) },
         pollIntervalSeconds: UInt64 = 15,
         maxPolls: Int = 40) {
        self.apiKeyProvider = apiKeyProvider
        self.pollInterval = pollIntervalSeconds * 1_000_000_000
        self.maxPolls = maxPolls
    }

    /// 提交一段视频 + 提示词做局部编辑，返回结果视频 URL（调用方负责下载）。
    /// - Parameter videoFileURL: 本地分镜头切片（mp4），内部转 Base64 内联。
    func edit(videoFileURL: URL,
              prompt: String,
              onStatus: @Sendable (String) -> Void = { _ in }) async throws -> URL {
        guard let key = apiKeyProvider(), !key.isEmpty else { throw ClientError.missingAPIKey }

        // 1) 组请求体（Base64 内联 media）
        let data = try Data(contentsOf: videoFileURL)
        let b64 = data.base64EncodedString()
        let body: [String: Any] = [
            "model": Self.model,
            "input": [
                "prompt": prompt,
                "media": [
                    ["type": "video", "url": "data:video/mp4;base64,\(b64)"]
                ]
            ],
            "parameters": [
                "resolution": "720P",
                "ratio": "9:16",
                "duration": 0,
                "watermark": false,
                "prompt_extend": true
            ]
        ]

        var req = URLRequest(url: Self.submitURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("enable", forHTTPHeaderField: "X-DashScope-Async")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, resp) = try await URLSession.shared.data(for: req)
        try Self.assertHTTPOK(resp, respData)
        let taskId = try Self.parseTaskId(respData)
        onStatus("生成中")

        // 2) 轮询
        for _ in 0..<maxPolls {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: pollInterval)
            var qreq = URLRequest(url: Self.taskURL(taskId))
            qreq.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let (qdata, qresp) = try await URLSession.shared.data(for: qreq)
            try Self.assertHTTPOK(qresp, qdata)
            let (status, videoURL, msg) = try Self.parseTaskStatus(qdata)
            switch status {
            case "SUCCEEDED":
                guard let u = videoURL else { throw ClientError.badResponse("成功但无 video_url") }
                return Self.upgradedToHTTPS(u)
            case "FAILED":
                throw ClientError.taskFailed(msg ?? "task failed")
            default:
                onStatus("生成中")   // PENDING / RUNNING
            }
        }
        throw ClientError.timeout
    }

    // MARK: - 解析

    private static func assertHTTPOK(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw ClientError.badResponse("HTTP \(http.statusCode) \(raw)")
        }
    }

    private static func parseTaskId(_ data: Data) throws -> String {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = obj["output"] as? [String: Any],
              let id = output["task_id"] as? String, !id.isEmpty else {
            throw ClientError.badResponse(String(data: data, encoding: .utf8) ?? "无 task_id")
        }
        return id
    }

    private static func parseTaskStatus(_ data: Data) throws -> (String, URL?, String?) {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = obj["output"] as? [String: Any],
              let status = output["task_status"] as? String else {
            throw ClientError.badResponse(String(data: data, encoding: .utf8) ?? "无 task_status")
        }
        let url = (output["video_url"] as? String).flatMap { URL(string: $0) }
        let msg = output["message"] as? String ?? output["code"] as? String
        return (status, url, msg)
    }

    /// OSS 结果 URL 多为 http，会被 ATS 拦截；升级 https（预签名 V1 不含 scheme，不影响签名）。
    private static func upgradedToHTTPS(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http",
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.scheme = "https"
        return comps.url ?? url
    }
}
