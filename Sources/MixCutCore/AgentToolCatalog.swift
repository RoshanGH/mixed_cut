import Foundation

/// Agent 工具错误码（工具层结构化错误，区别于 JSON-RPC 协议层错误）
public enum AgentToolErrorCode: String, Sendable {
    case invalidArgument = "INVALID_ARGUMENT"
    case projectNotFound = "PROJECT_NOT_FOUND"
    case videoNotFound = "VIDEO_NOT_FOUND"
    case jobNotFound = "JOB_NOT_FOUND"
    case fileNotFound = "FILE_NOT_FOUND"
    case jobAlreadyRunning = "JOB_ALREADY_RUNNING"
    case segmentNotFound = "SEGMENT_NOT_FOUND"
    case schemeNotFound = "SCHEME_NOT_FOUND"
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
    /// initialize 握手时下发给客户端的服务器说明（客户端注入给模型）。
    /// 作用：让任何注册了本服务的 Agent 自动知道 MC 简写、寻址约定、核心工作流和注意事项。
    public static let serverInstructions = """
    MixCut（用户常用简写：MC）是一款 macOS 端 AI 视频混剪应用，面向广告投放团队。\
    用户说「MC」「混剪工具」时即指本服务。

    寻址约定：视频用 video_no（项目内按导入顺序 1 起），分镜用 segment_nos（视频内按时间顺序 1 起，与 UI 卡片 # 编号一致）。\
    用户说「1 号视频的 3~8 号分镜」即 video_no=1, segment_nos=[3,4,5,6,7,8]。先 get_project / list_segments 查看编号再操作。

    核心工作流：
    1. 导入分析：create_project → import_videos（返回 job_id）→ get_job 轮询直到 state 不是 running → list_segments 查看分镜，失败用 retry_analysis / retry_asr。
    2. 分镜修改：update_segment_tags 改标签；update_segment_text 改台词（修错别字/润色）；adjust_segment_boundary 按帧调边界；set_subtitle_mode 设字幕；set_voice_keep_original 保留原声；generate_voice_variants 生成声音变体（job）；delete_segments 删分镜。
    3. 组合与导出：generate_schemes AI 生成方案（job）；create_custom_scheme 自选分镜组方案；export_scheme 导出方案成片（job）；export_segments 导出分镜片段（job）。

    重要规则：
    - 字幕只有三档：「直接烧录」「模糊虚化」「纯色遮挡」。用户用词含糊（如"直接收录"）时，必须报出这三个名称请用户确认，不得自行猜测。
    - 分镜是全局共享的：修改/删除分镜会影响所有引用同一视频的项目，涉及多项目时先告知用户。
    - adjust_segment_boundary 返回 stale_dubs 时，表示这些分镜已生成的配音按旧时长合成、导出会静默用旧音频；只提醒用户，是否重新生成（generate_voice_variants）由用户决定，不要自作主张重跑。
    - 同一时间只允许一个异步任务（JOB_ALREADY_RUNNING）；app 重启后 job 丢失（JOB_NOT_FOUND），改查 get_project。
    - delete_project 必须两步：先不带 confirm 拿影响预览给用户确认，再 confirm=true 执行。delete_segments / remove_video 立即生效无撤销。
    """

    public static let all: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "list_projects",
            description: "列出所有项目及其状态、视频数、分镜数、方案数",
            inputSchemaJSON: #"{"type":"object","properties":{},"required":[]}"#,
            annotationsJSON: #"{"readOnlyHint":true}"#),
        MCPToolDefinition(
            name: "get_project",
            description: "获取项目详情，含每个视频的处理状态、时长、失败原因、分镜数",
            inputSchemaJSON: #"{"type":"object","properties":{"project_id":{"type":"string","description":"项目 UUID"}},"required":["project_id"]}"#,
            annotationsJSON: #"{"readOnlyHint":true}"#),
        MCPToolDefinition(
            name: "list_segments",
            description: "列出分镜（台词、帧范围、语义类型、位置、质量分）。project_id 与 video_id 二选一，同时提供报错",
            inputSchemaJSON: #"{"type":"object","properties":{"project_id":{"type":"string","description":"项目 UUID（与 video_id 二选一）"},"video_id":{"type":"string","description":"视频 UUID（与 project_id 二选一）"},"semantic_type":{"type":"string","description":"可选，按语义类型过滤，如 痛点/行动号召"},"position_type":{"type":"string","description":"可选，按位置过滤：开头/中间/结尾"}},"required":[]}"#,
            annotationsJSON: #"{"readOnlyHint":true}"#),
        MCPToolDefinition(
            name: "list_schemes",
            description: "列出项目的混剪方案（名称、风格、所属策略、预计时长、分镜序列），供选择导出",
            inputSchemaJSON: #"{"type":"object","properties":{"project_id":{"type":"string","description":"项目 UUID"}},"required":["project_id"]}"#,
            annotationsJSON: #"{"readOnlyHint":true}"#),
        MCPToolDefinition(
            name: "get_job",
            description: "查询异步任务状态与该项目所有视频的实时流水线进度",
            inputSchemaJSON: #"{"type":"object","properties":{"job_id":{"type":"string","description":"任务 UUID"}},"required":["job_id"]}"#,
            annotationsJSON: #"{"readOnlyHint":true}"#),
        MCPToolDefinition(
            name: "create_project",
            description: "新建项目",
            inputSchemaJSON: #"{"type":"object","properties":{"name":{"type":"string","description":"项目名称"}},"required":["name"]}"#,
            annotationsJSON: #"{"readOnlyHint":false,"destructiveHint":false}"#),
        MCPToolDefinition(
            name: "import_videos",
            description: "把本地视频文件导入项目并启动完整分析流水线（场景检测→ASR→AI 语义分析→边界优化）。立即返回 job_id，用 get_job 轮询进度",
            inputSchemaJSON: #"{"type":"object","properties":{"project_id":{"type":"string","description":"项目 UUID"},"paths":{"type":"array","items":{"type":"string"},"description":"视频文件绝对路径数组"}},"required":["project_id","paths"]}"#,
            annotationsJSON: #"{"readOnlyHint":false,"destructiveHint":false}"#),
        MCPToolDefinition(
            name: "retry_analysis",
            description: "对失败的视频重试 AI 语义分析。返回 job_id",
            inputSchemaJSON: #"{"type":"object","properties":{"video_id":{"type":"string","description":"视频 UUID"}},"required":["video_id"]}"#,
            annotationsJSON: #"{"readOnlyHint":false,"destructiveHint":false}"#),
        MCPToolDefinition(
            name: "retry_asr",
            description: "对识别异常的视频重跑语音识别（会连带重做 AI 分析并重建分镜）。返回 job_id",
            inputSchemaJSON: #"{"type":"object","properties":{"video_id":{"type":"string","description":"视频 UUID"}},"required":["video_id"]}"#,
            annotationsJSON: #"{"readOnlyHint":false,"destructiveHint":false}"#),
        MCPToolDefinition(
            name: "remove_video",
            description: "从项目移除视频（立即生效，无撤销）。若视频不被其它项目引用则连分镜记录一起删除",
            inputSchemaJSON: #"{"type":"object","properties":{"project_id":{"type":"string","description":"项目 UUID"},"video_id":{"type":"string","description":"视频 UUID"}},"required":["project_id","video_id"]}"#,
            annotationsJSON: #"{"readOnlyHint":false,"destructiveHint":true}"#),
        MCPToolDefinition(
            name: "generate_schemes",
            description: "AI 生成混剪方案（策略生成→批量分镜组合，与 UI 流程一致）。需要已配置 AI API Key。返回 job_id，用 get_job 轮询",
            inputSchemaJSON: #"{"type":"object","properties":{"project_id":{"type":"string","description":"项目 UUID"},"target_count":{"type":"integer","description":"目标方案数量，默认 50，上限 100"},"custom_prompt":{"type":"string","description":"可选的自定义生成要求"}},"required":["project_id"]}"#,
            annotationsJSON: #"{"readOnlyHint":false,"destructiveHint":false}"#),
        MCPToolDefinition(
            name: "export_scheme",
            description: "把方案导出为成片 mp4（原声导出，默认 H.264 硬件加速，命名规则与 UI 批量导出一致）。返回 job_id，用 get_job 轮询",
            inputSchemaJSON: #"{"type":"object","properties":{"scheme_ids":{"type":"array","items":{"type":"string"},"description":"要导出的方案 UUID 数组，串行导出"},"output_dir":{"type":"string","description":"输出目录绝对路径，必须已存在且可写"}},"required":["scheme_ids","output_dir"]}"#,
            annotationsJSON: #"{"readOnlyHint":false,"destructiveHint":false}"#),
        MCPToolDefinition(
            name: "delete_project",
            description: "删除整个项目（无撤销）。需二次确认：不带 confirm 时只返回影响预览（将删除的视频/方案数），带 confirm=true 才真正执行。方案/策略级联删除；视频仅在不被其它项目引用时才连分镜一起删除",
            inputSchemaJSON: #"{"type":"object","properties":{"project_id":{"type":"string","description":"项目 UUID"},"confirm":{"type":"boolean","description":"必须显式传 true 才执行删除；省略或 false 时仅返回影响预览"}},"required":["project_id"]}"#,
            annotationsJSON: #"{"readOnlyHint":false,"destructiveHint":true}"#),
        MCPToolDefinition(
            name: "update_segment_tags",
            description: "批量修改分镜标签。add/remove/set_semantic_types 三选一（11 种：噱头引入/痛点/产品方案/效果展示/信任背书/价格对比/活动福利/行动号召/产品定位/产品使用教育/过渡），可同时设 position_type（开头/中间/结尾）。每个分镜至少保留 1 个语义类型",
            inputSchemaJSON: #"{"type":"object","properties":{"project_id":{"type":"string","description":"项目 UUID（与 video_no/segment_nos 配合使用）"},"video_no":{"type":"integer","description":"视频编号：项目内按导入顺序 1 起"},"segment_nos":{"type":"array","items":{"type":"integer"},"description":"分镜编号数组：视频内按时间顺序 1 起，如 [3,4,5]"},"segment_ids":{"type":"array","items":{"type":"string"},"description":"分镜 UUID 数组（与编号方式二选一）"},"add_semantic_types":{"type":"array","items":{"type":"string"},"description":"要添加的语义类型"},"remove_semantic_types":{"type":"array","items":{"type":"string"},"description":"要移除的语义类型"},"set_semantic_types":{"type":"array","items":{"type":"string"},"description":"直接替换为这组语义类型"},"position_type":{"type":"string","description":"位置：开头/中间/结尾"}},"required":[]}"#,
            annotationsJSON: #"{"readOnlyHint":false,"destructiveHint":false}"#),
        MCPToolDefinition(
            name: "update_segment_text",
            description: "批量修改分镜台词（修错别字/润色）。items 每项 {video_no, segment_no, text} 或 {segment_id, text}，每条分镜各配各的新台词；用 video_no 寻址时需带顶层 project_id；同一分镜在 items 中重复出现时按顺序最后一条生效。台词全局共享，改动即时同步到所有引用该视频的项目。⚠️ 已生成的配音变体是基于旧台词改写的，不会自动更新；是否用 generate_voice_variants 重新生成由用户决定",
            inputSchemaJSON: #"{"type":"object","properties":{"project_id":{"type":"string","description":"项目 UUID（items 用 video_no+segment_no 寻址时必填）"},"items":{"type":"array","items":{"type":"object","properties":{"video_no":{"type":"integer","description":"视频编号：项目内按导入顺序 1 起"},"segment_no":{"type":"integer","description":"分镜编号：视频内按时间顺序 1 起"},"segment_id":{"type":"string","description":"分镜 UUID（与编号方式二选一）"},"text":{"type":"string","description":"该分镜的新台词，不能为空"}},"required":["text"]},"description":"有序修改列表，每项定位一个分镜并给出新台词"}},"required":["items"]}"#,
            annotationsJSON: #"{"readOnlyHint":false,"destructiveHint":false}"#),
        MCPToolDefinition(
            name: "adjust_segment_boundary",
            description: "按帧批量调整分镜边界（start_delta_frames/end_delta_frames 可负；绝对值 start_frame/end_frame 仅单分镜可用）。自动重配台词与缩略图。⚠️ 已生成配音的分镜会返回 stale_dubs 提醒（配音按旧时长合成，导出会静默用旧音频），是否重新生成由用户决定",
            inputSchemaJSON: #"{"type":"object","properties":{"project_id":{"type":"string","description":"项目 UUID（与 video_no/segment_nos 配合使用）"},"video_no":{"type":"integer","description":"视频编号：项目内按导入顺序 1 起"},"segment_nos":{"type":"array","items":{"type":"integer"},"description":"分镜编号数组：视频内按时间顺序 1 起"},"segment_ids":{"type":"array","items":{"type":"string"},"description":"分镜 UUID 数组（与编号方式二选一）"},"start_delta_frames":{"type":"integer","description":"起点偏移帧数，可负"},"end_delta_frames":{"type":"integer","description":"终点偏移帧数，可负（往后延伸用正数）"},"start_frame":{"type":"integer","description":"起点绝对帧（仅单分镜）"},"end_frame":{"type":"integer","description":"终点绝对帧（仅单分镜）"}},"required":[]}"#,
            annotationsJSON: #"{"readOnlyHint":false,"destructiveHint":false}"#),
        MCPToolDefinition(
            name: "set_subtitle_mode",
            description: "设置字幕处理模式，只认三档：直接烧录（新字幕直接叠加）/模糊虚化（原字幕区域模糊后烧新字幕）/纯色遮挡（色块盖住原字幕再烧新字幕）。用户用词含糊时必须报出三档名称请其确认。可同时设字号 font_ratio（0.030-0.085）与遮挡区域 mask_y/mask_height（0-1）。保留原声的分镜自动跳过",
            inputSchemaJSON: #"{"type":"object","properties":{"project_id":{"type":"string","description":"项目 UUID（与 video_no/segment_nos 配合使用）"},"video_no":{"type":"integer","description":"视频编号：项目内按导入顺序 1 起"},"segment_nos":{"type":"array","items":{"type":"integer"},"description":"分镜编号数组：视频内按时间顺序 1 起"},"segment_ids":{"type":"array","items":{"type":"string"},"description":"分镜 UUID 数组（与编号方式二选一）"},"mode":{"type":"string","enum":["直接烧录","模糊虚化","纯色遮挡"],"description":"字幕三档之一，必须明确"},"font_ratio":{"type":"number","description":"字号比例 0.030-0.085，超界自动钳制"},"mask_y":{"type":"number","description":"遮挡区域顶部位置 0-1（原点左上）"},"mask_height":{"type":"number","description":"遮挡区域高度 0-1"}},"required":["mode"]}"#,
            annotationsJSON: #"{"readOnlyHint":false,"destructiveHint":false}"#),
        MCPToolDefinition(
            name: "set_voice_keep_original",
            description: "设置保留原声开关：开=不改写不配音、导出不加字幕。可选设置原声是否参与导出组合",
            inputSchemaJSON: #"{"type":"object","properties":{"project_id":{"type":"string","description":"项目 UUID（与 video_no/segment_nos 配合使用）"},"video_no":{"type":"integer","description":"视频编号：项目内按导入顺序 1 起"},"segment_nos":{"type":"array","items":{"type":"integer"},"description":"分镜编号数组：视频内按时间顺序 1 起"},"segment_ids":{"type":"array","items":{"type":"string"},"description":"分镜 UUID 数组（与编号方式二选一）"},"keep_original":{"type":"boolean","description":"true=保留原声"},"original_in_combination":{"type":"boolean","description":"可选：原声是否参与导出组合"}},"required":["keep_original"]}"#,
            annotationsJSON: #"{"readOnlyHint":false,"destructiveHint":false}"#),
        MCPToolDefinition(
            name: "set_dub_participation",
            description: "设置指定声音变体是否参与导出组合（对应 UI 变体面板勾选）",
            inputSchemaJSON: #"{"type":"object","properties":{"project_id":{"type":"string","description":"项目 UUID（与 video_no/segment_nos 配合使用）"},"video_no":{"type":"integer","description":"视频编号：项目内按导入顺序 1 起"},"segment_nos":{"type":"array","items":{"type":"integer"},"description":"分镜编号数组：视频内按时间顺序 1 起"},"segment_ids":{"type":"array","items":{"type":"string"},"description":"分镜 UUID 数组（与编号方式二选一）"},"variant_indexes":{"type":"array","items":{"type":"integer"},"description":"变体序号数组（list_segments 的 voice_variant_count 内）"},"participates":{"type":"boolean","description":"是否参与导出组合"}},"required":["variant_indexes","participates"]}"#,
            annotationsJSON: #"{"readOnlyHint":false,"destructiveHint":false}"#),
        MCPToolDefinition(
            name: "generate_voice_variants",
            description: "为分镜生成声音变体：自动克隆原声→AI 改写 K 套→合成配音→字幕对齐（与 UI 一键改写同流程）。需要千问 API Key。返回 job_id 轮询",
            inputSchemaJSON: #"{"type":"object","properties":{"project_id":{"type":"string","description":"项目 UUID（与 video_no/segment_nos 配合使用）"},"video_no":{"type":"integer","description":"视频编号：项目内按导入顺序 1 起"},"segment_nos":{"type":"array","items":{"type":"integer"},"description":"分镜编号数组：视频内按时间顺序 1 起"},"segment_ids":{"type":"array","items":{"type":"string"},"description":"分镜 UUID 数组（与编号方式二选一）"}},"required":[]}"#,
            annotationsJSON: #"{"readOnlyHint":false,"destructiveHint":false}"#),
        MCPToolDefinition(
            name: "delete_segments",
            description: "批量删除分镜（立即生效，无撤销）。级联删除其配音变体与方案槽位记录，结果列出受影响的方案",
            inputSchemaJSON: #"{"type":"object","properties":{"project_id":{"type":"string","description":"项目 UUID（与 video_no/segment_nos 配合使用）"},"video_no":{"type":"integer","description":"视频编号：项目内按导入顺序 1 起"},"segment_nos":{"type":"array","items":{"type":"integer"},"description":"分镜编号数组：视频内按时间顺序 1 起"},"segment_ids":{"type":"array","items":{"type":"string"},"description":"分镜 UUID 数组（与编号方式二选一）"}},"required":[]}"#,
            annotationsJSON: #"{"readOnlyHint":false,"destructiveHint":true}"#),
        MCPToolDefinition(
            name: "create_custom_scheme",
            description: "跨视频自选分镜按顺序组成方案（进「自定义组合」分组），之后可用 export_scheme 导出。segments 为有序数组，每项 {video_no, segment_no} 或 {segment_id}",
            inputSchemaJSON: #"{"type":"object","properties":{"project_id":{"type":"string","description":"项目 UUID"},"name":{"type":"string","description":"方案名称，缺省自动编号"},"segments":{"type":"array","items":{"type":"object","properties":{"video_no":{"type":"integer"},"segment_no":{"type":"integer"},"segment_id":{"type":"string"}}},"description":"有序分镜列表，跨视频任意混排"}},"required":["project_id","segments"]}"#,
            annotationsJSON: #"{"readOnlyHint":false,"destructiveHint":false}"#),
        MCPToolDefinition(
            name: "export_segments",
            description: "批量导出分镜片段为独立 mp4 到指定目录（命名规则与 UI 批量导出一致）。返回 job_id 轮询",
            inputSchemaJSON: #"{"type":"object","properties":{"project_id":{"type":"string","description":"项目 UUID（与 video_no/segment_nos 配合使用）"},"video_no":{"type":"integer","description":"视频编号：项目内按导入顺序 1 起"},"segment_nos":{"type":"array","items":{"type":"integer"},"description":"分镜编号数组：视频内按时间顺序 1 起"},"segment_ids":{"type":"array","items":{"type":"string"},"description":"分镜 UUID 数组（与编号方式二选一）"},"output_dir":{"type":"string","description":"输出目录绝对路径，必须已存在且可写"}},"required":["output_dir"]}"#,
            annotationsJSON: #"{"readOnlyHint":false,"destructiveHint":false}"#),
    ]
}
