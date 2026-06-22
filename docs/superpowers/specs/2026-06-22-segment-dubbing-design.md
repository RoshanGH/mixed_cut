# 分镜级配音改写（换词 + 换音色 + 烧字幕）设计文档

- 日期：2026-06-22
- 状态：设计已评审通过，待写实现计划
- 关联：复用 v0.4.0「定格最后一帧」能力；与现有混剪方案生成为两条独立差异化轴

## 1. 背景与目标

用户的广告素材分两类：

1. **纯旁白型**：全程商品展示，一个画外音从头讲到尾，旁白连贯、单一说话人。
2. **明星出镜型**：也是商品展示，但夹杂 3-4 个明星出镜口播的镜头，明星用本人原声说话。明星片段是**花钱买授权的核心资产**。

目标：为视频生成**多个差异化配音版本**（防投放平台去重检测）。每个版本 = 一套重写的台词 + 一种音色配音 + 重新烧录的字幕。

**核心约束**：明星出镜镜头的原声原画**绝对不能被替换**，只能替换非明星的旁白片段。

## 2. 已评审通过的设计基线

| 决策点 | 选择 |
|---|---|
| 明星出镜镜头 | 保留原声原画，不动 |
| 谁是明星镜头 | 每个分镜手动开关「保留原声 / 可重配」 |
| 改写目的 | 差异化多版（防去重） |
| 时长对齐 | 字数约束为主 + 变速(atempo)/定格兜底 |
| 作用层级 | 分镜级，单分镜存多个配音版本，混剪/导出复用 |
| TTS | 云端 TTS（MiniMax / 千问） |
| 旧硬字幕 | 遮挡条 + 新字幕，遮挡区域**逐分镜可调** + 一键同步全视频 |
| 配音版本范围 | 全局共享（挂在 Video 上，跟分镜共享哲学一致） |

**本期做**：手动标记开关、AI 改写（带上下文 + 字数约束）、台词校对关卡、云端 TTS、时长对齐、硬字幕遮挡、字幕烧制、导出集成、生成 N 版。

**本期不做**：声纹自动识别明星、音色克隆明星本人、改写明星台词。

## 3. 总体流程

一个分镜可挂多个「配音版本」（DubVersion）。生成的操作单位是「某视频的第 K 版配音」，以保证一版内音色一致、旁白连贯。

```
为「视频 V」生成「第 K 版配音」：
  ① 台词校对关卡（复用现有台词编辑，关键词高亮，用户确认无误）
  ② 设置：生成几版 N / 每版选音色 / 目标语速
  ③ 遍历 V 里所有"可重配"分镜（跳过被标记"保留原声"的明星镜头）：
      ├─ AI 整片一次性改写（带前后上下文，每句卡在字数预算内）
      ├─ 云端 TTS 用「音色_K」合成音频
      ├─ 时长对齐：字数已卡准 → 轻微 atempo → 必要时定格补帧
      └─ 存为 DubVersion(分镜, 版本号=K, 音色, 台词, 音频, 对齐参数)

导出第 K 版：
  可重配分镜 → 用其第 K 版配音音频 + 新字幕
  明星镜头   → 用原声原画 + 原台词字幕（可选）
  有硬字幕的 → 遮挡矩形盖旧字幕
  → 全片烧字幕 → 编码成片
```

N 个版本 = N 条差异化成片。与现有混剪重排相乘，差异化数量大幅增长。

## 4. 数据模型

沿用项目约定：SwiftData relationship 表达集合关系；归一化坐标避免分辨率耦合；音频文件按 hash 存全局目录。

### 4.1 `Segment` 新增字段（逐分镜属性，全局共享）

```swift
// 是否"保留原声"（明星出镜镜头 = true，不可重配；默认 false 可重配）
var isVoiceLocked: Bool = false

// —— 硬字幕遮挡（逐分镜独立可调）——
var hasHardSubtitle: Bool = false   // 原片该分镜是否有硬字幕，要遮挡
var maskX: Double = 0.0             // 遮挡矩形，归一化 0~1（相对画面）
var maskY: Double = 0.80           // 默认底部带状区
var maskWidth: Double = 1.0
var maskHeight: Double = 0.12
var maskStyle: String = "blur"     // blur / solid / dim(半透明)
```

### 4.2 新模型 `DubVariant`（一个视频的第 K 版配音，整体管理单元）

```swift
@Model final class DubVariant {
    var id: UUID
    var video: Video?              // 这版配音属于哪个源视频（全局共享）
    var index: Int                 // 版本号 1..N
    var name: String               // "版本A" 可改名
    var voiceId: String            // TTS 音色 id
    var voiceProvider: String      // minimax / qwen
    var targetCharsPerSecond: Double = 5.0  // 目标语速（字数约束用）
    var status: String             // draft / generating / ready / failed
    var createdAt: Date
    @Relationship(deleteRule: .cascade) var segmentDubs: [SegmentDub]
}
```

### 4.3 新模型 `SegmentDub`（某分镜在某版里的配音）

```swift
@Model final class SegmentDub {
    var id: UUID
    var variant: DubVariant?
    var segment: Segment?
    var rewrittenText: String      // 改写后台词（可编辑）
    var audioFilePath: String?     // 配音音频；未生成时 nil
    var audioDuration: Double = 0  // 实际配音时长
    var atempoFactor: Double = 1.0 // 对齐变速系数（1.0=不变速）
    var freezePadFrames: Int = 0   // 末尾定格补帧数
    var status: String             // pending / generated / failed
}
```

### 4.4 关系与存储

```
Video 1──* Segment                                   （已有）
Video 1──* DubVariant 1──* SegmentDub *──1 Segment    （新增）
Segment ── isVoiceLocked / 遮挡矩形字段               （新增）
```

音频文件：`AppSupport/MixCut/Dubs/{videoHash}/v{index}/{segmentId}.m4a`

> **Schema 变更前必须先备份 `MixCut.store`**（CLAUDE.md 铁律）。新增字段带默认值是加性安全的；新增 @Model + 关系风险更高，备份后验证。

## 5. AI 改写台词

### 5.1 校对关卡（垃圾进垃圾出的防线）

改写语义基础是原台词，原台词错则一路传错（尤其产品名/价格/数字/卖点）。生成前强制一道校对：

- 左侧列出每个可重配分镜的原台词（可直接改，复用现有「双击编辑」）。
- 关键词（`Segment.keywords`）高亮，提示重点核对关键事实。
- 用户确认后才允许「生成」。改后的 `Segment.text` 全局共享，顺手修正原始数据。
- 时长对齐靠帧边界（`startFrame/endFrame`），不依赖 ASR 时间戳，故 ASR 时间漂移不影响对齐，只需校对文本。

### 5.2 改写策略（整片一次调用）

- 一次把该视频所有可重配分镜的【原台词 + 各自时长 + 各自字数预算】打包给 AI，产出一整套连贯新台词，每句卡在预算内。
- 字数预算：`目标字数 = 分镜时长 × 目标语速`，给区间 `[0.85×, 1.0×]` 留余量（TTS 实际略快）。
- prompt 硬约束：保留关键事实（keywords 锚定）、换说法做差异化、承上启下保持连贯。
- N 版差异化：每版喂不同风格/角度（复用 `ad_styles.md`）+ 不同音色。
- 走现有 `AIProvider.generateJSON`，返回 `[{segmentId, rewrittenText}]`，无需新协议。

## 6. TTS 配音 + 时长对齐

每个 `SegmentDub` 依次执行：

```
TTS(音色, 新台词) → 音频时长 D'，目标 = 分镜时长 D
对齐阶梯（能停就停）：
  1. |D'-D| ≤ 0.15s          → 直接用（短了补极短静音）
  2. 仍差                     → atempo 变速，锁 [0.9,1.1]（±10% 几乎听不出）
  3. 音频比画面长(变速到顶仍超) → 末尾定格补帧 freezePadFrames（复用 v0.4.0）
  4. 音频比画面短             → 末尾留静音，画面正常播完
```

- 字数预算已卡准，绝大多数走 1、2 步即停；定格只兜极少数残差。
- `atempoFactor`、`freezePadFrames` 落库，导出照拼，可复现。
- 云端 TTS 逐分镜独立容错：单句失败标 `failed`、不阻塞其余、可单独重生成。
- 并发：用项目现有自适应并发，避免打爆 API。

## 7. 字幕烧制

用 **ASS 字幕格式**（精确定位、逐句时间、样式可控）。每次导出生成一个 `.ass` 文件，最后烧入画面。

- 字幕内容：
  - 可重配分镜：字幕 = 新台词，时间贴配音音频区间。
  - 保留原声分镜：字幕 = 原 `Segment.text`，统一风格（默认开，可关）。
- 位置：归一化遮挡矩形 × 输出分辨率换算像素，新字幕落在遮挡条上——一步盖旧字幕又显示新字幕。
- 断行：字数预算已压短，9:16 单/双行即可，长句自动折行。
- **打包中文字体**：libass 渲染中文需字体文件，往 `Resources/` 塞开源中文字体（思源黑体 OFL），用 `fontsdir` 指定。否则中文字幕变方块（违反开箱即用）。
- 遮挡条：对 `hasHardSubtitle` 分镜，按 `maskStyle` 在遮挡矩形做 `boxblur`/`drawbox`/半透明。

## 8. 导出集成（两阶段）

现有 `FFmpegRunner.concat` 只做切片→缩放补边→统一 fps→concat→loudnorm，无换音轨/遮挡/字幕。逐分镜差异大，改为两阶段：

```
阶段一 · 逐分镜渲染中间片：
  对时间线每个分镜：
    切 [start,end]
    ├ 有硬字幕 → 遮挡矩形做 模糊/纯色/半透明
    ├ 可重配   → 替换音轨为配音 .m4a；freezePadFrames>0 则定格补帧
    └ 保留原声 → 保留原音轨
    缩放补边到 9:16、统一 fps → 标准化中间片

阶段二 · 拼接 + 烧字幕：
  concat 所有中间片 → 烧入整条 .ass → 最终编码（默认 H.264 硬件加速）
```

- **不破坏现有导出**：普通导出仍走原单遍 concat；只有「导出配音版本」走新管线。`ExportService` 加分支判断。
- 代价：多一道中间片编码。中间片用高码率/接近无损，最终再压一遍，画质损失压到不可见。
- 配音音轨与原声分镜统一 `loudnorm`，避免音量跳变。

## 9. UI 入口

按现有 `NavigationItem` 枚举 + 侧边栏 + 功能子视图落位：

- **分镜素材库（`SegmentLibraryView`）**：每分镜加「保留原声」开关、「硬字幕遮挡」开关；开启遮挡后 9:16 预览出现可拖拽遮挡框（上下移 + 改高度）+「应用到本视频所有分镜」按钮。复用现有多选/Equatable 性能优化，不破坏批量功能。
- **新视图「配音改写」（`DubbingView`，侧边栏加一项）**：① 台词校对列表 → ② 设置(N 版/音色/语速) → ③ 生成进度(逐分镜 pending/generated/failed) → ④ 版本管理(改名/删除/单句重生成/试听)。
- **导出（`ExportView`）**：加「配音版本」选择器（原声 / 版本A / 版本B…），导出所选版本走新管线。

## 10. 容错 / 边界 / 风险

| 项 | 处理 |
|---|---|
| ASR 不准 | 生成前「台词校对」关卡兜底 |
| 单句 TTS 失败 | 标 `failed`、不阻塞其余、可单独重生成 |
| AI 改写超字数 | 小幅超 → 变速/定格吸收；严重超 → 标记让用户手改 |
| 无旁白纯画面分镜 | 跳过改写，不配音不加字幕，原样保留 |
| 明星镜头又有硬字幕 | 可遮挡 + 保留原声 + 显示原台词字幕，三者不冲突 |
| 音量跳变 | 配音与原声分镜统一 `loudnorm` |
| 重新生成某版 | 覆盖该版 `SegmentDub` 和音频文件（幂等） |
| TTS 并发 | 用现有自适应并发 |
| Schema 变更 | 改前必须先备份 `MixCut.store` |
| 中文字体 | 打包思源黑体（OFL），否则中文方块 |
| 成本 | N 版 × M 分镜 的 AI+TTS 调用量，UI 提示预计调用量 |
| 9:16 比例 | 所有新预览/遮挡框严格 9:16 |

## 11. 模块边界（高内聚低耦合）

- `DubbingService`（actor）：编排改写→TTS→对齐→落库，无 UI 依赖。
- `ScriptRewriter`：封装 AI 改写（字数预算、上下文、差异化风格）。
- `TTSClient`（协议 + MiniMax/Qwen 实现）：文本→音频，与 `AIProvider` 平行。
- `AudioAligner`：对齐阶梯逻辑（atempo/定格计算），纯函数易测。
- `SubtitleBuilder`：生成 `.ass`（定位、样式、逐句时间），纯函数易测。
- `FFmpegRunner` 扩展：遮挡滤镜、换音轨、两阶段导出。
- `DubbingView` / `SegmentLibraryView` 扩展：UI 层。

每个单元职责单一、接口清晰、可独立测试。
