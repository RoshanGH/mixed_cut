# 变体感知的分镜库批量导出（含 BGM 混音）设计

**日期**：2026-06-24
**作者**：MixCut
**状态**：已批准，待实现

## 目标

让分镜素材库的多选导出，对每个选中分镜导出 **1 + N 个**视频文件：

- **1 个原版**：原画面 + 原声 + 原字幕，完全不动（现有行为）。
- **N 个变体**：每个已生成配音的改写变体一个。变体视频 = 原画面 + 克隆配音 + 原 BGM 切片混音 + 烧录新字幕（遮挡旧字幕）。

例：选 2 号分镜，该分镜有 A/B 两个改写变体 → 导出 3 个文件（原版 / A 版 / B 版）。锁定原声（`isVoiceLocked`）的分镜没有变体，只导 1 个原版。

## 背景与现状（代码验证）

- 分镜素材库多选导出走 `BatchSegmentExportService.exportAll`，对每个 `BatchExportItem` 仅做 `ffmpeg cutSegment -c copy`（纯流复制切原片段）。**完全不感知配音变体**，永远只导原版。
- 单片「切片→9:16 标准化→遮挡旧字幕→烧新字幕→换音轨→定格补帧」的渲染逻辑**已存在**于 `DubExportService.renderSegment`（私有）+ `DubSegmentGraphBuilder.build`，目前服务于 MixScheme 方案导出。
- 人声/BGM 分离已实现：`VocalSeparationService.separate` 产出并缓存 `Stems/{videoHash}/vocals.wav` 与 `bgm.wav`。`bgm.wav` 当前**除定义外从未被消费**——配音镜头导出时音轨被整段替换为纯克隆人声，背景音乐被丢弃。
- 配音变体数据：`SegmentDub`（`segment × textVariantIndex × voiceId`）。克隆方案下音色唯一，所以一个 `textVariantIndex` 即一个变体。已生成音频 = `audioFilePath != nil`。

**两个待补的缺口**：
1. 批量导出不感知变体（只导原版）。
2. 配音镜头导出无 BGM（人声替换整段、丢背景音）。

本设计同时解决这两点。

## 需求

1. 每个选中分镜展开为 1 个原版任务 + 每个「已生成音频的 `SegmentDub`」一个变体任务。
2. 变体任务输出 = 原画面 + 克隆配音与原 BGM 切片混音 + 烧录新字幕（按该分镜遮挡设置遮挡旧字幕）。
3. 锁定原声的分镜只导原版。
4. 文件命名：原版 `{编号}_{视频名}.mp4`；变体 `{编号}_{视频名}_{字母}.mp4`，字母由 `textVariantIndex` 映射（0→A、1→B、…）。同名冲突沿用现有 `(1)(2)` 去重。
5. `bgm.wav` 缺失时变体仍可导出（回退为只有克隆人声），不报错。
6. 导出前 UI 显示将导出的文件总数（含变体），让用户有预期。

## 架构

新增一个**编排层**，把「选中分镜集合」展开成扁平的「导出任务列表」，每个任务按类型路由到对应渲染器；不另起大服务，最大化复用现有 `DubExportService.renderSegment` 与 `BatchSegmentExportService` 的流复制切片。

```
选中分镜集合
   │  展开（纯逻辑，可测）
   ▼
[导出任务]  每项 = .original(segment)  或  .variant(segment, dub)
   │  路由
   ├─ .original → 流复制切片（cutSegment -c copy）
   └─ .variant  → DubExportService.renderSegment（+ BGM 混音）
   ▼
输出目录中的多个 mp4（按命名规则）
```

## 组件

### 1. 任务展开（MixCutCore 纯逻辑，可测）

新增纯函数：输入「分镜及其变体的轻量描述」，输出导出任务列表 + 文件名。放在 `Sources/MixCutCore/`，不依赖 SwiftData / FFmpeg，便于单测。

- 输入项（值类型）：每个选中分镜的编号、视频名、是否锁定、变体列表（每个变体的 `textVariantIndex` 与「是否已生成音频」）。
- 输出：有序任务列表，每项含：类型（原版 / 变体）、命名（`{编号}_{名}` 或 `{编号}_{名}_{字母}`）、来源分镜/变体标识。
- 规则：锁定分镜只产原版任务；非锁定分镜产 1 原版 + 每个「已生成音频」变体一个；未生成音频的变体跳过。
- 字母映射：`textVariantIndex` → `A/B/C…`（`index` 映射到 `UnicodeScalar("A") + index`）。

### 2. BGM 混音（`DubSegmentGraphBuilder` + `DubExportService`）

`DubSegmentGraphBuilder.build` 音频段（现第 5 步）扩展：当为配音镜头（`keepOriginalAudio == false`）且提供了 BGM 输入索引时，音轨改为克隆人声与 BGM 切片的混音。

- 新增参数：`bgmInputIndex: Int?`（nil = 无 BGM，保持现有纯人声行为，向后兼容方案导出）。
- BGM 处理：`[bgmIdx:a]atrim=start={aStart}:end={aEnd},asetpts=PTS-STARTPTS,aresample=44100,volume={bgmGain}[bgmcut]`，其中 `aStart/aEnd` 为该分镜在原视频时间轴的起止秒（`startFrame/fps`、`endFrame/fps`）。
- 人声处理：沿用现有 `aresample=44100,loudnorm[,apad]`，得到 `[voice]`。
- 混音：`[voice][bgmcut]amix=inputs=2:duration=first:normalize=0[aout]`。`duration=first` 以人声（含 `apad` 补静音）为准，BGM 覆盖整段含定格尾巴。
- 音量：人声经 loudnorm 后为主轨；BGM `bgmGain` 默认 `0.6`，作为常量便于调。

`DubExportService`：
- 把 `renderSegment` 提取为可独立按单分镜调用的入口（公开方法或可注入的渲染步骤），供编排层复用。
- 渲染配音镜头时，把 `Stems/{videoHash}/bgm.wav` 作为额外输入追加，传入对应 `bgmInputIndex`；若文件不存在则不追加、传 `nil`（回退纯人声）。
- `bgm.wav` 路径通过 `FileHelper.stemsDirectory(videoHash:)` 定位，`videoHash` 取自分镜所属 `Video`。

### 3. 编排与现有批量导出整合（`BatchSegmentExportService` 流程）

- 在构建导出任务时（当前在 `BatchExportSheet` / `SegmentLibraryViewModel` 组装 `[BatchExportItem]` 处）调用组件 1 展开任务。
- 原版任务 → 现有 `cutSegment` 路径。
- 变体任务 → `DubExportService` 单片渲染路径。
- 进度汇总：总数 = 所有任务数（含变体）；逐任务上报，沿用 `SegmentBatchExportProgress` 结构（必要时扩展 `currentItem` 文案以区分原版/变体）。
- 失败隔离：单个任务失败不阻断其余（沿用现有 `failed` 收集）。

### 4. UI（`BatchExportSheet`）

- 导出前根据展开结果显示「将导出 X 个文件（含 Y 个配音变体）」。
- 其余交互（输出目录、命名、进度、失败提示）沿用现有实现。

## 数据流

1. 用户在分镜素材库多选分镜，点批量导出。
2. 编排层对每个选中分镜读取其 `segmentDubs`（已生成音频者），展开为任务列表。
3. UI 显示文件总数，用户确认输出目录。
4. 逐任务执行：原版走流复制；变体走 dub 渲染（按需追加 `bgm.wav` 输入，混音 + 烧字幕 + 遮挡）。
5. 全部写入输出目录，去重命名，汇总成功/失败。

## 错误处理与边界

- **变体未生成音频**：跳过该变体任务（不计入、不报错）。
- **`bgm.wav` 缺失**：变体任务回退为纯克隆人声音轨（无 BGM），记日志，不中断。
- **`vocals/bgm` 缓存属于整轨**：BGM 按分镜时间 `atrim` 裁切，无需逐分镜重新分离。
- **锁定原声分镜**：永远只产原版任务；即使历史上挂过变体也不导出变体。
- **同名冲突**：沿用 `BatchSegmentExportService.uniqueDestination` 的 `(1)(2)` 去重。
- **中间片编码一致性**：变体渲染沿用 `DubExportService` 的 `h264_videotoolbox` 固定参数；原版为流复制，二者是各自独立文件，互不拼接，无需参数对齐。

## 测试

纯逻辑层（`Tests/MixCutCoreTests/`，Swift Testing）：

1. **任务展开**
   - 非锁定分镜 + 2 个已生成变体 → 3 个任务（1 原版 + A + B），命名正确。
   - 锁定分镜 → 仅 1 个原版任务。
   - 含未生成音频的变体 → 该变体被跳过。
   - 多分镜混合 → 任务顺序、编号、字母映射正确。
2. **BGM 滤镜图**
   - `build` 传入 `bgmInputIndex` → `filterComplex` 含 `atrim`（起止秒正确）、`volume`、`amix=inputs=2`，且 `[aout]` 标签接线正确。
   - `bgmInputIndex == nil` → 退化为现有纯人声音轨（回归保护，方案导出不受影响）。
   - 带 `trailingSilence` 时人声 `apad` 仍在，`amix duration=first` 以人声为准。

## 不在本次范围

- 自动识别明星镜头（仍为手动 `isVoiceLocked`）。
- 克隆参考音跳过明星镜头时间段（type 2 偶发，另议）。
- BGM 音量的自适应/响度匹配（先用固定 `0.6` 常量，听后微调）。
- 混剪方案导出（`MixScheme`）的 BGM 混音——本次 `DubSegmentGraphBuilder` 改动向后兼容（`bgmInputIndex` 可选），方案导出可在后续单独接入。
