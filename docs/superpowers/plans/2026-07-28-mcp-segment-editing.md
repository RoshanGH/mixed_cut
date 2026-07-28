# MCP 分镜修改能力实施计划（Agent 第二阶段）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给内嵌 MCP server 增加 9 个分镜修改工具（改标签/调边界/字幕模式/保留原声/变体参与/生成变体/删分镜/自选组合/导出分镜）+ 视频·分镜编号寻址，实现 Agent 与分镜库 UI 能力对等。

**Architecture:** 工具定义与 serverInstructions 在 MixCutCore（TDD）；寻址解析与 9 个 handler 放新文件 `MCPSegmentToolHandlers.swift`（MCPToolHandlers 的 extension，避免主文件超 800 行）；写库复用既有模型 API 与 headless VM（SegmentLibraryViewModel 调边界、SchemeViewModel 自定义组合、DubbingViewModel 配音），与 UI 走同一套副作用链。

**Tech Stack:** Swift 5.10 / SwiftData / Swift Testing。零第三方依赖。

**Spec:** `docs/superpowers/specs/2026-07-28-mcp-segment-editing-design.md`

## Global Constraints

- 分支 `feature/mcp-server-phase1` 直接续做；**版本号保持 0.9.2 不动**（版本号以发版为准）
- 字幕三档只认「直接烧录 / 模糊虚化 / 纯色遮挡」，serverInstructions 必须写明"用户用词含糊时报出三档名称请其确认，不得猜测"
- 配音过期只提醒不自动重生成；无配音的分镜改边界不出提醒
- 视频编号 = `ProjectVideo.addedAt` 升序 1-based；分镜编号 = 视频内 `startFrame` 升序 1-based
- 禁止直写 `semanticTypesData`（必须走 `segment.semanticTypes =`）；帧修改必须走 `segment.setFrameRange`
- 所有写操作 safeSave + 批量结束统一 `Self.notifyUIReload()` 一次
- 编译 `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build`；Core 测试 `swift test`；新 app 文件用 `add_to_pbxproj.py`（scratchpad）登记
- commit 中文 conventional commits，无 attribution

---

### Task 1: MixCutCore — 9 个工具定义 + 新错误码 + serverInstructions 升级（TDD）

**Files:**
- Modify: `Sources/MixCutCore/AgentToolCatalog.swift`
- Test: `Tests/MixCutCoreTests/AgentToolCatalogTests.swift`、`Tests/MixCutCoreTests/MCPProtocolTests.swift`

**Interfaces:**
- Produces: `AgentToolCatalog.all` 共 22 个工具（顺序见测试）；`AgentToolErrorCode` 新增 `.segmentNotFound = "SEGMENT_NOT_FOUND"`、`.schemeNotFound = "SCHEME_NOT_FOUND"`；`AgentToolCatalog.serverInstructions` 含寻址约定/字幕三档/全局共享警告/配音过期说明
- 共用 selector schema 片段（下述 `SELECTOR_PROPS`）：`project_id`(string)、`video_no`(integer)、`segment_nos`(int array)、`segment_ids`(string array)

- [ ] **Step 1: 更新测试**（AgentToolCatalogTests.swift 中替换 `allTools`，新增两个测试）

```swift
    @Test("22 个工具且命名齐全")
    func allTools() {
        let names = AgentToolCatalog.all.map(\.name)
        #expect(names == [
            "list_projects", "get_project", "list_segments", "list_schemes", "get_job",
            "create_project", "import_videos", "retry_analysis", "retry_asr", "remove_video",
            "generate_schemes", "export_scheme", "delete_project",
            "update_segment_tags", "adjust_segment_boundary", "set_subtitle_mode",
            "set_voice_keep_original", "set_dub_participation", "generate_voice_variants",
            "delete_segments", "create_custom_scheme", "export_segments",
        ])
    }

    @Test("分镜工具的 selector 参数齐全")
    func segmentSelectorSchema() throws {
        for name in ["update_segment_tags", "adjust_segment_boundary", "set_subtitle_mode",
                     "set_voice_keep_original", "set_dub_participation", "generate_voice_variants",
                     "delete_segments", "export_segments"] {
            let tool = try #require(AgentToolCatalog.all.first { $0.name == name })
            let obj = try #require(JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8)) as? [String: Any])
            let props = try #require(obj["properties"] as? [String: Any])
            for key in ["project_id", "video_no", "segment_nos", "segment_ids"] {
                #expect(props[key] != nil, "\(name) 缺 \(key)")
            }
        }
    }

    @Test("set_subtitle_mode 只认三档中文枚举")
    func subtitleModeEnum() throws {
        let tool = try #require(AgentToolCatalog.all.first { $0.name == "set_subtitle_mode" })
        let obj = try #require(JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8)) as? [String: Any])
        let props = try #require(obj["properties"] as? [String: Any])
        let mode = try #require(props["mode"] as? [String: Any])
        #expect(mode["enum"] as? [String] == ["直接烧录", "模糊虚化", "纯色遮挡"])
    }

    @Test("delete_segments 带 destructiveHint")
    func deleteSegmentsAnnotation() throws {
        let tool = try #require(AgentToolCatalog.all.first { $0.name == "delete_segments" })
        let json = try #require(tool.annotationsJSON)
        let obj = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(obj["destructiveHint"] as? Bool == true)
    }
```

MCPProtocolTests.swift 的 `serverInstructionsContent` 替换为：

```swift
    @Test("serverInstructions 含 MC 简写/寻址约定/字幕三档/含糊必须反问")
    func serverInstructionsContent() {
        let text = AgentToolCatalog.serverInstructions
        #expect(text.contains("MC"))
        #expect(text.contains("video_no"))
        #expect(text.contains("直接烧录") && text.contains("模糊虚化") && text.contains("纯色遮挡"))
        #expect(text.contains("反问") || text.contains("确认"))
        #expect(text.contains("全局"))
        #expect(text.contains("confirm"))
    }
```

- [ ] **Step 2: 跑测试确认失败**：`swift test --filter AgentToolCatalog 2>&1 | tail -3` → FAIL

- [ ] **Step 3: 实现**。`AgentToolErrorCode` 加两个 case：

```swift
    case segmentNotFound = "SEGMENT_NOT_FOUND"
    case schemeNotFound = "SCHEME_NOT_FOUND"
```

`AgentToolCatalog.all` 末尾追加 9 个定义（selector 四参数每个工具原样重复，JSON 无法复用变量就复制）。selector 属性片段（嵌入各 schema 的 properties）：

```json
"project_id":{"type":"string","description":"项目 UUID（与 video_no/segment_nos 配合使用）"},
"video_no":{"type":"integer","description":"视频编号：项目内按导入顺序 1 起"},
"segment_nos":{"type":"array","items":{"type":"integer"},"description":"分镜编号数组：视频内按时间顺序 1 起，如 [3,4,5]"},
"segment_ids":{"type":"array","items":{"type":"string"},"description":"分镜 UUID 数组（与编号方式二选一）"}
```

9 个工具（description 全文照抄，annotations：delete_segments 为 destructive，其余写类为 `{"readOnlyHint":false,"destructiveHint":false}`）：

| name | description | 额外参数（加在 selector 之后） | required |
|---|---|---|---|
| update_segment_tags | 批量修改分镜标签。add/remove/set_semantic_types 三选一（11 种：噱头引入/痛点/产品方案/效果展示/信任背书/价格对比/活动福利/行动号召/产品定位/产品使用教育/过渡），可同时设 position_type（开头/中间/结尾）。每个分镜至少保留 1 个语义类型 | `add_semantic_types`/`remove_semantic_types`/`set_semantic_types`(string array)、`position_type`(string) | [] |
| adjust_segment_boundary | 按帧批量调整分镜边界（start_delta_frames/end_delta_frames 可负；绝对值 start_frame/end_frame 仅单分镜可用）。自动重配台词与缩略图。⚠️ 已生成配音的分镜会返回 stale_dubs 提醒（配音按旧时长合成，导出会静默用旧音频），是否重新生成由用户决定 | `start_delta_frames`/`end_delta_frames`/`start_frame`/`end_frame`(integer) | [] |
| set_subtitle_mode | 设置字幕处理模式，只认三档：直接烧录（新字幕直接叠加）/模糊虚化（原字幕区域模糊后烧新字幕）/纯色遮挡（色块盖住原字幕再烧新字幕）。用户用词含糊时必须报出三档名称请其确认。可同时设字号 font_ratio（0.030-0.085）与遮挡区域 mask_y/mask_height（0-1）。保留原声的分镜自动跳过 | `mode`(enum 三档)、`font_ratio`(number)、`mask_y`(number)、`mask_height`(number) | ["mode"] |
| set_voice_keep_original | 设置保留原声开关：开=不改写不配音、导出不加字幕。可选设置原声是否参与导出组合 | `keep_original`(boolean)、`original_in_combination`(boolean) | ["keep_original"] |
| set_dub_participation | 设置指定声音变体是否参与导出组合（对应 UI 变体面板勾选） | `variant_indexes`(int array)、`participates`(boolean) | ["variant_indexes","participates"] |
| generate_voice_variants | 为分镜生成声音变体：自动克隆原声→AI 改写 K 套→合成配音→字幕对齐（与 UI 一键改写同流程）。需要千问 API Key。返回 job_id 轮询 | 无额外 | [] |
| delete_segments | 批量删除分镜（立即生效，无撤销）。级联删除其配音变体与方案槽位记录，结果列出受影响的方案 | 无额外 | [] |
| create_custom_scheme | 跨视频自选分镜按顺序组成方案（进"自定义组合"分组），之后可用 export_scheme 导出。segments 为有序数组，每项 {video_no, segment_no} 或 {segment_id} | `name`(string 可选)、`segments`(array of object{video_no,segment_no,segment_id}) | ["project_id","segments"] |
| export_segments | 批量导出分镜片段为独立 mp4 到指定目录（命名规则与 UI 批量导出一致）。返回 job_id 轮询 | `output_dir`(string) | ["output_dir"] |

`serverInstructions` 替换为（全文）：

```
MixCut（用户常用简写：MC）是一款 macOS 端 AI 视频混剪应用，面向广告投放团队。用户说「MC」「混剪工具」时即指本服务。

寻址约定：视频用 video_no（项目内按导入顺序 1 起），分镜用 segment_nos（视频内按时间顺序 1 起，与 UI 卡片 # 编号一致）。用户说「1 号视频的 3~8 号分镜」即 video_no=1, segment_nos=[3,4,5,6,7,8]。先 get_project / list_segments 查看编号再操作。

核心工作流：
1. 导入分析：create_project → import_videos（返回 job_id）→ get_job 轮询 → list_segments 查看分镜，失败用 retry_analysis / retry_asr。
2. 分镜修改：update_segment_tags 改标签；adjust_segment_boundary 按帧调边界；set_subtitle_mode 设字幕；set_voice_keep_original 保留原声；generate_voice_variants 生成声音变体（job）；delete_segments 删分镜。
3. 组合与导出：generate_schemes AI 生成方案（job）；create_custom_scheme 自选分镜组方案；export_scheme 导出方案成片（job）；export_segments 导出分镜片段（job）。

重要规则：
- 字幕只有三档：「直接烧录」「模糊虚化」「纯色遮挡」。用户用词含糊（如"直接收录"）时，必须报出这三个名称请用户确认，不得自行猜测。
- 分镜是全局共享的：修改/删除分镜会影响所有引用同一视频的项目，涉及多项目时先告知用户。
- adjust_segment_boundary 返回 stale_dubs 时，表示这些分镜已生成的配音按旧时长合成、导出会静默用旧音频；只提醒用户，是否重新生成（generate_voice_variants）由用户决定，不要自作主张重跑。
- 同一时间只允许一个异步任务（JOB_ALREADY_RUNNING）；app 重启后 job 丢失（JOB_NOT_FOUND），改查 get_project。
- delete_project 必须两步：先不带 confirm 拿影响预览给用户确认，再 confirm=true 执行。delete_segments / remove_video 立即生效无撤销。
```

- [ ] **Step 4: 跑测试确认通过**：`swift test 2>&1 | tail -1` → 全 PASS
- [ ] **Step 5: Commit**：`git add Sources/MixCutCore/AgentToolCatalog.swift Tests/MixCutCoreTests/ && git commit -m "feat: 分镜修改 9 工具定义+编号寻址说明+字幕三档规则（TDD）"`

---

### Task 2: App — 寻址解析 + get_project/list_segments 升级

**Files:**
- Create: `MixCut/Services/MCP/MCPSegmentToolHandlers.swift`（extension MCPToolHandlers）
- Modify: `MixCut/Services/MCP/MCPToolHandlers.swift`（getProject/listSegments/videoSummary）

**Interfaces:**
- Produces（Task 3-6 依赖）:
  - `struct SelectorArgs: Decodable`（project_id/video_no/segment_nos/segment_ids，全 optional）
  - `func resolveSegments(_ sel: SelectorArgs) throws -> [Segment]`（all-or-nothing，缺失报 SEGMENT_NOT_FOUND）
  - `static func orderedVideos(of project: Project) -> [Video]`（addedAt 升序）
  - `static func orderedSegments(of video: Video) -> [Segment]`（startFrame 升序）
  - `static func subtitleModeName(of segment: Segment) -> String`（三档中文名）

- [ ] **Step 1: 建 `MCPSegmentToolHandlers.swift`（先只放寻址与辅助）**

```swift
import Foundation
import SwiftData

// MARK: - 分镜修改工具（第二阶段）：寻址解析与 9 个 handler
extension MCPToolHandlers {
    struct SelectorArgs: Decodable {
        let project_id: String?
        let video_no: Int?
        let segment_nos: [Int]?
        let segment_ids: [String]?
    }

    static func orderedVideos(of project: Project) -> [Video] {
        project.projectVideos
            .sorted { $0.addedAt < $1.addedAt }
            .compactMap(\.video)
    }

    static func orderedSegments(of video: Video) -> [Segment] {
        video.segments.sorted { $0.startFrame < $1.startFrame }
    }

    /// 三档中文名：直接烧录 / 模糊虚化 / 纯色遮挡（与 SubtitleTreatment 对齐）
    static func subtitleModeName(of segment: Segment) -> String {
        guard segment.hasHardSubtitle else { return "直接烧录" }
        switch segment.maskStyle {
        case .solid: return "纯色遮挡"
        default: return "模糊虚化"   // blur 与旧 dim 统一归模糊（与 SubtitleTreatment.from 口径一致）
        }
    }

    /// all-or-nothing 定位：全部找到才返回，否则整个调用不执行
    func resolveSegments(_ sel: SelectorArgs) throws -> [Segment] {
        if let ids = sel.segment_ids, !ids.isEmpty {
            var result: [Segment] = []
            var missing: [String] = []
            for idString in ids {
                guard let uuid = UUID(uuidString: idString) else {
                    throw toolFailure(.invalidArgument, "segment_id 不是合法 UUID：\(idString)")
                }
                let descriptor = FetchDescriptor<Segment>(predicate: #Predicate { $0.id == uuid })
                if let seg = try? contextForTools.fetch(descriptor).first { result.append(seg) }
                else { missing.append(idString) }
            }
            guard missing.isEmpty else {
                throw toolFailure(.segmentNotFound, "找不到分镜：\(missing.joined(separator: "、"))")
            }
            return result
        }
        guard let pid = sel.project_id, let vno = sel.video_no,
              let nos = sel.segment_nos, !nos.isEmpty else {
            throw toolFailure(.invalidArgument, "必须提供 segment_ids，或 project_id + video_no + segment_nos")
        }
        let project = try fetchProjectShared(pid)
        let videos = Self.orderedVideos(of: project)
        guard vno >= 1, vno <= videos.count else {
            throw toolFailure(.videoNotFound, "video_no \(vno) 超出范围（项目共 \(videos.count) 个视频）")
        }
        let ordered = Self.orderedSegments(of: videos[vno - 1])
        let missing = nos.filter { $0 < 1 || $0 > ordered.count }
        guard missing.isEmpty else {
            throw toolFailure(.segmentNotFound,
                "视频 \(vno) 共 \(ordered.count) 个分镜，找不到编号：\(missing.map(String.init).joined(separator: "、"))")
        }
        return nos.map { ordered[$0 - 1] }
    }
}
```

注意：extension 无法访问 `private` 成员——把主文件里 `ToolFailure`/`context`/`fetchProject` 的访问打通：
在 `MCPToolHandlers.swift` 中把 `private struct ToolFailure` 改为 `struct ToolFailure: Error`（去 private），
`private let context` 改 `let context`，并加两个便捷方法（放主文件 `// MARK: - 公共辅助`）：

```swift
    var contextForTools: ModelContext { context }
    func toolFailure(_ code: AgentToolErrorCode, _ message: String) -> ToolFailure {
        ToolFailure(code: code, message: message)
    }
    func fetchProjectShared(_ idString: String) throws -> Project { try fetchProject(idString) }
```

（`fetchProject` 保持 private，透出壳即可；如 extension 同文件可见性允许直接用则省掉壳——实现时以编译器为准，能删就删。）

- [ ] **Step 2: getProject 升级**（videos 排序 + video_no）。`getProject` 中 `"videos": project.videos.map(Self.videoSummary)` 改为：

```swift
            "videos": Self.orderedVideos(of: project).enumerated().map { idx, video in
                var summary = Self.videoSummary(video)
                summary["video_no"] = idx + 1
                return summary
            },
```

（`videoSummary` 返回类型已是 `[String: Any]`，直接可变。）

- [ ] **Step 3: listSegments 升级**。构造 items 的循环改为（每视频先算编号表，新增 6 个字段）：

```swift
        var items: [[String: Any]] = []
        for video in videos {
            let sorted = Self.orderedSegments(of: video)
            for (idx, seg) in sorted.enumerated() {
                let types = seg.semanticTypes.map(\.rawValue)
                if let filter = args.semantic_type, !types.contains(filter) { continue }
                if let filter = args.position_type, seg.positionType.rawValue != filter { continue }
                let variants = seg.effectiveDubVariants
                let hasStale = variants.contains { dub in
                    let snap = DubSnapshot(recordedStartFrame: dub.generatedForStartFrame,
                                           recordedEndFrame: dub.generatedForEndFrame,
                                           recordedTextHash: dub.generatedForTextHash)
                    if case .stale = DubStaleness.check(
                        snapshot: snap,
                        currentStartFrame: seg.startFrame, currentEndFrame: seg.endFrame,
                        currentTextHash: DubStaleness.textHash(of: dub.rewrittenText)) { return true }
                    return false
                }
                items.append([
                    "id": seg.id.uuidString,
                    "segment_no": idx + 1,
                    "segment_index": seg.segmentIndex,
                    "video_id": video.id.uuidString,
                    "video_name": video.name,
                    "start_frame": seg.startFrame,
                    "end_frame": seg.endFrame,
                    "start_sec": seg.startTime,
                    "end_sec": seg.endTime,
                    "duration_sec": seg.duration,
                    "text": seg.text,
                    "semantic_types": types,
                    "position_type": seg.positionType.rawValue,
                    "confidence": seg.confidence,
                    "quality_score": seg.qualityScore,
                    "is_voice_locked": seg.isVoiceLocked,
                    "subtitle_mode": Self.subtitleModeName(of: seg),
                    "font_ratio": seg.subtitleFontRatio,
                    "voice_variant_count": variants.count,
                    "has_stale_dubs": hasStale,
                ])
            }
        }
```

- [ ] **Step 4: pbxproj 登记 + 编译**：`python3 <scratchpad>/add_to_pbxproj.py MixCut/Services/MCP/MCPSegmentToolHandlers.swift` → `xcodebuild ... Debug build` → BUILD SUCCEEDED
- [ ] **Step 5: 重启 app，curl 验证**：`get_project`（滴露1）出现 video_no；`list_segments` 出现 segment_no/subtitle_mode 等新字段
- [ ] **Step 6: Commit**：`git add -A && git commit -m "feat: 分镜编号寻址解析 + get_project/list_segments 返回编号与字幕/配音状态"`

---

### Task 3: App — 四个纯数据写工具（标签/字幕模式/保留原声/变体参与）

**Files:**
- Modify: `MixCut/Services/MCP/MCPSegmentToolHandlers.swift`（追加 4 个 handler）
- Modify: `MixCut/Services/MCP/MCPToolHandlers.swift`（call switch 加 4 个 case）

**Interfaces:**
- Consumes: `resolveSegments`、`toolFailure`、`AgentJSON`、`notifyUIReload`
- Produces: `updateSegmentTags(_:)`、`setSubtitleMode(_:)`、`setVoiceKeepOriginal(_:)`、`setDubParticipation(_:)`（均 `(Data) throws -> Outcome`）

- [ ] **Step 1: call switch 追加**（主文件）：

```swift
            case "update_segment_tags": return try updateSegmentTags(argumentsData)
            case "adjust_segment_boundary": return try adjustSegmentBoundary(argumentsData)
            case "set_subtitle_mode": return try setSubtitleMode(argumentsData)
            case "set_voice_keep_original": return try setVoiceKeepOriginal(argumentsData)
            case "set_dub_participation": return try setDubParticipation(argumentsData)
            case "generate_voice_variants": return try generateVoiceVariants(argumentsData)
            case "delete_segments": return try deleteSegments(argumentsData)
            case "create_custom_scheme": return try createCustomScheme(argumentsData)
            case "export_segments": return try exportSegments(argumentsData)
```

（本 Task 只实现前 1、3、4、5 个；其余在 Task 4-6，先写空实现会编译不过——**按 Task 顺序逐个加 case**，每个 Task 只加自己实现的。）

- [ ] **Step 2: updateSegmentTags 实现**

```swift
    struct UpdateTagsArgs: Decodable {
        let project_id: String?; let video_no: Int?
        let segment_nos: [Int]?; let segment_ids: [String]?
        let add_semantic_types: [String]?
        let remove_semantic_types: [String]?
        let set_semantic_types: [String]?
        let position_type: String?
    }

    func updateSegmentTags(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(UpdateTagsArgs.self, from: data)
        let segments = try resolveSegments(SelectorArgs(
            project_id: args.project_id, video_no: args.video_no,
            segment_nos: args.segment_nos, segment_ids: args.segment_ids))
        let opCount = [args.add_semantic_types, args.remove_semantic_types, args.set_semantic_types]
            .compactMap { $0 }.count
        guard opCount <= 1 else {
            throw toolFailure(.invalidArgument, "add/remove/set_semantic_types 只能提供一个")
        }
        guard opCount == 1 || args.position_type != nil else {
            throw toolFailure(.invalidArgument, "至少提供一种修改：语义类型或 position_type")
        }
        func parseTypes(_ raw: [String]) throws -> [SemanticType] {
            try raw.map {
                guard let t = SemanticType(rawValue: $0) else {
                    throw toolFailure(.invalidArgument,
                        "非法语义类型「\($0)」，合法值：\(SemanticType.allCases.map(\.rawValue).joined(separator: "、"))")
                }
                return t
            }
        }
        var position: PositionType?
        if let p = args.position_type {
            guard let parsed = PositionType(rawValue: p) else {
                throw toolFailure(.invalidArgument, "非法位置「\(p)」，合法值：开头、中间、结尾")
            }
            position = parsed
        }
        var results: [[String: Any]] = []
        for seg in segments {
            var note = "已修改"
            if let add = args.add_semantic_types {
                let types = try parseTypes(add)
                var current = seg.semanticTypes
                for t in types where !current.contains(t) { current.append(t) }
                seg.semanticTypes = current
            } else if let remove = args.remove_semantic_types {
                let types = try parseTypes(remove)
                let remaining = seg.semanticTypes.filter { !types.contains($0) }
                if remaining.isEmpty { note = "跳过：至少要保留 1 个语义类型" }
                else { seg.semanticTypes = remaining }
            } else if let set = args.set_semantic_types {
                let types = try parseTypes(set)
                if types.isEmpty { note = "跳过：至少要保留 1 个语义类型" }
                else { seg.semanticTypes = types }
            }
            if let position { seg.positionType = position }
            results.append(["segment_index": seg.segmentIndex, "note": note,
                            "semantic_types": seg.semanticTypes.map(\.rawValue),
                            "position_type": seg.positionType.rawValue])
        }
        context.safeSave()
        Self.notifyUIReload()
        return success(["results": results])
    }
```

（若 `notifyUIReload`/`success` 因 private 不可见，同 Task 2 方式在主文件加 internal 壳：`func toolSuccess(...)`。实现时以编译器为准，本计划后续代码统一按可见的写。）

- [ ] **Step 3: setSubtitleMode 实现**

```swift
    struct SubtitleModeArgs: Decodable {
        let project_id: String?; let video_no: Int?
        let segment_nos: [Int]?; let segment_ids: [String]?
        let mode: String
        let font_ratio: Double?
        let mask_y: Double?
        let mask_height: Double?
    }

    func setSubtitleMode(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(SubtitleModeArgs.self, from: data)
        let segments = try resolveSegments(SelectorArgs(
            project_id: args.project_id, video_no: args.video_no,
            segment_nos: args.segment_nos, segment_ids: args.segment_ids))
        guard ["直接烧录", "模糊虚化", "纯色遮挡"].contains(args.mode) else {
            throw toolFailure(.invalidArgument, "mode 只认三档：直接烧录、模糊虚化、纯色遮挡")
        }
        var results: [[String: Any]] = []
        for seg in segments {
            if seg.isVoiceLocked {
                results.append(["segment_index": seg.segmentIndex, "note": "已跳过（保留原声，不加字幕）"])
                continue
            }
            switch args.mode {
            case "直接烧录": seg.hasHardSubtitle = false
            case "模糊虚化": seg.hasHardSubtitle = true; seg.maskStyle = .blur
            default: seg.hasHardSubtitle = true; seg.maskStyle = .solid
            }
            if let ratio = args.font_ratio {
                let clamped = SubtitleFontSize.clamp(ratio)
                seg.subtitleFontRatio = clamped
                SubtitleFontSize.rememberPreferred(clamped)
            }
            if args.mask_y != nil || args.mask_height != nil {
                var rect = seg.maskRect
                if let y = args.mask_y { rect.y = y }
                if let h = args.mask_height { rect.height = h }
                seg.maskRect = rect   // setter 自带 clamped()
            }
            results.append(["segment_index": seg.segmentIndex, "note": "已修改",
                            "subtitle_mode": Self.subtitleModeName(of: seg),
                            "font_ratio": seg.subtitleFontRatio])
        }
        context.safeSave()
        Self.notifyUIReload()
        return success(["results": results])
    }
```

（`SubtitleMaskRect` 的字段名以 `Sources/MixCutCore/SubtitleMaskRect.swift` 实际为准——若是 `y/height` 直接如上；若带前缀改之。）

- [ ] **Step 4: setVoiceKeepOriginal + setDubParticipation 实现**

```swift
    struct VoiceKeepArgs: Decodable {
        let project_id: String?; let video_no: Int?
        let segment_nos: [Int]?; let segment_ids: [String]?
        let keep_original: Bool
        let original_in_combination: Bool?
    }

    func setVoiceKeepOriginal(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(VoiceKeepArgs.self, from: data)
        let segments = try resolveSegments(SelectorArgs(
            project_id: args.project_id, video_no: args.video_no,
            segment_nos: args.segment_nos, segment_ids: args.segment_ids))
        for seg in segments {
            seg.isVoiceLocked = args.keep_original
            if let flag = args.original_in_combination {
                seg.originalParticipatesInCombination = flag
            }
        }
        context.safeSave()
        Self.notifyUIReload()
        return success(["updated": segments.count, "keep_original": args.keep_original])
    }

    struct DubParticipationArgs: Decodable {
        let project_id: String?; let video_no: Int?
        let segment_nos: [Int]?; let segment_ids: [String]?
        let variant_indexes: [Int]
        let participates: Bool
    }

    func setDubParticipation(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(DubParticipationArgs.self, from: data)
        let segments = try resolveSegments(SelectorArgs(
            project_id: args.project_id, video_no: args.video_no,
            segment_nos: args.segment_nos, segment_ids: args.segment_ids))
        var results: [[String: Any]] = []
        for seg in segments {
            let variants = seg.effectiveDubVariants
            var touched: [Int] = []
            var missing: [Int] = []
            for idx in args.variant_indexes {
                let matches = variants.filter { $0.textVariantIndex == idx }
                if matches.isEmpty { missing.append(idx) }
                else { matches.forEach { $0.participatesInCombination = args.participates }; touched.append(idx) }
            }
            results.append(["segment_index": seg.segmentIndex,
                            "updated_variants": touched, "missing_variants": missing])
        }
        context.safeSave()
        Self.notifyUIReload()
        return success(["results": results, "participates": args.participates])
    }
```

- [ ] **Step 5: 编译 + 重启 + curl 实测**（滴露1 视频1 的 1-2 号分镜）：加标签「痛点」→ list_segments 验证；改回。设 `模糊虚化`+font_ratio 0.06 → 验证 subtitle_mode/font_ratio 变化；保留原声开→关。UI 截图确认分镜卡片标签变化实时可见。
- [ ] **Step 6: Commit**：`git commit -m "feat: 分镜标签/字幕模式/保留原声/变体参与四个批量写工具"`

---

### Task 4: App — adjust_segment_boundary（含配音过期提醒）

**Files:**
- Modify: `MixCut/Services/MCP/MCPSegmentToolHandlers.swift`
- Modify: `MixCut/ViewModels/SegmentLibraryViewModel.swift`（仅当 `reExtractText`/`regenStartThumbnail` 为 private 时去掉 private，不改任何逻辑）
- Modify: `MixCut/Services/MCP/AgentGateway.swift`（AgentGateway 增 headless `segmentLibVM`，注入 MCPToolHandlers）

**Interfaces:**
- Consumes: `SegmentLibraryViewModel.setStartFrame(for:to:)/setEndFrame(for:to:)`（含 clamp+reExtractText+debounce 缩略图+save）、`DubSnapshot`/`DubStaleness`/`FrameTime`
- Produces: `adjustSegmentBoundary(_:)`；MCPToolHandlers init 增参 `segmentLibVM: SegmentLibraryViewModel`

- [ ] **Step 1: AgentGateway 装配 headless SegmentLibraryViewModel**：`AgentGateway.configure` 里创建 `let segLibVM = SegmentLibraryViewModel(); segLibVM.setModelContext(container.mainContext)`，`MCPToolHandlers.init` 增加 `segmentLibVM:` 参数并存为 `let segmentLibVM: SegmentLibraryViewModel`（internal，extension 要用）。

- [ ] **Step 2: handler 实现**

```swift
    struct BoundaryArgs: Decodable {
        let project_id: String?; let video_no: Int?
        let segment_nos: [Int]?; let segment_ids: [String]?
        let start_delta_frames: Int?
        let end_delta_frames: Int?
        let start_frame: Int?
        let end_frame: Int?
    }

    func adjustSegmentBoundary(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(BoundaryArgs.self, from: data)
        let segments = try resolveSegments(SelectorArgs(
            project_id: args.project_id, video_no: args.video_no,
            segment_nos: args.segment_nos, segment_ids: args.segment_ids))
        let hasDelta = args.start_delta_frames != nil || args.end_delta_frames != nil
        let hasAbsolute = args.start_frame != nil || args.end_frame != nil
        guard hasDelta || hasAbsolute else {
            throw toolFailure(.invalidArgument, "必须提供 delta（start/end_delta_frames）或绝对值（start/end_frame）")
        }
        guard !(hasDelta && hasAbsolute) else {
            throw toolFailure(.invalidArgument, "delta 与绝对值不能混用")
        }
        if hasAbsolute && segments.count > 1 {
            throw toolFailure(.invalidArgument, "绝对帧值只支持单个分镜，批量请用 delta")
        }
        var results: [[String: Any]] = []
        var staleDubs: [[String: Any]] = []
        for seg in segments {
            guard let video = seg.video, video.fps > 0 else {
                results.append(["segment_index": seg.segmentIndex, "note": "跳过：视频帧率缺失"])
                continue
            }
            let fps = video.fps
            let maxFrame = FrameTime.frame(seconds: video.duration, fps: fps)
            var targetStart = args.start_frame ?? (seg.startFrame + (args.start_delta_frames ?? 0))
            var targetEnd = args.end_frame ?? (seg.endFrame + (args.end_delta_frames ?? 0))
            // 与 UI 相同的钳制：0 ≤ start，end ≤ 视频总帧，最短 2 帧（先 clamp end 再保下限）
            targetEnd = min(maxFrame, targetEnd)
            targetStart = max(0, targetStart)
            if targetEnd < targetStart + 2 { targetEnd = min(maxFrame, targetStart + 2) }
            if targetStart > targetEnd - 2 { targetStart = max(0, targetEnd - 2) }
            let oldStart = seg.startFrame, oldEnd = seg.endFrame
            // 走 UI 同一路径（clamp/reExtractText/save/起点缩略图重生都在里面）
            if targetStart != oldStart { segmentLibVM.setStartFrame(for: seg, to: targetStart) }
            if targetEnd != oldEnd { segmentLibVM.setEndFrame(for: seg, to: targetEnd) }
            results.append([
                "segment_index": seg.segmentIndex,
                "start_frame": ["old": oldStart, "new": seg.startFrame],
                "end_frame": ["old": oldEnd, "new": seg.endFrame],
                "duration_sec": seg.duration,
                "text": seg.text,
            ])
            // 配音过期提醒（只对已生成音频的变体；没有变体的分镜不出现在提醒里）
            for dub in seg.effectiveDubVariants {
                let snap = DubSnapshot(recordedStartFrame: dub.generatedForStartFrame,
                                       recordedEndFrame: dub.generatedForEndFrame,
                                       recordedTextHash: dub.generatedForTextHash)
                if case .stale = DubStaleness.check(
                    snapshot: snap,
                    currentStartFrame: seg.startFrame, currentEndFrame: seg.endFrame,
                    currentTextHash: DubStaleness.textHash(of: dub.rewrittenText)) {
                    let oldDur = Double(dub.generatedForEndFrame - dub.generatedForStartFrame) / fps
                    staleDubs.append([
                        "segment_index": seg.segmentIndex,
                        "variant_index": dub.textVariantIndex,
                        "dub_duration_sec": (oldDur * 100).rounded() / 100,
                        "segment_duration_sec": (seg.duration * 100).rounded() / 100,
                    ])
                }
            }
        }
        Self.notifyUIReload()
        var payload: [String: Any] = ["results": results]
        if !staleDubs.isEmpty {
            payload["stale_dubs"] = staleDubs
            payload["stale_warning"] = "以上分镜已生成的配音是按旧时长合成的，与新时长不匹配，导出会静默使用旧音频。请把此情况告知用户，由用户决定是否用 generate_voice_variants 重新生成；不要自作主张重跑。"
        }
        return success(payload)
    }
```

- [ ] **Step 3: 编译 + 实测**：滴露1 视频1 的 2 号分镜 `end_delta_frames: +10` → 对比前后 list_segments 的 end_frame/duration/text 变化；再 `-10` 复原。截图确认 UI 分镜卡片时长更新。滴露1 无配音变体 → 确认结果里**没有** stale_dubs 字段（符合"没生成过就不提醒"）。
- [ ] **Step 4: Commit**：`git commit -m "feat: adjust_segment_boundary 批量帧级边界调整（UI 同路径+配音过期提醒）"`

---

### Task 5: App — delete_segments / create_custom_scheme / export_segments

**Files:**
- Modify: `MixCut/Services/MCP/MCPSegmentToolHandlers.swift`
- Modify: `MixCut/Services/MCP/AgentJobRegistry.swift`（Kind 增 `exportSegments = "export_segments"`）

**Interfaces:**
- Consumes: `SchemeViewModel.createCustomScheme(from: [Segment], in: Project) async -> MixScheme?`（headless `schemeVM` 已在 MCPToolHandlers 上）、`BatchSegmentExportService.exportAll(items:outputDirectory:onProgress:) async -> (succeeded: Int, failed: [(BatchExportItem, String)])`、`ExportDestination.validate(directory:)`
- Produces: `deleteSegments(_:)`、`createCustomScheme(_:)`、`exportSegments(_:)`

- [ ] **Step 1: deleteSegments**（立即执行版，语义对齐 UI 的 commit 闭包：先删 SchemeSegment 再删 Segment；segmentDubs/physicalShots 由 cascade 关系带走；磁盘文件交孤儿 GC）

```swift
    func deleteSegments(_ data: Data) throws -> Outcome {
        let sel = try JSONDecoder().decode(SelectorArgs.self, from: data)
        let segments = try resolveSegments(sel)
        var affectedSchemes = Set<String>()
        for seg in segments {
            for ss in Array(seg.schemeSegments) {
                if let name = ss.scheme?.name { affectedSchemes.insert(name) }
                context.delete(ss)
            }
            context.delete(seg)
        }
        context.safeSave()
        Self.notifyUIReload()
        return success([
            "deleted": segments.count,
            "affected_schemes": Array(affectedSchemes).sorted(),
            "note": affectedSchemes.isEmpty ? "无方案受影响"
                : "以上方案因分镜被删而缺少槽位，导出前请检查",
        ])
    }
```

（`SchemeSegment` 指向方案的属性名以 `MixCut/Models/SchemeSegment.swift` 为准，可能是 `scheme` 或 `mixScheme`，实现时确认。）

- [ ] **Step 2: createCustomScheme**（有序、跨视频；条目 `{segment_id}` 或 `{video_no, segment_no}`）

```swift
    struct CustomSchemeArgs: Decodable {
        struct Entry: Decodable {
            let video_no: Int?
            let segment_no: Int?
            let segment_id: String?
        }
        let project_id: String
        let name: String?
        let segments: [Entry]
    }

    func createCustomScheme(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(CustomSchemeArgs.self, from: data)
        let project = try fetchProjectShared(args.project_id)
        guard !args.segments.isEmpty else {
            throw toolFailure(.invalidArgument, "segments 不能为空")
        }
        var ordered: [Segment] = []
        for (i, entry) in args.segments.enumerated() {
            if let sid = entry.segment_id {
                ordered.append(contentsOf: try resolveSegments(SelectorArgs(
                    project_id: nil, video_no: nil, segment_nos: nil, segment_ids: [sid])))
            } else if let vno = entry.video_no, let sno = entry.segment_no {
                ordered.append(contentsOf: try resolveSegments(SelectorArgs(
                    project_id: args.project_id, video_no: vno, segment_nos: [sno], segment_ids: nil)))
            } else {
                throw toolFailure(.invalidArgument, "第 \(i + 1) 项必须提供 segment_id 或 video_no+segment_no")
            }
        }
        let vm = schemeVM
        let job = jobsRegistry // 若同步走不需要 job；createCustomScheme 内含一次 AI 元数据推断（inferMetadata 失败返回 nil 不抛错）——同步等待即可，通常 <10s
        _ = job
        return try awaitCustomScheme(vm: vm, ordered: ordered, project: project, name: args.name)
    }
```

同步桥接（handler 是同步 throws，须起 Task 等待——改为返回 job 太重；用信号量会卡 MainActor。**实现取巧**：把 `createCustomScheme` handler 案改成 async 路径：`call(name:argumentsData:)` 本身是 async 的，直接把 handler 声明为 `func createCustomScheme(_ data: Data) async throws -> Outcome` 并在 switch 用 `try await`（switch 其它 case 不变）。上面 `awaitCustomScheme` 壳去掉，直接：

```swift
        guard let scheme = await schemeVM.createCustomScheme(from: ordered, in: project) else {
            throw toolFailure(.invalidArgument, schemeVM.errorMessage ?? "自定义组合创建失败")
        }
        if let name = args.name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            scheme.name = name
        }
        context.safeSave()
        Self.notifyUIReload()
        return success([
            "scheme_id": scheme.id.uuidString,
            "name": scheme.name,
            "segment_count": scheme.segmentCount,
            "total_duration_sec": scheme.totalDuration,
        ])
```

实现前先读 `SchemeViewModel.createCustomScheme` 全文（:719-780 附近）确认：分镜顺序是否按传入数组落 position（应是）；是否已含 safeSave。

- [ ] **Step 3: exportSegments**（job 模型）

```swift
    struct ExportSegmentsArgs: Decodable {
        let project_id: String?; let video_no: Int?
        let segment_nos: [Int]?; let segment_ids: [String]?
        let output_dir: String
    }

    func exportSegments(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(ExportSegmentsArgs.self, from: data)
        let segments = try resolveSegments(SelectorArgs(
            project_id: args.project_id, video_no: args.video_no,
            segment_nos: args.segment_nos, segment_ids: args.segment_ids))
        let outputURL = URL(fileURLWithPath: args.output_dir)
        if let problem = ExportDestination.validate(directory: outputURL) {
            throw toolFailure(.invalidArgument, problem)
        }
        var items: [BatchExportItem] = []
        for seg in segments {
            guard let video = seg.video else {
                throw toolFailure(.videoNotFound, "分镜 \(seg.segmentIndex) 缺少所属视频")
            }
            let sequence = Self.orderedSegments(of: video).firstIndex { $0.id == seg.id }.map { $0 + 1 } ?? 0
            items.append(BatchExportItem(
                id: seg.id,
                sourcePath: video.localPath,
                sourceVideoName: (video.name as NSString).deletingPathExtension,
                startTime: seg.startTime,
                endTime: seg.endTime,
                sequenceNumber: sequence,
                fps: video.fps))
        }
        try ensureNoActiveJobShared()
        let projectID: UUID = segments.first?.video?.projectVideos.first?.project?.id ?? UUID()
        let job = beginJob(kind: .exportSegments, projectID: projectID)
        let exportItems = items
        Task { @MainActor in
            let service = BatchSegmentExportService()
            let (succeeded, failed) = await service.exportAll(
                items: exportItems, outputDirectory: outputURL, onProgress: { _ in })
            let summary: [String: Any] = [
                "succeeded": succeeded,
                "output_dir": outputURL.path,
                "failed": failed.map { ["name": $0.0.sourceVideoName + "_\($0.0.sequenceNumber)", "reason": $0.1] },
            ]
            self.finishJobWithResult(job.id, resultJSON: AgentJSON.encode(summary))
        }
        return success(["job_id": job.id.uuidString])
    }
```

（`ensureNoActiveJob`/`jobs.begin`/`finishWithResult` 为主文件 private——同前，在主文件加 internal 壳 `ensureNoActiveJobShared()`/`beginJob(kind:projectID:)`/`finishJobWithResult(_:resultJSON:)`；`BatchExportItem` 的成员顺序以 `BatchSegmentExportService.swift:4-12` 为准，字段还有默认值 `fps`。）

- [ ] **Step 4: 编译 + 实测**：
  - `delete_segments`：先在滴露1 用 `create_custom_scheme` 组一个 2 分镜测试方案 → 删其中 1 个分镜 → 验证 affected_schemes 里列出该方案 → 删掉测试方案（delete 不了方案？用 UI？——**注**：无 delete_scheme 工具，测试改用「123」项目的分镜做删除，不建方案，或删完让用户 UI 里清理；实测优先用无方案引用的分镜）
  - `create_custom_scheme`：滴露1「1号视频 1、2 号 + 2号视频 1 号」→ list_schemes 验证出现在"自定义组合"组、顺序正确 → export_scheme 导出验证能出片 → 结束后把测试方案留给用户看（或经用户同意后清）
  - `export_segments`：视频1 的 1-2 号分镜导出到 scratchpad → ffprobe 验证时长≈分镜时长
- [ ] **Step 5: Commit**：`git commit -m "feat: delete_segments/create_custom_scheme/export_segments 三工具"`

---

### Task 6: App — generate_voice_variants（job）

**Files:**
- Modify: `MixCut/Services/MCP/MCPSegmentToolHandlers.swift`
- Modify: `MixCut/Services/MCP/AgentGateway.swift`（headless `DubbingViewModel` 注入）
- Modify: `MixCut/Services/MCP/AgentJobRegistry.swift`（Kind 增 `generateVoiceVariants = "generate_voice_variants"`）

**Interfaces:**
- Consumes: `DubbingViewModel.ensureClonedVoice(for:context:forceReclone:) async -> Bool`、`rewriteSegment(_:context:) async`、`errorMessage: String?`
- Produces: `generateVoiceVariants(_:)`

- [ ] **Step 1: AgentGateway 增 `let dubbingVM = DubbingViewModel()` 注入 handlers（同 segmentLibVM 方式；DubbingViewModel 的方法逐个传 context，不需要 setModelContext——以实际 init 为准）**

- [ ] **Step 2: handler 实现**

```swift
    func generateVoiceVariants(_ data: Data) throws -> Outcome {
        let sel = try JSONDecoder().decode(SelectorArgs.self, from: data)
        let segments = try resolveSegments(sel)
        let eligible = segments.filter { !$0.isVoiceLocked && !$0.text.isEmpty }
        let skipped = segments.filter { $0.isVoiceLocked || $0.text.isEmpty }
            .map { ["segment_index": $0.segmentIndex,
                    "reason": $0.isVoiceLocked ? "保留原声" : "台词为空"] }
        guard !eligible.isEmpty else {
            throw toolFailure(.invalidArgument, "所选分镜均无法生成变体（保留原声或台词为空）")
        }
        try ensureNoActiveJobShared()
        let projectID: UUID = eligible.first?.video?.projectVideos.first?.project?.id ?? UUID()
        let job = beginJob(kind: .generateVoiceVariants, projectID: projectID)
        let vm = dubbingVM
        let ctx = context
        Task { @MainActor in
            var perSegment: [[String: Any]] = []
            let byVideo = Dictionary(grouping: eligible, by: { $0.video?.id ?? UUID() })
            for (_, group) in byVideo {
                guard let video = group.first?.video else { continue }
                vm.errorMessage = nil
                let cloneOK = await vm.ensureClonedVoice(for: video, context: ctx)
                guard cloneOK else {
                    let reason = vm.errorMessage ?? "克隆原声失败"
                    for seg in group {
                        perSegment.append(["segment_index": seg.segmentIndex, "ok": false, "reason": reason])
                    }
                    continue
                }
                for seg in group {
                    vm.errorMessage = nil
                    await vm.rewriteSegment(seg, context: ctx)
                    if let err = vm.errorMessage {
                        perSegment.append(["segment_index": seg.segmentIndex, "ok": false, "reason": err])
                    } else {
                        perSegment.append(["segment_index": seg.segmentIndex, "ok": true,
                                           "variant_count": seg.effectiveDubVariants.count])
                    }
                }
            }
            var summary: [String: Any] = ["results": perSegment]
            if !skipped.isEmpty { summary["skipped"] = skipped }
            self.finishJobWithResult(job.id, resultJSON: AgentJSON.encode(summary))
            Self.notifyUIReload()
        }
        return success(["job_id": job.id.uuidString, "note": "生成中：克隆原声→AI 改写→合成→字幕对齐，用 get_job 轮询"])
    }
```

（`rewriteSegment` 失败是否写 `errorMessage` 实现时读 `DubbingViewModel.swift:237-290` 确认；若失败静默则以 `seg.effectiveDubVariants.count` 是否增长来判断成败。）

- [ ] **Step 3: 编译 + 实测**：当前 Debug 环境 DashScope Key 无效 → 对 123 项目 1 个分镜发起 → get_job 应返回逐分镜 `ok:false` + 401 友好错误（验证错误透出链路）。跑通后 UI 回归：变体面板手动操作正常。
- [ ] **Step 4: Commit**：`git commit -m "feat: generate_voice_variants 声音变体生成 job（克隆→改写→合成→对齐全链）"`

---

### Task 7: 收尾 — 全量验证 + Settings 边界文案 + 文档记忆 + 测试包

**Files:**
- Modify: `MixCut/Views/Settings/SettingsView.swift`（权限边界一句话更新）
- Modify: `docs/superpowers/specs/2026-07-28-mcp-segment-editing-design.md`（如实现有偏差则更新）
- Modify: memory `project_mcp_server.md`

- [ ] **Step 1: Settings 边界文案改为**：

```swift
                Text("以上是 Agent 的全部权限边界：不能拆分分镜、不能做画面替换变体。删除项目需 Agent 二次确认（先返回影响预览）；删除分镜/视频/项目执行后无撤销。")
```

- [ ] **Step 2: `swift test` 全绿 + Debug 编译 + 重启 + tools/list 应为 22 个**
- [ ] **Step 3: 完整场景实测**（滴露1）：list_segments 看编号 → 改 2 个分镜标签 → 边界 +10/-10 帧往返 → 字幕改「纯色遮挡」再改回 → 自选组合 3 分镜 → export_scheme 出片 → export_segments 出 2 个片段 → 全程截图 2-3 张验证 UI 联动
- [ ] **Step 4: UI 回归铁律清单**：分镜库多选/筛选/双击台词/边界微调行/字幕 chips/删除撤销浮条，逐项人工过
- [ ] **Step 5: 更新 memory（22 工具+分镜编辑边界）与 CLAUDE.md 工具数（13→22 处如有提及）**
- [ ] **Step 6: 打测试包** `MixCut-v0.9.2-agent-full-test.dmg`（版本号不动 0.9.2；Release universal + 三项校验 + 卷名带后缀），删旧 `-mcp-test` 包
- [ ] **Step 7: Commit + 汇报**：列「用户必须测试项」（声音变体真实生成需有效 API Key；多项目共享分镜的联动改动）

## Self-Review 结论

- Spec 覆盖：9 工具（Task 3-6）、寻址（Task 2）、错误码/说明书（Task 1）、只提醒不重生成（Task 4 staleDubs）、现有工具升级（Task 2）、测试与回归（Task 7）——全覆盖。
- 类型一致性：`SelectorArgs`/`resolveSegments`/`toolFailure`/`success` 贯穿 Task 2-6 已对齐；job Kind 两个新 case 在 Task 5/6 各自声明处一致。
- 刻意留白（实现时以代码为准，均已标注）：private 成员透出壳的取舍、`SubtitleMaskRect` 字段名、`SchemeSegment.scheme` 属性名、`rewriteSegment` 的失败信号、`createCustomScheme` 的顺序语义确认。
