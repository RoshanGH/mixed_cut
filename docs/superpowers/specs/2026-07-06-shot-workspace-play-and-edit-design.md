# 分镜头工作区：可播放 + 可调整（合并/拆分/移动边界）— 设计文档

> 日期：2026-07-06
> 状态：设计已与用户逐段对齐，待 spec 评审 → 用户复核 → writing-plans
> 关系：扩展 `2026-07-06-shot-picture-replacement-inplace-design.md` 的工作区（`ShotEditSheet`）。切分/变体/VACE/就地替换等不变。

---

## 1. 目标

当前工作区分镜头只展示静态首帧，且切分粒度固定、不可调。用户需要：
1. **能播放每个分镜头**（悬停播它在源视频的那段），才能判断切得对不对；版本区的「原版」「各替换变体」也要能播，便于对比。
2. **能调整分镜头划分**：合并相邻镜头、拆分一个镜头、移动/微调边界（拖动 + ±帧）。

**铁律（核心不变式）**：**所有分镜头帧区间必须始终无缝铺满外层分镜 `[segment.startFrame, segment.endFrame]`，总时长恒等于外层分镜时长**。任何调整都不能破坏这一点。

---

## 2. 对齐保证：切分点建模

不把分镜头当独立时间段，而是把外层分镜看成一整条、分镜头之间只由 **N−1 个切分帧** 分隔。**不变式**（持久化后始终成立）：
- 按 `orderIndex` 升序；
- `shots[0].startFrame == segment.startFrame`；
- `shots[i].endFrame == shots[i+1].startFrame`（相邻无缝）；
- `shots[last].endFrame == segment.endFrame`。

所有编辑操作都以"改切分点"表达，段落自动跟随 → 总长恒等于分镜时长，结构上不可能出现空隙/重叠/总长不符。

---

## 3. 纯逻辑：ShotPartitionEditor（MixCutCore，TDD）

新增 `Sources/MixCutCore/ShotPartitionEditor.swift`，`public enum`，全 static 纯函数，输入输出 `[ShotSpan]`（`{startFrame,endFrame}`，Sendable/Equatable）。每个函数返回新的合法分区（保持不变式 + 最小帧数约束），并**上报哪些区间发生了变化**（供上层失效变体）。

- `merge(_ shots:, at i:) -> [ShotSpan]`：合并 `i` 与 `i+1`（新区间 = `[shots[i].start, shots[i+1].end]`）。
- `moveBoundary(_ shots:, boundaryIndex b:, toFrame f:) -> [ShotSpan]`：把第 b 个切分点（`shots[b].end == shots[b+1].start`）移到 f，**clamp** 到 `(shots[b].start + minFrames, shots[b+1].end - minFrames)`。
- `split(_ shots:, at i:, atFrame f:) -> [ShotSpan]`：把镜头 i 在 f 处一分为二（f 需在 `(start+minFrames, end-minFrames)`，否则原样返回）。
- 辅助 `changedRanges(old:new:) -> Set<帧区间>` 或直接由上层比对 id/range 判定失效。
- `minFrames`（最小镜头帧数，默认按 ~0.3s 或 1 帧，取实现常量）防止 0 长。

**测试**（`Tests/MixCutCoreTests/ShotPartitionEditorTests.swift`）：合并后无缝且总长不变；移动边界 clamp 生效、两侧无缝；拆分后两段和 = 原段；所有操作后 `shots[0].start/last.end` 不变（= 分镜边界）；非法输入原样返回。

---

## 4. App 层：应用编辑到模型 + 失效变体

`ShotEditViewModel` 新增（改动持久化 PhysicalShot）：
- `mergeShots(at:)` / `splitShot(_:atFrame:)` / `moveBoundary(between:toFrame:)`：调 `ShotPartitionEditor` 得新分区 → **对账** `segment.physicalShots`：
  - 帧区间**未变**的镜头：保留（含其变体/缩略图）。
  - 帧区间**变化**或新产生的镜头：删除其 `ShotVariant`（含 `resultVideoPath`/缩略图文件，留给孤儿 GC）、清 `selectedVariantID`、`thumbnailPath=nil`（触发重生成）。
  - 数量减少（合并）→ 删多余 PhysicalShot；增加（拆分）→ 插新 PhysicalShot。
  - 重排 `orderIndex` 连续 1..N。
- **对账映射规则（明确）**：新分区的每个 `ShotSpan` 按 `(startFrame,endFrame)` **精确相等**匹配旧 `PhysicalShot`——相等则保留（含变体/缩略图/selectedVariantID）；无相等匹配的旧 shot 删除、新 span 新建。**不要用 orderIndex 对位**（会误保留错变体）。
- **【必做】同时作废外层分镜的替换画面**：调整只改 `PhysicalShot`，**不经过** `Segment.setFrameRange`，所以现有"改边界清替换画面"逻辑不会触发。若本次调整改动了任一镜头帧区间，**必须一并清除** `segment` 的替换画面四件套（`replacedPictureVideoPath/Thumbnail/FrameCount=nil/0`、`pictureShowsReplaced=false`）——否则"合成后再回工作区调整"会留下指向旧合成片的状态，导出/预览用陈旧画面。抽 `Segment.invalidateReplacedPicture()`，供 `setFrameRange` 与本处共用。
- 改动后：`save()` → `ensureShotThumbnails`（补新/变动镜头缩略图）→ 刷新 `shots` 与 `selections`（新镜头默认选原版）。

> 说明：分镜头调整只在**未合成替换画面前**在工作区内进行；不影响外层分镜的 `startFrame/endFrame`（分区始终贴合它）。

---

## 5. 播放：RangeVideoPlayer（悬停播放指定区间）

新增轻量组件 `MixCut/Views/SegmentLibrary/RangeVideoPlayer.swift`：
- 入参：`videoPath`、`startTime`、`endTime`、`thumbnailPath?`、9:16 容器。
- **悬停自动播**该区间（对齐外层 `SegmentInlinePlayer` 的悬停播 + 半帧对齐 + 到 endTime 定格 逻辑，抽其精简版；避免与 SegmentInlinePlayer 强耦合 Segment）。
- 非悬停显示缩略图（`ThumbnailCache`）。
- **本地单播协调**：工作区一条轨道 + 版本区多张卡都可 hover，必须只有一个在播——在 `ShotEditViewModel` 加 `playingID: UUID?`（当前在播卡片 id），`RangeVideoPlayer` 开播前置为自己、别的卡见 id 不符即停，避免多卡同时出声。
- **hover 事件挂稳定外层容器**（复刻 `SegmentInlinePlayer` 修过的坑：hover 挂顶层而非条件分支，否则鼠标移到另一张卡会卡住不切）。
- 用于：
  - 分镜头轨道每个镜头卡 → 播源视频 `[shot.start/fps, shot.end/fps]`。
  - 版本区「原版」卡 → 同上（该镜头源区间）。
  - 版本区「变体」卡 → 播变体结果片整段（`resultVideoPath`，0..其时长）。

---

## 6. UI（ShotEditSheet 升级）

**分镜头轨道**（横向，9:16）：
- 每镜头 = `RangeVideoPlayer`（悬停播）+ 时长 + 资格标记（超限置灰）+ 选中框。
- **相邻镜头之间**：一个分界区，含
  - 可**拖动**的分界手柄（拖动 = `moveBoundary`，实时 clamp）；
  - 「**合并**」按钮（合并这两镜头）。
- 选中某镜头时，下方出一行**帧级微调**（`−帧 / +帧`，对齐外层 `BoundaryAdjustRow` 手感）调它与相邻的边界；以及「**拆分**」按钮（**在该镜头中点拆分**——工作区无持久播放头概念，固定中点即可，后续如需可点选帧位再加）。

**版本区**：`RangeVideoPlayer` 化的「原版」+ 各变体卡（悬停播），单选逻辑不变。

**交互**：所有编辑即时写库、即时刷新轨道/资格/缩略图；变动镜头的变体被清除会有轻提示（如"该镜头已调整，原变体已失效"）。9:16 铁律。

---

## 7. 非目标（YAGNI）

- 不改外层分镜边界（分区只在分镜内部动，贴合外层 `[start,end]`）。
- 不做多级撤销（依赖即时持久化；误操作可重新合并/拆分）。
- 不在此实现"跨分镜"的镜头移动。

---

## 8. 测试策略

- **纯逻辑单测**（MixCutCore）：`ShotPartitionEditor` 的 merge/move/split/clamp/不变式，见 §3。
- **人工验收（app 内）**：
  1. 进工作区，悬停每个分镜头**能播**、看清切分；版本区原版/变体可播。
  2. 合并镜头1+2 → 变一个镜头、时长相加、可能过 2s 变可编辑；总时长不变。
  3. 拆分一个镜头 → 两段、和不变。
  4. 拖动/±帧移动边界 → 两侧无缝、clamp 生效、总时长不变。
  5. 调整过的镜头若已有变体 → 变体自动失效清除 + 缩略图重生；未动的镜头变体保留。
  6. 合成后外层分镜"替换画面"与原分镜**等长**（因分区总长恒等于分镜时长，音画对齐前提成立）。
  7. 既有：生成变体/占位选择/合成/切换画面 不回归。
