# 逐句字幕时间 + 逐句烧录 — 设计文档

> 日期：2026-07-09
> 状态：设计已与用户逐点对齐；**已过一轮 spec 评审并补齐必改项**（输入序号重排/音频措辞/播放黑屏/性能预算/文本只读/构造点补全）；待用户复核 → writing-plans
> 一句话：变体字幕不再"整段糊在画面上"，改为**按配音里每句实际说到的时间逐句出现**；时间由内置 whisper 对变体配音做 ASR 自动得到，用户可手动微调。

---

## 1. 目标与背景

**现状**（已在代码确认）：`DubExportService` 对每个要烧字幕的变体，把**整段改写台词**（`dub.rewrittenText`）当**一整块**渲染成一张 PNG（`captionText = 整段文本` → `CaptionRenderer.renderToFile` → 全程 overlay 在整段时长上）。真实语音是一句一句说的，字幕却整段堆在上面，观感差。

**目标**：变体字幕**逐句出现**——每句只在"配音实际说这句话"的时间窗内显示。

---

## 2. 定稿决策（与用户逐点确认）

1. **只作用于"有配音的变体"**：只有变体台词需要烧录；原版/其他一律不烧（维持现状，`hasHardSubtitle` 仅在变体路径生效）。
2. **永远逐句，无"整段烧录"回退**：没生成配音的变体根本走不到烧录这步，不存在"退回整段"这个分支——**整段烧录方案彻底移除**。
3. **字幕文本 = 改写台词（方案"甲"）**：字幕文字用用户写的 `rewrittenText`（字准），**只借配音 ASR 的时间**（不用 whisper 的转写文本，避免听错字）。
4. **不要标点**：显示时标点全去掉、用空格代替（复用现有 `CaptionRenderer.stripPunctuation`）；逐句出现，无需标点连句。
5. **自动生成 + 手动微调**：配音生成后自动算好每句时间；不准的地方用户在编辑器里手调。

---

## 3. 数据模型

`SegmentDub` 新增一个字段存"逐句字幕行"（含时间），随配音一起持久化：

```swift
/// 一行逐句字幕：文本（原始，含标点；显示时再 strip）+ 相对分镜起点的秒时间窗。
struct CaptionLine: Codable, Hashable, Sendable {
    var text: String     // 该句改写台词原文（显示时 stripPunctuation）
    var start: Double    // 相对分镜起点（秒）
    var end: Double
}

// SegmentDub 新增：
var captionLinesData: Data?          // [CaptionLine] JSON 编码；nil = 尚未对齐
// 计算属性 captionLines: [CaptionLine] 读写（与 keywords/asrWords 同款 Data?+JSON 模式）
```

- **Schema 变更**：新增一个可选 `Data?`，additive、向后兼容；仍按项目规则改前备份 `MixCut.store`。
- 时间基准：**相对分镜起点的秒**（分镜内时间轴），与烧录时 ffmpeg 的段内时间轴一致，无需再换算。

---

## 4. 生成流水线与对齐算法

### 4.1 触发时机与音频事实（评审修正）
在**任何"(重)生成变体配音音频"的路径成品落库后**自动追加一步"逐句对齐"，结果写进 `dub.captionLines`：
- **首次生成配音**（`DubbingViewModel.generateAudio` 里 `dub.audioFilePath = …` 之后，@MainActor）。
- **编辑台词后重配音**（用户在既有「编辑台词」里改字 → ✓ 确认 → `updateVariantText` 重新生成配音）——**这就是"改字幕文字"的正规路径**：改的是 `rewrittenText`，确认即重配音，然后重对齐、`captionLines` 随之刷新。未点确认的改动不生效（丢弃）。
- 抽一个统一入口（如 `alignCaptions(for dub:)`）在这两条路径的配音落库后都调用，保证字幕文本永远跟随最新配音内容。
- **成品 m4a 的真实性质**（`DubAudioFinalizer` + `AlignmentPlan`）：m4a 是 atempo 变速后的**纯语音**音频，**起点与分镜起点对齐、时间轴为分镜内 0 起**；但 `trailingSilence`/`freezePadFrames` **不烧进 m4a**（留给导出阶段）。所以**偏短的配音，m4a 时长 < 分镜时长**（差一段末尾静音）。→ 对 m4a 做 ASR 得到的时间落在 `[0, m4a时长]` ⊆ `[0, 分镜时长]`，**仍是分镜内 0 起的真实时间**，逐句对齐成立（末句结束早于画面结尾，正确）。**「配音总时长」一律指 m4a 时长，不是分镜时长。**
- 重新生成/重新配音覆盖 `captionLines`（同生命周期）。

### 4.2 对齐算法（"甲"：改写台词做文本、ASR 做时间）—— 抽成纯函数 `SentenceTimingAligner`
输入：`rewrittenText`（含标点）、`asrWords: [ASRWord]`、`audioDuration`（m4a 时长）。输出：`[CaptionLine]`。
1. **按标点切句**：`rewrittenText` 按句末标点（。！？；！?.;、换行、多空格）切成 `[句子原文]`；空/纯标点段丢弃。
2. **主策略＝按字符比例分配到"语音跨度"内（比现有逐字匹配更稳，评审建议）**：
   - 由 `asrWords` 取整体语音跨度 `[首词.start, 末词.end]`（ASR 空 → 用 `[0, audioDuration]`）。
   - 在该跨度内，按各句**去标点字符数**的比例切分 → 每句 `[start,end]`。参考并复用项目现成、已验证的 `TranscriptionResult.buildSentencesFromTextFallback`（`ASRService.swift:67-123`，正是"标点切句 + 字符比例分时间"）。
3. **可选精修（有 asrWords 时）**：把 `asrWords` 展成"字符→时间"序列——**注意 whisper 的是 token 级不是严格每字**，一个多字 token 的 `[start,end]` 要**按字符数线性内插**摊到每个字符；再用各句去标点字符在该序列里顺序单向匹配，命中则用命中的首/末字符时间**替换**比例估的边界，未命中保留比例估值。指针单向前进，句间不重叠、升序。
4. 全部 clamp 到 `[0, 分镜时长]`，按 start 升序写回 `dub.captionLines`。

> 句子边界来自"改写台词标点"，时间来自"配音 ASR/比例"，都可能有偏差 → **必须手动微调**（§5）。

### 4.3 性能预算与失败处理（评审补）
- **批量代价**：`generateAllAudio` 是串行 for 逐个 dub 生成；每个 dub 后加一次 ASR = **N 次 whisper 进程启动 + N 次模型加载**（当前内置模型 `ggml-large-v3-turbo` ≈1.6GB，单次 CLI 都重新 load，5 分钟超时）。分镜/变体多时会显著拉长批量总时长。
- **不阻塞主线程**：ASR 在 `ASRService`（actor）内起子进程，不卡 UI；但会占满"批量配音"的总时长。spec 要求：对齐**在配音生成后台流程内异步进行**，**不阻塞试听/UI**；对齐**失败或超时一律走 §4.2 兜底**，**绝不影响配音本身判定为成功**（不进 `lastDubErrors`、不报错阻断）。
- 内置 `ggml-small` 未随包（只内置了 large-turbo），故对齐**复用已内置的 large-turbo**；"换小模型加速"列为**后续可选优化**，本期不引入新内置二进制。

---

## 5. UI：逐句时间编辑器（评审修正）

变体已生成配音时，在**配音变体池**（`SegmentVariantInspector`）该变体卡片上放一个「逐句字幕」入口 → 打开**独立弹窗 sheet**（不塞进 340 宽的窄检视栏，避免"文本+起止+微调"一行挤爆）。弹窗列出该变体的 `captionLines`：

- 每行：**句子文本（只读）** + **起 / 止**（可编辑：数字框或 −/＋ 微调，单位 0.1s 或帧）。
  - **文本只读、跟随 `rewrittenText`**（评审"字画不符"红线）：本期编辑器**只调时间**，不改字。理由：字幕文本必须与配音说的内容一致；要改字请去改 `rewrittenText`（走既有编辑→重配音→自动重对齐），保证字画同步。
  - 断句不理想（切错句）：本期先接受自动断句 + 手调时间；**行的合并/拆分留 v2**（YAGNI）。
- **播放校对**：点某句 → **只放配音 m4a 的 [start,end] 音频段**（用 `AVAudioPlayer` 或复用 `dubVM.playDub` 的音频通道，**不要用 `RangeVideoPlayer` 喂纯音频**——它是 AVPlayerLayer，纯音频会黑屏）。听着确认这句字幕对不对得上说的话。
- **「重新自动对齐」** 按钮：重跑 §4.2 覆盖当前逐句时间（**只覆盖时间**，文本本就跟随 rewrittenText；给二次确认）。
- 约束校验：起<止；相邻不重叠（可留间隙）；全部 clamp 到 `[0, 分镜时长]` + 轻提示。
- 空态：变体还没配音 → 不显示入口（走不到烧录，决策 2）。

> 铁律：编辑器数据加载用 `.task(id:)` 挂 body 顶层（切分镜/切项目联动刷新）；即时写库。

---

## 6. 烧录改造（DubExportService + DubSegmentGraph + VariantBatchExportService）

**现状**：`spec.captionText`（整段）→ 一张 PNG → 一个 overlay 全程显示。ffmpeg `extraInputs` 顺序 `[caption?, dub?, bgm?]`，`captionInputIndex=1`、`dubAudioInputIndex/bgmInputIndex` 按 `extraInputs.count` 现算（`DubExportService.swift:227-262`）。

**改为**：变体路径下用 `dub.captionLines` 生成**多张** PNG、**多个**分时段 overlay。关键改造点：

1. **输入序号重排（评审必改，否则串音轨）**：新输入布局 = **先 push 全部 N 张 caption PNG（占 input 1..N），再 push dub、bgm**；`dubAudioInputIndex/bgmInputIndex` = **N + 偏移**（不能再沿用旧的"caption 恒为 1、dub=count"假设）。
2. **`DubSegmentGraphBuilder.build` 签名改造**：从单个 `captionOrigin/captionInputIndex` → `captions: [(inputIndex:Int, origin:(x,y), start:Double, end:Double)]`；filter 里对每条生成 `...overlay=x:y:enable='between(t,start,end)'` 串联。段内时间轴 `t` = 分镜内 0 起（`trim,setpts=PTS-STARTPTS` 已保证，`DubSegmentGraph.swift:44`），与 `CaptionLine.start/end` 天然一致。
3. **统一画布避免竖直跳动（评审建议）**：各句 PNG 高度随行数变化会让 `overlayOrigin` 竖直居中位置逐句跳。→ **按"最高的一张"统一各句 PNG 画布高度 / 或统一落位 y**，保证字幕上下不跳。
4. **构造点要全部改（评审：漏了 VariantBatchExportService）**：`captionText → captionLines` 连锁改动涉及 **三处**：`DubExportService.swift`（方案组合导出，`:61-70`）、`VariantBatchExportService.swift`（单/批量分镜导出，`:70`）、`exportSingleSegment`（也走 `renderSegment`）。`DubSegmentSpec` 的 `captionText: String` → `captionLines: [CaptionLine]`；三处构造都从**选定的那个 dub** 取其 `captionLines`（captionLines 属 dub，随选定变体走）。
5. **移除整段路径**（决策 2）：不再有 `captionText` 单图分支。
6. **遮挡空窗（评审提示，需确认）**：遮挡（`.blur/.solid/.dim`）是**全程**作用于 mask 区，字幕改逐句后，**句间空窗会露出"有底色/模糊但没字"的空条**（`.solid` 纯色最明显）。**决策：接受**——空窗有遮挡底但无字属正常（避免旧字幕透出）；若后续觉得丑再让遮挡也跟随逐句 enable（v2）。

**上限与鲁棒**：给每段 caption 行数设**上限（如 ≤ 20 行/overlay）**，超出则合并相邻短句，避免"1 字 1 句"炸出几十个 `-i png`+overlay 拖垮命令；`captionLines` 为空（异常）→ 该段不烧、不报错、不阻塞串行队列（见导出串行 PRD）。

---

## 7. 边界与异常

- 变体无配音 → 无 `captionLines` → 不烧（走不到这步）。
- ASR 崩溃/空 → §4.2 兜底按字数比例给初值，用户可调；导出时即使 `captionLines` 异常为空也只是不烧、不崩。
- 改写台词被编辑（改字/重生成配音）→ `captionLines` 随配音重算（失效追踪与现有 `DubStaleness` 一致）。
- 分镜边界被改 → 配音本就要重生成（现有逻辑），`captionLines` 跟着重算。
- **对齐 ASR 失败/超时 → 走 §4.2 比例兜底，绝不阻断"配音成功"的判定**（不进 lastDubErrors）。
- 句子极多/极短（1 字一句）→ 有**行数上限 + 相邻短句合并**（§6），避免炸 overlay。
- `captionLines` 属 `SegmentDub`、随选定变体走；多变体组合导出时每条各取自己选定 dub 的 captionLines。

---

## 8. 非目标（YAGNI）

- 不给"原版台词"做逐句烧录（原版不烧字幕）。
- 不做"对齐到原视频口播时间槽"（用户已否掉：改写文本硬套原文别扭；改用变体自身 ASR）。
- 不改配音生成本身（仍整段生成+atempo 对齐；本功能只在其后加"对配音测时间"，不改音频）。
- 不做多语言/双语字幕。
- 不保留"整段烧录"开关（彻底移除）。

---

## 9. 测试策略

**纯逻辑单测（MixCutCore，Swift Testing）**：把"对齐算法"的可测部分抽成纯函数 `SentenceTimingAligner`（输入：`rewrittenText` + `[ASRWord]`，输出：`[CaptionLine]`），覆盖：
- 正常：3 句台词 + 对应字级时间 → 3 行、时间正确、不重叠、升序。
- 标点切句：多种句末标点/换行/空格 → 句子数与边界正确；纯标点段被丢弃。
- 匹配容错：ASR 少字/多字/错字 → 指针单向前进不崩、句子仍拿到合理 [start,end]。
- 兜底：ASR words 为空 → 按字数比例等分；某句匹配不到 → 相邻插值。
- 边界：单字句、空文本、全落在 [0,duration] 内。

**人工验收（app 内）**：
1. 变体生成配音后，逐句字幕区自动列出每句 + 时间；点句能播对应配音段、字幕与听到的话对得上。
2. 手改某句时间/文字 → 即时写库、重开仍在。
3. 导出该变体 → 成片里字幕**逐句出现**、去标点、每句卡在它被说的时间窗，不再整段糊上面。
4. "重新自动对齐"覆盖手改（有二次确认）。
5. 既有：配音生成/试听/重生成/删除、参与组合勾选、导出串行、遮挡三模式 不回归。
