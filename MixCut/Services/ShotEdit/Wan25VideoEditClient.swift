import Foundation

/// 阿里通义万相 `wan2.7-videoedit` 指令式视频编辑客户端（DashScope 异步 task）。
///
/// 流程（Phase 0 已实测）：POST 提交（`X-DashScope-Async: enable`）→ `output.task_id`
/// → 轮询 `GET /tasks/{id}` 看 `output.task_status` → SUCCEEDED 取 `output.video_url`（24h 过期）。
/// `media` 支持 Base64 内联（`data:video/mp4;base64,...`），无需 OSS 上传。
/// 鉴权复用千问 DashScope key（`api_key_qwen`）。
///
/// 设计要点（防重复扣费）：提交与轮询**拆成两个独立方法**。调用方拿到 `submit()` 返回的
/// taskId 后必须**立即落库**；此后任何「重试」都只用 taskId 走 `poll()` 查旧任务结果，
/// 绝不重复提交（阿里按任务成功计费，重复提交 = 重复扣费）。
actor Wan25VideoEditClient {
    enum ClientError: LocalizedError {
        case missingAPIKey
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "未配置千问(DashScope) API Key，请在设置中填写"
            case .badResponse(let s): return "接口返回异常：\(s)"
            }
        }
    }

    /// 单次轮询的结果（对应 DashScope `task_status`）。
    enum PollOutcome: Sendable {
        case succeeded(URL)      // SUCCEEDED，带结果视频地址
        case running             // PENDING / RUNNING，仍在跑
        case failed(String)      // FAILED / CANCELED，带原因
        case expired             // UNKNOWN：任务不存在/已过期(超24h)/非本账户
    }

    private static let submitURL = URL(string: "https://dashscope.aliyuncs.com/api/v1/services/aigc/video-generation/video-synthesis")!
    private static func taskURL(_ id: String) -> URL {
        URL(string: "https://dashscope.aliyuncs.com/api/v1/tasks/\(id)")!
    }
    private static let model = "wan2.7-videoedit"

    private let apiKeyProvider: @Sendable () -> String?

    init(apiKeyProvider: @escaping @Sendable () -> String? = { KeychainHelper.getAPIKey(for: .qwen) }) {
        self.apiKeyProvider = apiKeyProvider
    }

    // MARK: - 提交（异步任务）

    /// 提交一段视频 + 提示词做局部编辑，**返回 taskId**（不等待结果）。
    /// 调用方拿到 taskId 后应立即落库，再用 `poll(taskId:)` 轮询。
    /// - Parameter videoFileURL: 本地分镜头切片（mp4），内部转 Base64 内联。
    func submit(videoFileURL: URL, prompt: String) async throws -> String {
        guard let key = apiKeyProvider(), !key.isEmpty else { throw ClientError.missingAPIKey }

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
        return try Self.parseTaskId(respData)
    }

    // MARK: - 轮询（查一次）

    /// 查询一次任务状态。**只读、幂等、不产生费用**，可安全重复调用。
    func poll(taskId: String) async throws -> PollOutcome {
        guard let key = apiKeyProvider(), !key.isEmpty else { throw ClientError.missingAPIKey }
        var qreq = URLRequest(url: Self.taskURL(taskId))
        qreq.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (qdata, qresp) = try await URLSession.shared.data(for: qreq)
        try Self.assertHTTPOK(qresp, qdata)

        let (status, videoURL, msg) = try Self.parseTaskStatus(qdata)
        switch status {
        case "SUCCEEDED":
            guard let u = videoURL else { return .failed("任务成功但未返回结果视频地址") }
            return .succeeded(Self.upgradedToHTTPS(u))
        case "FAILED":
            return .failed(msg ?? "task failed")
        case "CANCELED":
            return .failed(msg ?? "任务已取消")
        case "UNKNOWN":
            // 实测：不存在/过期(超24h)/非本账户的 taskId → HTTP 200 + task_status=UNKNOWN
            return .expired
        default:
            return .running   // PENDING / RUNNING / 其它未知中间态
        }
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
