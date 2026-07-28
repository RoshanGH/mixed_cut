# MCP 分镜修改能力设计（Agent 能力第二阶段）

日期：2026-07-28
状态：已确认（关键语义经用户拍板，其余委托技术判断）
分支：`feature/mcp-server-phase1`（延续）
前置：`2026-07-28-mcp-server-phase1-design.md`（13 个工具已上线）

## 背景与用户决策

用户想清楚了分镜修改的能力边界：**UI 分镜库能做的操作，Agent 全部要能执行**。
本轮用户拍板的三个关键语义：

1. **字幕三档不做模糊映射**：工具只认「直接烧录 / 模糊虚化 / 纯色遮挡」三个明确档位。
   用户用词含糊（如"直接收录"）时，Agent 必须报出三档名称请用户确认，**不得自行猜测**。
   此规则写入 serverInstructions 下发给所有客户端。
2. **配音过期只提醒、不自动重生成**：分镜未生成过声音变体 → 随便改，不提示；
   已生成变体 → 改边界时明确告知哪些分镜的配音按旧时长合成、时长差多少、导出会静默用旧音频，
   是否重新生成由操作人决定。
3. **寻址用编号**：视频按导入顺序（`ProjectVideo.addedAt` 升序）1 起编号；
   分镜按时间顺序（`startFrame` 升序）1 起编号（与 UI 卡片 # 编号口径一致）。
   用户说"1 号视频的 3~8 号分镜"即可精确定位。

## 寻址协议（所有分镜工具共用）

```json
{
  "project_id": "UUID",
  "video_no": 1,               // 与 segment_ids 二选一
  "segment_nos": [3,4,5,6,7,8],
  "segment_ids": ["UUID", …]   // 直接用 id 也行（Agent 从 list_segments 拿到）
}
```
- `video_no`：项目内按 `ProjectVideo.addedAt` 升序 1-based。`addedAt` 字段此前无人消费，
  从此作为稳定顺序键；`get_project` 的 videos 数组改为按此排序并返回 `video_no`。
- `segment_nos`：该视频内按 `startFrame` 升序 1-based；`list_segments` 返回 `segment_no`。
- 范围（"3-8"）由 Agent 自行展开为数组，服务端只收显式列表。
- 找不到的编号 → `SEGMENT_NOT_FOUND`（新错误码），错误信息列出具体缺哪几个，**整个调用不执行**（要么全找到要么不动）。

## 新工具（9 个，总数 13→22）

### 1. `update_segment_tags`（写）
- 入参：selector + `add_semantic_types` / `remove_semantic_types` / `set_semantic_types`（三选一）
  + 可选 `position_type`（开头/中间/结尾）。
- 语义类型 rawValue 即 11 个中文名，非法名报 `INVALID_ARGUMENT` 并列出合法值。
- 校验：每个分镜至少保留 1 个语义类型（remove/set 导致清空 → 该分镜跳过并在结果中说明）。
- 落库：`segment.semanticTypes = ...` 计算属性（**禁止直写 semanticTypesData**，缓存会过期）。
- 副作用：safeSave + notifyUIReload（UI 的 SegmentCard.== 不比较标签字段，必须靠重载刷新）。

### 2. `adjust_segment_boundary`（写）
- 入参：selector + `start_delta_frames` / `end_delta_frames`（相对帧数，可负）
  或 `start_frame` / `end_frame`（绝对值，仅单分镜时允许）。
- 规则与 UI 完全一致：起点 ≥0；终点 ≤ 视频总帧数；最短 2 帧；相邻分镜允许重叠/空洞（UI 现状，不新增限制）。
  越界时钳制到边界值并在结果中注明实际生效值。
- 副作用链（照抄 UI `setStartFrame/setEndFrame` 的行为，但走静默路径不触发预览播放）：
  `setFrameRange`（同步派生时间 + 替换画面失效）→ `reExtractText` 按新时间窗重配台词 →
  safeSave → 起点变化的分镜批量重抽缩略图（批处理完统一做，不用 400ms debounce）→ notifyUIReload。
- **配音过期提醒**：对每个受影响分镜，用 `DubStaleness.check` 现算其已生成音频的 dub；
  结果附 `stale_dubs: [{segment_no, variant_index, old_duration_sec, new_duration_sec, diff_sec}]`
  和一句明确说明（"这些配音按旧时长合成，导出会静默使用旧音频；需要重新合成请调用 generate_voice_variants 或告知用户"）。
  没有已生成配音的分镜不出现在提醒里。

### 3. `set_subtitle_mode`（写）
- 入参：selector + `mode`（枚举，rawValue 就用中文：`直接烧录` / `模糊虚化` / `纯色遮挡`）
  + 可选 `font_ratio`（0.030–0.085，超界钳制）+ 可选 `mask_y` / `mask_height`（归一化 0-1，仅遮挡类生效）。
- 落库与 UI 绑定完全一致：`hasHardSubtitle = (mode != 直接烧录)`；遮挡类写 `maskStyle`（blur/solid）；
  `font_ratio` 写 `subtitleFontRatio` 并 `SubtitleFontSize.rememberPreferred`；mask 写 `maskRect`（自动 clamp）。
- **保留原声的分镜跳过**（UI 对锁定分镜隐藏字幕 chips），结果中逐条注明"已跳过（保留原声）"。

### 4. `set_voice_keep_original`（写）
- 入参：selector + `keep_original: Bool`（→ `isVoiceLocked`）
  + 可选 `original_in_combination: Bool`（→ `originalParticipatesInCombination`，原声是否进导出组合）。
- 开启保留原声后该分镜：不参与改写/配音、导出不加字幕（现有导出链路语义，不需要额外改）。

### 5. `set_dub_participation`（写）
- 入参：selector + `variant_indexes: [Int]` + `participates: Bool`
  （→ 对应 SegmentDub.participatesInCombination，UI 变体面板勾选的对等物）。
- 只作用于已生成音频的变体；找不到的 index 在结果中注明。

### 6. `generate_voice_variants`（写，job）
- 入参：selector。前置：分镜未保留原声、台词非空、千问 API Key 已配置。
- 流程 = UI 一键改写的分镜级版本：按视频分组 → 每视频 `ensureClonedVoice`（克隆原声，已有直接复用）
  → 逐分镜 `rewriteSegment`（AI 改写 K 套 + 克隆 TTS + 字幕对齐，K 取用户设置 dubVariantCount）。
- 返回 job_id；get_job 结果含逐分镜成败与失败原因（friendlyError 全透出）。
- 不改变 participatesInCombination 默认值（与 UI 行为一致，进组合需另行勾选/调 set_dub_participation）。

### 7. `delete_segments`（写，destructiveHint）
- 入参：selector。立即执行、无撤销（与 remove_video 同级，不做 confirm 两步——分镜可通过重跑分析重建）。
- 删除语义对齐 UI 批量删除路径（实现时以 SegmentLibraryViewModel 现行为准：级联删 SegmentDub/
  SchemeSegment 记录/物理镜头，磁盘文件交孤儿 GC）。
- 结果返回删除数量与受影响的方案列表（如有方案引用被删分镜，明确告知哪些方案缺了槽位）。

### 8. `create_custom_scheme`（写）
- 入参：`project_id` + `name`（可选，缺省自动编号"自定义 #N"）+ `segments`（**有序**数组，
  每项 `{video_no, segment_no}` 或 `{segment_id}`，跨视频任意混排）。
- 落到该项目"自定义组合"策略组下（与 UI createCustomScheme 同路径，含 AI 元数据推断如现路径有）。
- 返回 scheme_id + 总时长；之后可直接 `export_scheme` 导出。

### 9. `export_segments`（写，job）
- 入参：selector + `output_dir`（绝对路径，存在且可写，复用 ExportDestination.validate）。
- 复用 BatchSegmentExportService（编号+命名规则与 UI 批量导出一致）。
- 返回 job_id；result.exported 为产出文件路径列表。

## 现有工具的配套升级

- `get_project`：videos 按 addedAt 升序，新增 `video_no`。
- `list_segments`：新增 `segment_no`、`is_voice_locked`、`subtitle_mode`（三档中文名）、
  `font_ratio`、`voice_variant_count`（已生成音频的变体数）、`has_stale_dubs`。
- serverInstructions 追加：编号寻址约定；字幕三档准确名称与"含糊必须反问"规则；
  分镜全局共享警告（改动影响所有引用该视频的项目）；配音过期提醒的含义。

## 错误处理

- 新错误码：`SEGMENT_NOT_FOUND`、`SCHEME_NOT_FOUND`（补第一阶段 fetchScheme 复用 INVALID_ARGUMENT 的欠账）。
- selector 校验失败整个调用不执行（all-or-nothing 定位）；执行阶段逐分镜独立容错，
  结果含 per-segment 成败明细，绝不静默吞。
- 批量写共享 mainContext，逐条 safeSave 与 UI 一致；批量结束统一 notifyUIReload 一次。

## 测试与验收

1. Core 单测（TDD）：新工具 schema/错误码/serverInstructions 内容；编号寻址解析器（纯函数，
   放 MixCutCore：`SegmentSelector` 解析与校验）。
2. curl 实测（滴露1 项目真实数据）：改标签→UI 截图验证；边界±5 帧→验证台词/缩略图/时长变化与
   stale 提醒；字幕模式三档切换；保留原声开关；自选组合→export_scheme 导出成片；
   export_segments 出片段；delete_segments 删自建测试分镜。
3. generate_voice_variants：API Key 失效环境下验证结构化报错透出（与第一阶段 generate_schemes 同法）。
4. UI 回归（铁律清单）：分镜库多选/筛选/边界微调/字幕 chips/变体面板手动操作全部正常；
   VM 方法新增 silent 参数必须默认值保持 UI 行为不变。

## 已知限制（本阶段不做）

- 分镜拆分（splitSegment）、画面替换变体（ShotEdit）、台词重识别（↻）不在本轮（用户未提及）。
- 边界改动不自动重生成配音（用户拍板：只提醒）。
- `MixScheme.estimatedDuration` 存储字段在边界改动后陈旧（现有缺口，UI 同样存在；
  list_schemes 返回的是实时计算的 totalDuration，不受影响）。
