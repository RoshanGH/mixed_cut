# 分镜配音「裂变」编排（P5）设计文档

- 日期：2026-06-23
- 状态：设计待用户评审
- 基于：`2026-06-22-segment-dubbing-design.md`（沿用其分镜级配音、明星锁定、字数对齐理念）
- **取代**旧 spec 的两处过时设计：①「整片版本 `DubVariant`」模型 → 改为「每分镜变体池」；②「ASS 字幕 + 打包字体」→ P4 已改为 macOS 原生 PNG 叠加。

## 1. 背景与目标

P1–P4 已建好后台管线（数据模型雏形、AI 改写 `ScriptRewriteService`、千问 TTS + 对齐 `QwenTTSClient`/`DubAudioFinalizer`、遮挡+烧字幕+两阶段导出 `DubExportService`），但**没有任何 UI 驱动**，用户无法操作、无法测试。

P5 = **编排 UI + 裂变数据模型 + 组合引擎接入**，把全链路接通到「能点、能看、能导出」。

**裂变愿景**：每个可重配分镜 → 「K 个改写台词 × 3 个音色」变体池；混剪组合引擎按「音色统一/混用」开关消费这些变体，成片组合数指数级增长（反投放平台查重）。明星出镜锁定段保留原声原画原字幕。

## 2. 关键决策（本次可视化评审确认）

| 决策点 | 选择 |
|---|---|
| 入口 | **分镜素材库内**，顶部常驻可折叠「配音设置」栏（不开新页面） |
| 音色选择 | 前 10 音色卡片网格，多选**最多 3 个**，每卡可▶**按需试听** |
| 变体粒度 | 每分镜变体池 = **K 改写台词（默认 K=2）× 选定音色**；音频**按需生成** |
| 变体池展开 | **右侧检视栏（Inspector）**，矩阵：行=改写台词、列=音色、格=按需配音 |
| 方案页 | 逐槽显示「台词 + 变体标（音色·改写版 / 原声）+ ▶试听 + 就地『换变体』」 |
| 音色一致性 | 方案生成「**音色统一 / 混用**」开关 |
| TTS 时机 | 台词改写**预生成文本**；音频仅在 试听/生成/导出 时**按需合成** |
| 明星段 | `isVoiceLocked` 人工锁定，原声原画原字幕，不参与裂变 |
| 字幕/响度 | PNG 叠加（P4 既成）；锁定段原声**不做 loudnorm**（已定） |

## 3. 数据模型（schema 变更 —— 动手前必须先备份 `MixCut.store`）

> 因目前**无任何真实配音数据**（从未有 UI 创建过 `DubVariant`/`SegmentDub`），可在备份后直接重构，无需迁移用户数据。无 VersionedSchema，备份是唯一防线（CLAUDE.md 铁律）。

### 3.1 退役 `DubVariant`
旧「整片一个音色」模型无法表达「每分镜变体池 / 片内混音色」，**移除该 @Model**。其 `voiceId`/`voiceProvider` 字段并入 `SegmentDub`。

### 3.2 `SegmentDub` 改为「变体池单元」（一格 = 一个 分镜×改写版×音色）
```swift
@Model final class SegmentDub {
    @Attribute(.unique) var id: UUID
    var segment: Segment?              // 反向关系：Segment.segmentDubs
    var voiceId: String = ""           // 千问音色 id（如 "Cherry"）
    var voiceProvider: String = "qwen"
    var textVariantIndex: Int = 0      // 第几个改写版（0..K-1）
    var rewrittenText: String = ""     // 改写台词（同 textVariantIndex 的各音色行共享同文本）
    var audioFilePath: String?         // 按需配音；初始 nil
    var audioDuration: Double = 0
    var atempoFactor: Double = 1.0
    var freezePadFrames: Int = 0
    var trailingSilence: Double = 0
    // 失效追踪（DubStaleness，P3 既有）
    var generatedForStartFrame: Int = -1
    var generatedForEndFrame: Int = -1
    var generatedForTextHash: String = ""
    var statusRaw: String = "pending"  // pending / generated / failed
}
```
- `Segment` 加：`@Relationship(deleteRule: .cascade, inverse: \SegmentDub.segment) var segmentDubs: [SegmentDub] = []`
- 全局共享：变体池挂在 `Segment` 上（跟分镜全局共享哲学一致，多项目复用）。
- 一个可重配分镜的池 = K（改写版）× N（选定音色，N≤3）个 `SegmentDub`。

### 3.3 选定音色（记忆）
`Video` 加 `selectedVoiceIdsData: Data?`（JSON `[String]`，≤3）+ 计算属性 `selectedVoiceIds: [String]`。记住该视频选了哪 3 个音色，便于重进/重生成。

### 3.4 方案侧
- `MixScheme` 加 `voiceModeRaw: String = "unified"`（unified/mixed）+ `unifiedVoiceId: String?`（统一模式选的音色）。
- `SchemeSegment` 加 `selectedSegmentDubId: UUID?`（该槽选定的变体；`nil` = 原声 / 锁定段）。

### 3.5 音频文件路径
改 `FileHelper.dubAudioURL`：`AppSupport/MixCut/Dubs/{videoHash}/{segmentId}/{voiceId}-v{textVariantIndex}.m4a`。

## 4. UI（全部在分镜素材库 `SegmentLibraryView`）

### 4.1 顶部「配音设置」栏（常驻可折叠）
- **音色网格**：`QwenVoiceCatalog.all.prefix(10)`，卡片显示 中文名 + 特点；多选最多 3（满 3 其余置灰）；每卡 ▶ **按需试听**（固定样例文本合成短音频，按 `voiceId` 缓存到 temp，不入变体池）。选中写入 `Video.selectedVoiceIds`。
- **「一键改写台词」**按钮：对所有可重配分镜跑改写（见 §5.1），铺好 K 个文本变体；显示进度 + 成本提示（"将调用 AI K 次"）。
- 复用现有多选 / `Equatable` 性能优化，**不破坏**批量导出/删除/全选。

### 4.2 右侧检视栏「变体池」（选中某分镜时显示）
- **头部**：9:16 缩略图 + 原台词（可编辑，作校对基准）+ 时长/字数预算/🔓可重配 或 🔒锁定。
- **矩阵**：
  - 行 = 改写版（K 行；每行文本可编辑 + 字数预算校验；编辑某行 → 同步该分镜该 `textVariantIndex` 的所有音色行的 `rewrittenText`）。
  - 列 = 选定音色（≤3）。
  - 格 = 配音状态：▶（已生成可试听）/ ＋生成（按需合成该格）/ 灰（未生成）/ ⚠（`DubStaleness` 判失效，需重生成）。
- **锁定段**：检视栏显示「保留原声」，不出矩阵。
- 9:16 缩略图严格竖屏比例。

### 4.3 保留现有 `SegmentDubControls`
锁定/硬字幕遮挡/遮挡样式/一键应用到全视频 —— 不动。

## 5. 生成流程

### 5.1 改写（预生成文本，整片 K 次）
- 点「一键改写」→ `ScriptRewriteService` 整片调用 **K 次**（K 个差异化风格，复用 `ad_styles.md`），每次产一套「各可重配分镜的改写台词」，每句卡字数预算（`CharBudget`）。
- 落库：为 每可重配分镜 × 每 textVariantIndex × 每选定音色 建一个 `SegmentDub`（`rewrittenText` 填好、`audioFilePath = nil`、`status = pending`）。同 `textVariantIndex` 的各音色行文本相同（冗余但小）。
- 改音色选择：新增音色 → 为其建行（复制现有各 textVariant 文本）；移除音色 → 删该音色行（连带音频文件）。

### 5.2 音频（按需）
- 触发点：矩阵格 ▶/＋生成、检视栏「整行生成」、或导出补齐。
- 流程：`QwenTTSClient(voiceId, rewrittenText)` → `DubAudioFinalizer`（atempo + 转 m4a + 落对齐参数）→ 写 `audioFilePath`、`status=generated`、记 `generatedFor*` 快照。
- 容错：单格失败标 `failed`、不阻塞其余、可单独重生成。并发用项目现有自适应并发。

### 5.3 音色试听样例
选音色卡 ▶ → 固定样例文本（如「这款产品真的很好用，喜欢的话点击下方链接」）经 `QwenTTSClient` 合成短音频，按 `voiceId` 缓存复用，不入变体池。

## 6. 方案生成 + 组合引擎

### 6.1 音色模式开关
方案生成设置加「音色统一 / 混用」。统一 → 从选定音色里指定一个 `unifiedVoiceId`；混用 → 任意。

### 6.2 组合引擎（`SchemeGenerationService` 扩展）
现有引擎选好分镜组合后，为每个**可重配**槽位选定变体：
- **统一(voiceX)**：选该分镜 `voiceId==X` 的某个 textVariant 行。
- **混用**：任选该分镜池里任一行。
- **锁定段**：`selectedSegmentDubId = nil`（原声）。
- 写入 `SchemeSegment.selectedSegmentDubId` + `MixScheme.voiceModeRaw`/`unifiedVoiceId`。
- 被选中的变体**音频可缺**（导出时按需补，§7）。
- 选变体的「统一/混用 分配」逻辑抽到 **MixCutCore 纯函数 `VariantSelector`**（可单测）。

### 6.3 方案页（`SchemeDetailView` 扩展）
逐槽：缩略图 + 用的台词 + 变体标（绿=🎙音色·改写版 / 橙=🔒原声锁定）+ ▶试听 + **「换变体」**（下拉选该分镜池里另一变体 → 更新 `selectedSegmentDubId`，不重跑方案；导出时按需补音频）。

## 7. 导出集成（接 P4，引擎不变）

- `DubExportService.export(input:outputPath:config:)` 引擎**完全不变**。
- 改 `DubExportInput.from`：旧 `from(scheme:variant:DubVariant)` → 新 **`from(scheme:)`**：遍历 `scheme.orderedSegments`，按 `SchemeSegment.selectedSegmentDubId` 找 `SegmentDub` 建 `DubSegmentSpec`；`nil`/锁定 → 原声 spec（沿用 P4 既有回退逻辑）。
- 导出前**补齐缺失音频**：对被选中但 `audioFilePath==nil` 的 `SegmentDub`，先按需 TTS 合成（§5.2）再导出；任一失败则提示具体分镜。

## 8. 容错 / 边界

| 项 | 处理 |
|---|---|
| schema 变更 | 改前备份 `MixCut.store`；无真实数据故重构安全 |
| 改写超字数 | 小幅 → 变速/定格吸收；严重 → 标记让用户手改该行 |
| 单格 TTS 失败 | 标 `failed`、不阻塞、可单独重生成 |
| 选音色 <3 | 允许 1–3 个（不强制满 3） |
| K 值 | 默认 2（配 3 音色≈6 变体/分镜）；本期固定 2，不做可配 |
| 无旁白纯画面分镜 | 跳过改写，不入矩阵，导出原样保留 |
| 明星段又有硬字幕 | 锁定 → 原声原字幕，不遮挡不叠新字幕 |
| 成本提示 | 改写=K 次 AI 调用；音频=按需（UI 显示「待生成 N 格」）|
| 失效 | 改分镜边界/行文本 → `DubStaleness` 标该格 ⚠，重生成 |
| 9:16 | 所有新预览/缩略图严格竖屏 |

## 9. 模块边界（高内聚低耦合）

- `DubSettingsBar`（View）：顶部音色选择 + 一键改写 + 试听。
- `SegmentVariantInspector`（View）：右侧检视栏变体池矩阵。
- `DubbingViewModel`（`@Observable @MainActor`）：持有 services，触发改写/按需 TTS/试听，管理选定音色与矩阵状态。
- `VariantSelector`（MixCutCore 纯函数）：统一/混用 的逐槽变体分配，可单测。
- 复用：`ScriptRewriteService`(P2)、`QwenTTSClient`+`DubAudioFinalizer`(P3)、`DubExportService`(P4，仅改 `from`)、`DubStaleness`(P3)、`QwenVoiceCatalog`、`CharBudget`。
- 扩展：`SchemeGenerationService`（选变体）、`SchemeDetailView`（逐槽变体标+换变体）、`SegmentLibraryView`（顶栏+检视栏）。

## 10. 测试

- **MixCutCore 单测**：`VariantSelector`（统一/混用分配、锁定段跳过、音频可缺）；行文本同步逻辑（若抽纯函数）；失效判定（`DubStaleness` 已有）。
- **App**：编译通过 + 手动端到端（选 3 音色 → 一键改写 → 按需生成几格 → 方案生成两种音色模式 → 方案页换变体 → 导出配音版肉眼验收：遮挡/字幕/音色/锁定段原声）。
