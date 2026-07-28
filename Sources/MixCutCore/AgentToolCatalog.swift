import Foundation

/// Agent 工具错误码（工具层结构化错误，区别于 JSON-RPC 协议层错误）
public enum AgentToolErrorCode: String, Sendable {
    case invalidArgument = "INVALID_ARGUMENT"
    case projectNotFound = "PROJECT_NOT_FOUND"
    case videoNotFound = "VIDEO_NOT_FOUND"
    case jobNotFound = "JOB_NOT_FOUND"
    case fileNotFound = "FILE_NOT_FOUND"
    case jobAlreadyRunning = "JOB_ALREADY_RUNNING"
}

/// 工具结果/错误的 JSON 文本编码
public enum AgentJSON {
    public static func encode(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return #"{"code":"INVALID_ARGUMENT","message":"内部错误：结果无法编码为 JSON"}"#
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public static func error(code: AgentToolErrorCode, message: String) -> String {
        encode(["code": code.rawValue, "message": message])
    }
}

/// 第一阶段的 9 个 MCP 工具定义（实现在 app target 的 MCPToolHandlers）
public enum AgentToolCatalog {
    public static let all: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "list_projects",
            description: "列出所有项目及其状态、视频数、分镜数、方案数",
            inputSchemaJSON: #"{"type":"object","properties":{},"required":[]}"#),
        MCPToolDefinition(
            name: "get_project",
            description: "获取项目详情，含每个视频的处理状态、时长、失败原因、分镜数",
            inputSchemaJSON: #"{"type":"object","properties":{"project_id":{"type":"string","description":"项目 UUID"}},"required":["project_id"]}"#),
        MCPToolDefinition(
            name: "list_segments",
            description: "列出分镜（台词、帧范围、语义类型、位置、质量分）。project_id 与 video_id 二选一，同时提供报错",
            inputSchemaJSON: #"{"type":"object","properties":{"project_id":{"type":"string","description":"项目 UUID（与 video_id 二选一）"},"video_id":{"type":"string","description":"视频 UUID（与 project_id 二选一）"},"semantic_type":{"type":"string","description":"可选，按语义类型过滤，如 痛点/行动号召"},"position_type":{"type":"string","description":"可选，按位置过滤：开头/中间/结尾"}},"required":[]}"#),
        MCPToolDefinition(
            name: "get_job",
            description: "查询异步任务状态与该项目所有视频的实时流水线进度",
            inputSchemaJSON: #"{"type":"object","properties":{"job_id":{"type":"string","description":"任务 UUID"}},"required":["job_id"]}"#),
        MCPToolDefinition(
            name: "create_project",
            description: "新建项目",
            inputSchemaJSON: #"{"type":"object","properties":{"name":{"type":"string","description":"项目名称"}},"required":["name"]}"#),
        MCPToolDefinition(
            name: "import_videos",
            description: "把本地视频文件导入项目并启动完整分析流水线（场景检测→ASR→AI 语义分析→边界优化）。立即返回 job_id，用 get_job 轮询进度",
            inputSchemaJSON: #"{"type":"object","properties":{"project_id":{"type":"string","description":"项目 UUID"},"paths":{"type":"array","items":{"type":"string"},"description":"视频文件绝对路径数组"}},"required":["project_id","paths"]}"#),
        MCPToolDefinition(
            name: "retry_analysis",
            description: "对失败的视频重试 AI 语义分析。返回 job_id",
            inputSchemaJSON: #"{"type":"object","properties":{"video_id":{"type":"string","description":"视频 UUID"}},"required":["video_id"]}"#),
        MCPToolDefinition(
            name: "retry_asr",
            description: "对识别异常的视频重跑语音识别（会连带重做 AI 分析并重建分镜）。返回 job_id",
            inputSchemaJSON: #"{"type":"object","properties":{"video_id":{"type":"string","description":"视频 UUID"}},"required":["video_id"]}"#),
        MCPToolDefinition(
            name: "remove_video",
            description: "从项目移除视频（立即生效，无撤销）。若视频不被其它项目引用则连分镜记录一起删除",
            inputSchemaJSON: #"{"type":"object","properties":{"project_id":{"type":"string","description":"项目 UUID"},"video_id":{"type":"string","description":"视频 UUID"}},"required":["project_id","video_id"]}"#),
    ]
}
