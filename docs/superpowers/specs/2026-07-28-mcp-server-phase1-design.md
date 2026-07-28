# MCP Server 第一阶段设计：让 AI Agent 操作 MixCut 工作流

日期：2026-07-28
状态：已确认（用户委托技术判断）
分支：`feature/mcp-server-phase1`

## 背景与目标

MixCut 的人工工作流已经跑顺。本设计是"Agent 操作 MixCut"三阶段路线的第一阶段：
在 app 进程内嵌一个本地 MCP server，让 Claude Code 能够**批量导入视频、监控 8 步分析流水线、汇总失败并重试**。

**验收场景**：在 Claude Code 里，Agent 完成——新建项目 → 批量导入一组本地视频 →
轮询流水线进度直到完成 → 汇总每个视频的分镜结果与失败原因 → 对失败视频重试 →
（可选）移除导错的视频。全程 MixCut UI 实时可见 Agent 的操作。

**非目标（后续阶段）**：方案生成、变体选择、导出、自动质量验收、抽取共享 ImportPipeline。

## 已确认的决策

| 决策点 | 结论 |
|---|---|
| 验收场景 | 批量导入 + 盯流水线（最小范围） |
| Agent 客户端 | Claude Code（HTTP transport） |
| 写权限边界 | 建项目 + 导入 + 重试 + 删除视频 |
| Server 实现 | 自实现零依赖：NWListener + 手写 HTTP/1.1 + JSON-RPC，不引入任何 SPM 依赖 |
| 导入编排复用 | MCP 持有 headless `ImportViewModel` 实例；不在本阶段重构 1171 行的核心 VM |

## 架构

新增代码集中在 `MixCut/Services/MCP/`（app target）+ `Sources/MixCutCore/MCPProtocol.swift`（纯逻辑，可单测）。

```
Claude Code ──HTTP POST /mcp (JSON-RPC)──▶ 127.0.0.1:8787
                                              │
                                    ┌─────────▼─────────┐
                                    │ MCPServer (actor)  │  NWListener HTTP 监听（app target）
                                    └─────────┬─────────┘
                                              │ 解析/编码委托给 MixCutCore.MCPProtocol（纯函数，单测）
                                              │ await MainActor
                                    ┌─────────▼─────────┐
                                    │ MCPToolHandlers    │  @MainActor，9 个工具实现，读写 mainContext
                                    └───┬───────────┬───┘
                              ┌─────────▼──┐  ┌─────▼──────────┐
                              │ AgentJob   │  │ headless        │
                              │ Registry   │  │ ImportViewModel │──▶ 现有 Service 层（零改动）
                              │(@MainActor)│  │（共用 mainContext） │
                              └────────────┘  └────────────────┘
```

### 组件职责

1. **`MixCutCore.MCPProtocol`（新，纯逻辑）**
   - JSON-RPC 2.0 请求解析、响应/错误编码；MCP 方法路由：`initialize` /
     `notifications/initialized` / `tools/list` / `tools/call` / `ping`。
   - 工具定义（名称 + description + inputSchema JSON）也在这里声明，处理函数由 app 侧注入。
   - 不含任何网络、SwiftData 依赖 → Swift Testing TDD 单测。

2. **`MCPServer`（actor，app target）**
   - `NWListener` 绑定 `127.0.0.1`（硬编码，绝不监听 0.0.0.0），默认端口 8787。
   - 极简 HTTP/1.1：只接受 `POST /mcp`（Content-Type: application/json，按 Content-Length 读 body），
     其余路径/方法返回 404/405。响应为普通 JSON（不实现 SSE；进度用轮询工具获取）。
   - 请求体交给 `MCPProtocol` 解析路由；`tools/call` 跳到 MainActor 执行处理函数。
   - 端口被占用：启动失败时 Toast 提示 + Settings 里可改端口；不崩溃、不重试抢占。

3. **`MCPToolHandlers`（@MainActor）**
   - 持有 `modelContainer.mainContext`（与 UI 同一个，**不新建 ModelContext**，避免对象身份不一致）。
   - 持有 MCP 专属的 headless `ImportViewModel` 实例（`setModelContext(mainContext)`）。
     其 Toast 照常弹出——作为"Agent 在干活"的 UI 可视信号，不视为缺陷。

4. **`AgentJobRegistry`（@MainActor）**
   - 内存注册表：`job = {id, kind, state(running/completed/failed), startedAt, finishedAt,
     projectID, videoIDs, report}`。
   - 同一时间只允许一个 import/retry 类 job 在跑，重复发起返回 `JOB_ALREADY_RUNNING`
     （与 UI 串行导入行为一致，规避共享 mainContext 的并发踩踏）。
   - app 重启 job 丢失：可接受。启动时现有 `resetStaleAnalyzingStatus` 会自愈卡住的视频状态，
     Agent 通过 `get_project` 即可看到真实状态。

5. **Settings 新增"Agent 接入"区块**
   - 开关（默认开）+ 端口（默认 8787），存 UserDefaults；变更后重启 server。
   - 显示 Claude Code 注册命令一行，便于复制：
     `claude mcp add --transport http mixcut http://127.0.0.1:8787/mcp`

### 对现有代码的改动（刻意最小化）

| 文件 | 改动 | 性质 |
|---|---|---|
| `ImportViewModel.importVideos` | 增加结构化返回值 `ImportReport`（成功/跳过重复/失败+原因），标 `@discardableResult` | 纯加法，UI 调用点不改 |
| `ImportViewModel.deleteVideo` | 把"立即提交删除"闭包抽成 `commitDeleteVideo(_:from:)` 独立方法，UI 的 PendingDeletionCenter 撤销路径继续调它 | 等价重构（行为不变） |
| `MixCutApp` | init/onAppear 里按设置启动 `MCPServer` | 纯加法 |
| `SettingsView` | 新增 Agent 接入区块 | 纯加法 |

## 工具清单（9 个）

所有工具结果为结构化 JSON 文本；字段名英文稳定命名，人读文案（错误说明等）中文。

### 只读（4 个）

| 工具 | 入参 | 返回 |
|---|---|---|
| `list_projects` | 无 | `[{id, name, status, video_count, segment_count, scheme_count, updated_at}]` |
| `get_project` | `project_id` | 项目详情 + `videos: [{id, name, status, duration_sec, error_message, segment_count}]` |
| `list_segments` | `project_id` 或 `video_id`（二选一必填，同时提供报 `INVALID_ARGUMENT`）；可选 `semantic_type`、`position_type` 过滤 | `[{id, segment_index, video_id, video_name, start_frame, end_frame, start_sec, end_sec, duration_sec, text, semantic_types, position_type, confidence, quality_score}]` |
| `get_job` | `job_id` | `{id, kind, state, started_at, finished_at, videos: [{video_id, name, status, error_message}], report}`；videos 状态**实时读 SwiftData**，不是缓存快照 |

### 写（5 个）

| 工具 | 入参 | 返回 | 说明 |
|---|---|---|---|
| `create_project` | `name` | `{id, name}` | 同步 |
| `import_videos` | `project_id, paths[]`（绝对路径） | `{job_id}` | 校验路径存在可读后立即返回，后台 Task 跑完整 8 步流水线 |
| `retry_analysis` | `video_id` | `{job_id}` | 复用现有 `retryAIAnalysis`，job 模型 |
| `retry_asr` | `video_id` | `{job_id}` | 复用现有 `retryASR`，job 模型 |
| `remove_video` | `project_id, video_id` | `{removed, video_deleted_globally}` | 走立即提交路径，不进 UI 撤销浮条；若视频仍被其他项目引用则只解除关联（沿用现有全局共享语义） |

## 错误处理

- **协议层**：标准 JSON-RPC 错误码（-32700 解析失败 / -32600 无效请求 / -32601 方法不存在 / -32602 参数无效）。
- **工具层**：MCP `tools/call` 结果带 `isError: true`，content 为 `{code, message}`：
  `INVALID_ARGUMENT` / `PROJECT_NOT_FOUND` / `VIDEO_NOT_FOUND` / `JOB_NOT_FOUND` /
  `FILE_NOT_FOUND`（含具体是哪个路径）/ `JOB_ALREADY_RUNNING`（含当前 job_id）。
- **输入校验**（系统边界，全部前置）：UUID 可解析且实体存在；路径为绝对路径、存在、可读；
  `paths` 非空数组。校验失败立即返回，不产生半成品状态。
- 流水线内部的失败沿用现有机制（`video.status = .failed` + `errorMessage`），通过
  `get_job`/`get_project` 结构化透出，不吞。

## 安全

- 只绑定 `127.0.0.1`，仅本机进程可访问；第一阶段不做鉴权（威胁模型：单人开发机）。
- 不在任何工具返回值中包含 API Key 等敏感配置。
- 路径入参仅用于读取导入源文件，不提供任意文件读写工具。

## 测试与验收

1. **单元测试（TDD，`Tests/MixCutCoreTests/MCPProtocolTests.swift`）**：
   JSON-RPC 解析（含畸形输入）、五个 MCP 方法路由、tools/list 输出 schema、
   tools/call 参数校验与错误编码。
2. **集成自测（curl 脚本 `scripts/mcp_smoke_test.sh`）**：app 跑起来后依次
   initialize → tools/list → create_project → import_videos（用仓库外的小视频）→
   轮询 get_job → list_segments → remove_video，断言 JSON 结构。
3. **真实验收**：Claude Code `claude mcp add` 注册后跑完整验收场景。
4. **回归（铁律）**：UI 手动导入一组视频走完流水线，确认原有导入/删除/撤销/Toast 行为不变；
   切换项目联动正常。

## 已知限制（记录，不在本阶段解决）

- UI 与 MCP 各持一个 `ImportViewModel`，`cancelledVideoIDs` 不互通：Agent 导入进行中时，
  用户在 UI 删同一视频不会取消 Agent 侧任务（反之亦然）。
- job 不持久化，app 重启后 `get_job` 返回 `JOB_NOT_FOUND`，需 Agent 改查 `get_project`。
- 无鉴权，本机任何进程可调用（威胁模型为单人开发机，第二阶段再评估 token）。
- 不支持 MCP 通知推送，进度靠轮询 `get_job`。
