# TRD 05 · 自建分镜上传（技术方案）

> 配套产品文档：[05-自建分镜上传-PRD](./05-自建分镜上传-PRD.md)。本文只讲**怎么实现**：数据落库、服务、流水线、算法。
> 目标：Windows 端据此实现后，行为与 macOS 一致。随 Mac 端改动同步更新。

---

## 1. 核心设计原则
**自建分镜就绪后必须与"AI 切出来的普通分镜"数据同构**，从而下游一切能力（编辑/导出/方案组合/配音/画面替换）走**同一套代码、零特殊分支**。因此落库时给它配一个"载体视频"，让它天然满足现有"分镜挂在视频上"的所有假设。

> ⚠️ 这是纯后台实现细节，**产品与界面无感**（用户看到的就是一个分镜，见 PRD §2）。

**必须（实测踩过）**：载体视频（`isUserUploaded == true`）要在**所有"视频/成片列表与计数"**处过滤掉——项目概览「已导入视频」列表 +「视频」数、素材导入页视频列表等，都要 `filter { !$0.isUserUploaded }`；**分镜计数不过滤**（自建分镜计入分镜数）。否则自建分镜会和成片视频混在一起、平级显示（错误）。

---

## 2. 数据模型改动

### 2.1 Video 增加标记字段
现有 `Video` 加一个布尔标记（Schema 变更，**改前备份 `MixCut.store`**）：
```
// Video 模型
var isUserUploaded: Bool = false     // true = 用户自建分镜的载体视频
```
- 兼容：默认 `false`，旧数据自动为普通视频，无需迁移。
- 可选（若已有 `source`/来源枚举则复用）：用枚举 `VideoSource { imported, userSegment }` 亦可，二选一，保持单一标记。

### 2.2 一个自建分镜 = 一个载体 Video + 一个覆盖整片的 Segment
每上传一个文件，落库：
1. **Video**（载体）：`isUserUploaded = true`；`localPath` = 该文件在 App 目录的落盘路径；`duration/width/height/fps` 由 AVFoundation 读出；`contentHash` = 文件 SHA-256（复用现有去重）；`thumbnailPath` = 首帧 9:16 缩略图；`status = completed`。
2. **Segment**（覆盖整片）：`video = 该载体 Video`；`startFrame = 0`；`endFrame = round(duration * fps)`（末帧）；`startTime = 0`、`endTime = duration`（帧派生缓存，与现有 `setFrameRange` 口径一致）；`segmentIndex = "seg_001"`；`text`/`semanticTypes`/`positionType`/`keywords` 由后续 ASR + 打标写入。
- 因为它就是"一个视频 + 一个整片分镜"，`effectivePicture`、播放、缩略图、导出、配音、画面替换等**全部现成可用**，无需任何改动。

### 2.3 分组显示（分镜库把自建分镜聚成一类）
现有分组：`SegmentLibraryViewModel.recomputeGroupedSegments()` 按 `segment.video.id` 聚桶，产出 `[VideoSegmentGroup]`（每个视频一组）。改动：
- 遍历时，**所有 `video.isUserUploaded == true` 的 segment 合并进一个固定分组**「自建分镜」（一个特殊 `VideoSegmentGroup`，标题固定、图标为上传图标、`video` 可空或用哨兵）。
- 该分组**排在结果数组最前**；其余视频分组顺序不变。
- **该分组内无 segment 时，不产出该分组**（PRD §4.5：没有自建分镜就不显示）。
- 组内编号：沿用 `numberByVideo` 机制，对"自建分镜"这一组按加入顺序 1-based 编号（可用 `createdAt` 排序）。
- `DubSettingsBar`（视频级配音栏）在自建分镜组的处理：每个自建分镜是独立载体视频，配音栏按现有"每视频各自"逻辑即可（或在自建分镜组隐藏视频级批量配音栏，逐卡各自操作——按实现简洁度定，PRD 未强制）。

---

## 3. 上传与时长校验
- 入口：分镜库顶部工具栏「上传自建分镜」按钮 → `NSOpenPanel`（Windows：文件对话框），`allowedContentTypes = [mp4, mov]`，`allowsMultipleSelection = true`。
- **时长校验**：对每个选中文件用 AVFoundation 读 `duration`；`> 15.0s` 的**跳过**并计入"超时列表"；全部处理完若有超时项，汇总提示「N 个文件超过 15 秒已跳过」。合规文件进入落盘+处理。
- 去重：算 `contentHash`，若已存在同 hash 的 Video → 跳过并提示「已存在，已跳过」（复用现有导入去重）。

---

## 4. 处理流水线（每个自建分镜独立）
复用导入的处理骨架，但**砍掉切分相关步骤**，只保留 ASR + 打标：

| 步 | 动作 | 复用/新增 |
|---|---|---|
| 1 | 落盘 + AVFoundation 元数据 + 首帧 9:16 缩略图 | 复用现有导入落盘/缩略图逻辑 |
| 2 | 建载体 Video + 覆盖整片 Segment（§2.2），打 `isUserUploaded` | 新增（简单建实体） |
| 3 | **ASR 台词**：对整片做 ASR，写 `segment.text`（同时可写 `video.transcript/asrWords` 备用） | 复用 `ASRService.transcribe(videoPath:)`（whisper，本地）；或按 PRD 优先阿里 `QwenASRClient`（切整片 PCM）→ whisper 兜底 |
| 4 | **AI 打标（只打标不切分）**：见 §5，得语义类型/位置/关键词写入 Segment | **新增** AI 方法 |
| 5 | 就绪：卡片转正常分镜卡 | 无 |

- **不做**：场景切换检测、静音检测、AI 切分决策、四阶段边界优化、`mergeShortSegments`。
- **每步独立容错**（沿用现有流水线原则）：ASR 失败 → `text` 留空 + 卡片失败态 + 重试；打标失败 → 语义类型给默认「过渡」占位 + 失败态 + 重试；不阻断其它分镜。
- 处理状态驱动 UI：给该 Segment/载体 Video 一个处理阶段状态（复用 `Video.status` 或新增瞬态 `processingStage: idle/asr/tagging/done/failed`），卡片按此渲染"识别中…/打标中…/进度条"（PRD §4.4）。
- 并发：多文件建议**串行或小并发**（复用现有导入并发策略，避免多路 ASR/AI 抢资源）；每卡各自显示进度，互不阻塞 UI。

---

## 5. 新增能力：「只打标不切分」AI 调用
现有 `AIAnalysisService.analyzeVideo(...)` 把"切分决策 + 打标"耦合在一次调用里，输出是"一批新分镜 + 各自标签"，**没有**"给定一段已有分镜/文本 → 只回标签"的入口。需新增：

```
// AIAnalysisService 新增
func tagSingleSegment(
    text: String,                 // 该自建分镜的台词
    visualHint: String? = nil,    // 可选：缩略图描述/时长等弱提示
    onProgress: ((String) -> Void)? = nil
) async throws -> SegmentTags     // { semanticTypes: [SemanticType], position: PositionType, keywords: [String] }
```
- Prompt：复用现有语义类型定义（`segment_types_definition.md`），指令改为"这是**一个已切好的分镜**，只判定它的语义类型（可多）、位置、关键词，**不要再切分**"。
- 返回结构化 JSON（沿用现有 JSON 解析 + 截断修复防御）。
- 无 API Key：该步提示「请先在设置配置 API Key」，Segment 仍建成、台词仍可识别，语义类型留默认，打标可后补（PRD §7）。

> Windows 端同样新增此"只打标"入口，`SegmentTags` 结构与 macOS 对齐。

---

## 6. 就绪后（=普通分镜，零特殊化）
就绪的自建分镜在数据上与普通分镜无差别，因此**不需要为它写任何下游分支**：
- 分镜库筛选/搜索/排序/多选/批量导出、右键（含拆分，见 06）、检视器；
- 方案：自定义方案、AI 方案生成、排列组合、导出；
- AI：配音/克隆（`SegmentDub`）、画面替换（`PhysicalShot`/`ShotVariant`/`replacedPicture*`）、逐句字幕。
- **实现要求**：除"§2.3 分组显示"与"§3~5 上传+处理"外，**不得复制/分叉任何下游逻辑**。

---

## 7. 删除与清理
- 删除一个自建分镜 = 删其 Segment + 载体 Video（`isUserUploaded`）；级联删 `SegmentDub/PhysicalShot/ShotVariant/SchemeSegment`；磁盘文件（视频/缩略图/音频）交现有启动期孤儿 GC。
- 处理中删除 = 取消处理（复用"删除即取消"的 `cancelledVideoIDs` 机制）。

---

## 8. 落地清单（Windows）
- [ ] `Video.isUserUploaded` 字段 + 迁移安全（默认 false）。
- [ ] 上传入口（工具栏按钮）+ 多选 + 时长≤15s 校验 + 去重。
- [ ] 建"载体视频 + 覆盖整片分镜"落库。
- [ ] `recomputeGroupedSegments` 增"自建分镜"聚合分组（置顶、空则不显示、组内 1-based 编号）。
- [ ] 处理流水线（落盘→缩略图→ASR→只打标），每步独立容错 + 处理态 UI。
- [ ] 新增 `AIAnalysisService.tagSingleSegment`（只打标不切分）。
- [ ] 下游全部零特殊化复用；删除/取消复用现有清理。
