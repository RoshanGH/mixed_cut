# 分镜头工作区：可播放 + 可调整 Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给「分镜头替换」工作区加：每个分镜头/版本悬停可播放；分镜头可合并/拆分/拖动+±帧移动边界。核心不变式=所有分镜头恒无缝铺满外层分镜、总长恒等于分镜时长。

**Architecture:** 纯分区编辑逻辑放 `Sources/MixCutCore/ShotPartitionEditor`（切分点建模，TDD）；`ShotEditViewModel` 应用到 `PhysicalShot` 并按 (start,end) 相等对账、失效变动镜头的变体、并作废外层替换画面；新增解耦的 `RangeVideoPlayer` 悬停播放组件；`ShotEditSheet` 升级轨道（可播 + 分界手柄/合并/拆分/帧微调）。

**Tech Stack:** Swift 5.10 / SwiftUI / SwiftData / macOS 14；Swift Testing（MixCutCore）；xcodebuild（app）。

**参考 spec：** `docs/superpowers/specs/2026-07-06-shot-workspace-play-and-edit-design.md`

---

## ⚠️ 执行前必读
1. 不自动 git 提交；feature 分支。2. 改 UI 必编译+重启+截图自测。3. MixCutCore 用 `swift test`。4. 9:16 铁律。5. 勿破坏工作区既有：生成变体/占位选择/合成/切换画面。

---

## Phase 1：ShotPartitionEditor（MixCutCore，TDD）

### Task 1: 分区编辑纯逻辑

**Files:** Create `Sources/MixCutCore/ShotPartitionEditor.swift`、`Tests/MixCutCoreTests/ShotPartitionEditorTests.swift`

- [ ] **Step 1: 失败测试**
```swift
import Testing
@testable import MixCutCore

struct ShotPartitionEditorTests {
    private func spans(_ pairs: [(Int, Int)]) -> [ShotSpan] { pairs.map { ShotSpan(startFrame: $0.0, endFrame: $0.1) } }

    @Test("合并相邻：无缝、总长不变、边界不动")
    func merge() {
        let r = ShotPartitionEditor.merge(spans([(0,90),(90,165),(165,240)]), at: 0)
        #expect(r == spans([(0,165),(165,240)]))
        #expect(r.first?.startFrame == 0 && r.last?.endFrame == 240)
    }

    @Test("移动边界：clamp 到最小帧数内、两侧无缝")
    func moveBoundary() {
        let base = spans([(0,90),(90,240)])
        let r = ShotPartitionEditor.moveBoundary(base, boundaryIndex: 0, toFrame: 150, minFrames: 5)
        #expect(r == spans([(0,150),(150,240)]))
        // 越界被 clamp（不能小于 start+min，也不能大于下一段 end-min）
        let lo = ShotPartitionEditor.moveBoundary(base, boundaryIndex: 0, toFrame: -10, minFrames: 5)
        #expect(lo[0].endFrame == 5)
        let hi = ShotPartitionEditor.moveBoundary(base, boundaryIndex: 0, toFrame: 9999, minFrames: 5)
        #expect(hi[0].endFrame == 235)   // 240-5
    }

    @Test("拆分中点：两段和=原段、无缝")
    func split() {
        let r = ShotPartitionEditor.split(spans([(0,240)]), at: 0, atFrame: 120)
        #expect(r == spans([(0,120),(120,240)]))
    }

    @Test("拆分点过近端点（<minFrames）→ 原样返回")
    func splitTooClose() {
        let base = spans([(0,240)])
        #expect(ShotPartitionEditor.split(base, at: 0, atFrame: 2, minFrames: 5) == base)
    }

    @Test("任何操作后 首尾边界 = 原分区首尾")
    func endpointsInvariant() {
        let base = spans([(0,90),(90,240)])
        #expect(ShotPartitionEditor.merge(base, at: 0).first?.startFrame == 0)
        #expect(ShotPartitionEditor.merge(base, at: 0).last?.endFrame == 240)
    }
}
```

- [ ] **Step 2: 跑失败** — `swift test --filter ShotPartitionEditor`

- [ ] **Step 3: 实现** `Sources/MixCutCore/ShotPartitionEditor.swift`
```swift
import Foundation

public struct ShotSpan: Equatable, Sendable {
    public let startFrame: Int
    public let endFrame: Int
    public init(startFrame: Int, endFrame: Int) { self.startFrame = startFrame; self.endFrame = endFrame }
    public var frameCount: Int { max(0, endFrame - startFrame) }
}

/// 分镜头分区编辑（切分点建模）。所有操作保持无缝铺满 + 首尾边界不变。
public enum ShotPartitionEditor {
    public static let defaultMinFrames = 5

    /// 合并 i 与 i+1
    public static func merge(_ shots: [ShotSpan], at i: Int) -> [ShotSpan] {
        guard i >= 0, i + 1 < shots.count else { return shots }
        var out = shots
        let merged = ShotSpan(startFrame: shots[i].startFrame, endFrame: shots[i + 1].endFrame)
        out.replaceSubrange(i...(i + 1), with: [merged])
        return out
    }

    /// 移动第 b 个切分点（shots[b].end == shots[b+1].start）到 f，clamp
    public static func moveBoundary(_ shots: [ShotSpan], boundaryIndex b: Int, toFrame f: Int,
                                    minFrames: Int = defaultMinFrames) -> [ShotSpan] {
        guard b >= 0, b + 1 < shots.count else { return shots }
        let lo = shots[b].startFrame + minFrames
        let hi = shots[b + 1].endFrame - minFrames
        guard hi >= lo else { return shots }
        let nf = min(max(f, lo), hi)
        var out = shots
        out[b] = ShotSpan(startFrame: shots[b].startFrame, endFrame: nf)
        out[b + 1] = ShotSpan(startFrame: nf, endFrame: shots[b + 1].endFrame)
        return out
    }

    /// 拆分镜头 i：在 f 处一分为二（f 需落在合法区间，否则原样）
    public static func split(_ shots: [ShotSpan], at i: Int, atFrame f: Int,
                             minFrames: Int = defaultMinFrames) -> [ShotSpan] {
        guard i >= 0, i < shots.count else { return shots }
        let s = shots[i]
        guard f >= s.startFrame + minFrames, f <= s.endFrame - minFrames else { return shots }
        var out = shots
        out.replaceSubrange(i...i, with: [ShotSpan(startFrame: s.startFrame, endFrame: f),
                                          ShotSpan(startFrame: f, endFrame: s.endFrame)])
        return out
    }

    /// 中点拆分便捷
    public static func splitAtMidpoint(_ shots: [ShotSpan], at i: Int,
                                       minFrames: Int = defaultMinFrames) -> [ShotSpan] {
        guard i >= 0, i < shots.count else { return shots }
        let s = shots[i]
        return split(shots, at: i, atFrame: (s.startFrame + s.endFrame) / 2, minFrames: minFrames)
    }
}
```

- [ ] **Step 4: 跑通过** — `swift test --filter ShotPartitionEditor` 全 PASS
- [ ] **Step 5: 全套回归** — `swift test`（不碰坏其它）
- [ ] **Step 6: 检查点**

---

## Phase 2：Segment.invalidateReplacedPicture 抽取

### Task 2: 抽公共失效方法

**Files:** Modify `MixCut/Models/Segment.swift`

- [ ] **Step 1:** 抽方法：
```swift
/// 作废就地替换画面（改边界 / 调整分镜头时调用）。文件留给孤儿 GC 回收。
func invalidateReplacedPicture() {
    replacedPictureVideoPath = nil
    replacedPictureThumbnailPath = nil
    replacedPictureFrameCount = 0
    pictureShowsReplaced = false
}
```
- [ ] **Step 2:** `setFrameRange` 里那段清理改为调用 `invalidateReplacedPicture()`（行为不变）。
- [ ] **Step 3: 编译** → SUCCEEDED
- [ ] **Step 4: 检查点**

---

## Phase 3：ShotEditViewModel 应用编辑 + 对账 + 失效

### Task 3: 编辑操作 + 单播 id

**Files:** Modify `MixCut/ViewModels/ShotEditViewModel.swift`

- [ ] **Step 1: 加单播 id** — `var playingID: UUID?`（当前在播卡片；供 RangeVideoPlayer 协调）。
- [ ] **Step 2: 离散动作 merge/split → applyPartition（改变镜头数）**
```swift
func mergeShots(at i: Int, segment: Segment, modelContext: ModelContext) {
    applyPartition(ShotPartitionEditor.merge(currentSpans(), at: i), segment: segment, modelContext: modelContext)
}
func splitShot(at i: Int, segment: Segment, modelContext: ModelContext) {
    applyPartition(ShotPartitionEditor.splitAtMidpoint(currentSpans(), at: i), segment: segment, modelContext: modelContext)
}
private func currentSpans() -> [ShotSpan] {
    shots.sorted { $0.orderIndex < $1.orderIndex }.map { ShotSpan(startFrame: $0.startFrame, endFrame: $0.endFrame) }
}
```

- [ ] **Step 3: applyPartition 对账（核心）+ no-op 早返回**
```swift
private func applyPartition(_ newSpans: [ShotSpan], segment: Segment, modelContext: ModelContext) {
    // 【必做】no-op 守卫：分区没变就什么都不做（否则会误清合成好的替换画面）
    if newSpans == currentSpans() { return }
    let old = segment.physicalShots
    var reused = Set<UUID>()
    for (idx, span) in newSpans.enumerated() {
        if let match = old.first(where: { $0.startFrame == span.startFrame && $0.endFrame == span.endFrame && !reused.contains($0.id) }) {
            match.orderIndex = idx + 1
            reused.insert(match.id)
        } else {
            let s = PhysicalShot(orderIndex: idx + 1, startFrame: span.startFrame, endFrame: span.endFrame)
            s.parentSegment = segment
            modelContext.insert(s)
        }
    }
    for o in old where !reused.contains(o.id) { modelContext.delete(o) }  // 变体随 cascade 删；文件留 GC
    segment.invalidateReplacedPicture()   // 分区变了 → 作废外层替换画面
    try? modelContext.save()
    shots = segment.physicalShots.sorted { $0.orderIndex < $1.orderIndex }
    resetSelectionsToOriginal()
    Task { await ensureShotThumbnails(segment: segment, modelContext: modelContext) }
}
```
> 按 (start,end) 精确相等保留（含变体），否则删/建；未变动的镜头变体保留。

- [ ] **Step 4: 移动边界 = 拖动就地 + 松手提交（避免 ffmpeg 风暴/竞态）**
  拖动过程**只就地改两个相邻镜头的共享边界、保持 PhysicalShot 身份**，不删建/不 save/不重生缩略图；松手（或 ±帧单击）才一次性失效变体+作废替换画面+重生缩略图+save。
```swift
private var boundaryDirty = false

/// 拖动中：就地把第 b 个切分点移到 f（clamp 由纯函数算）。保持身份，不落库。
func dragBoundary(boundaryIndex b: Int, toFrame f: Int) {
    let sorted = shots.sorted { $0.orderIndex < $1.orderIndex }
    guard b >= 0, b + 1 < sorted.count else { return }
    let spans = ShotPartitionEditor.moveBoundary(
        sorted.map { ShotSpan(startFrame: $0.startFrame, endFrame: $0.endFrame) },
        boundaryIndex: b, toFrame: f)
    let nf = spans[b].endFrame
    guard nf != sorted[b].endFrame else { return }   // 没动（已到 clamp）→ 不脏
    sorted[b].endFrame = nf
    sorted[b + 1].startFrame = nf
    boundaryDirty = true
    shots = sorted   // 刷新 UI（身份不变）
}

/// 松手 / ±帧后提交：只对被动过的两镜头失效变体，作废替换画面，重生缩略图。
func endBoundaryEdit(boundaryIndex b: Int, segment: Segment, modelContext: ModelContext) {
    guard boundaryDirty else { return }
    boundaryDirty = false
    let sorted = shots.sorted { $0.orderIndex < $1.orderIndex }
    for idx in [b, b + 1] where idx < sorted.count {
        let s = sorted[idx]
        for v in s.variants {
            if let p = v.resultVideoPath { try? FileManager.default.removeItem(atPath: p) }
            if let t = v.thumbnailPath { try? FileManager.default.removeItem(atPath: t) }
            modelContext.delete(v)
        }
        s.selectedVariantID = nil
        s.thumbnailPath = nil   // 触发重生
    }
    segment.invalidateReplacedPicture()
    try? modelContext.save()
    shots = segment.physicalShots.sorted { $0.orderIndex < $1.orderIndex }
    resetSelectionsToOriginal()
    Task { await ensureShotThumbnails(segment: segment, modelContext: modelContext) }
}
```
> ±帧按钮 = 调一次 `dragBoundary(...,toFrame: 当前±1帧)` 立即接 `endBoundaryEdit(...)`。

- [ ] **Step 5: 编译** → SUCCEEDED
- [ ] **Step 6: 检查点**

---

## Phase 4：RangeVideoPlayer 悬停播放组件

### Task 4: 解耦的区间播放器

**Files:** Create `MixCut/Views/SegmentLibrary/RangeVideoPlayer.swift`

- [ ] **Step 1: 实现** — 参数 `videoPath/startTime/endTime/thumbnailPath?/playID: UUID` + `@Binding var playingID: UUID?`；9:16。
  - 非 hover：显示缩略图（`ThumbnailCache`）。
  - hover：`playingID = playID`；播 `[startTime,endTime]`（半帧对齐 + `forwardPlaybackEndTime` 到 end 定格，抽 `SegmentInlinePlayer.play` 精简版）。
  - **到 end 定格时不要把 `playingID` 置 nil**（否则自己的 `onChange` 会触发、把定格帧清回缩略图）——定格仍保持 `playingID == playID`，只有鼠标移开才清。复刻 `SegmentInlinePlayer` 的定格陷阱处理（SegmentLibraryView.swift:1191-1193）。
  - `onChange(of: playingID)`：若 != playID 则停并回缩略图（本地单播）。
  - **hover 修饰挂最外层容器**（非条件分支），复刻 `SegmentInlinePlayer` 防卡坑。
- [ ] **Step 2: 编译** → SUCCEEDED
- [ ] **Step 3: 检查点**

---

## Phase 5：ShotEditSheet UI 升级

### Task 5: 轨道可播 + 分界手柄/合并/拆分/帧微调 + 版本区可播

**Files:** Modify `MixCut/Views/SegmentLibrary/ShotEditSheet.swift`

- [ ] **Step 1: 轨道镜头卡改 RangeVideoPlayer** — 每镜头用 `RangeVideoPlayer(videoPath: 源, startTime: shot.startFrame/fps, endTime: shot.endFrame/fps, thumbnailPath: shot.thumbnailPath, playID: shot.id, playingID: $vm.playingID)`；保留时长/资格标记/选中框。
- [ ] **Step 2: 相邻镜头之间分界区** — 两卡之间放：可拖动手柄 + 「合并」小按钮（`vm.mergeShots(at: i)`）。
  - 拖动：`DragGesture().onChanged` → 换算像素位移到帧 → `vm.dragBoundary(boundaryIndex: i, toFrame:)`（**就地、实时、不落库**）；`.onEnded` → `vm.endBoundaryEdit(boundaryIndex: i, segment:, modelContext:)`（一次性失效+重生+save）。
- [ ] **Step 3: 选中镜头的帧微调 + 拆分** — 选中某镜头时下方一行：`−帧/+帧` + 「拆分」按钮（`vm.splitShot(at: i)` 中点拆）。
  - ±帧 = `vm.dragBoundary(boundaryIndex:toFrame: 当前±1)` 后立即 `vm.endBoundaryEdit(...)`。
  - **端点处理**：第 1 个镜头的**左边界** = 分镜起点、最后一个镜头的**右边界** = 分镜止点，**不可动**（不变式禁止）。UI 只暴露"可调的那侧边界"：第 1 镜头只调它与第 2 镜头之间的点，末镜头只调它与前一镜头之间的点；对端点方向禁用/隐藏按钮。
- [ ] **Step 4: 版本区可播** — 「原版」卡用 `RangeVideoPlayer`（源区间）；变体卡用 `RangeVideoPlayer(videoPath: resultVideoPath, startTime:0, endTime: 变体时长, playID: variant.id, ...)`（播整段）。单选逻辑不变。
- [ ] **Step 5: 变体失效轻提示** — 调整后若清了变体，`vm.errorMessage` 或 toast 提示"该镜头已调整，原变体已失效"。
- [ ] **Step 6: 编译 + 重启 + 截图自测** — 悬停每镜头能播、合并/拆分/拖动边界即时生效且总长不变、版本区可播、9:16。
- [ ] **Step 7: 检查点**

---

## Phase 5.5：孤儿 GC 纳管分镜头产物

### Task 5b: GC 扫 ShotVariants/ + ShotThumbnails/

**Files:** Modify `MixCut/Utilities/FileHelper.swift`（`collectOrphanFiles`）、`MixCut/App/MixCutApp.swift`（`runOrphanGC`）

> 调整分镜头会 cascade 删 `ShotVariant`（其 `resultVideoPath`/缩略图不随 cascade 删）+ 清 `PhysicalShot.thumbnailPath`。现有 `collectOrphanFiles` 只扫 Videos/Thumbnails/ReplacedPictures，**不扫 ShotVariants/、ShotThumbnails/** → 每次编辑泄漏文件。

- [ ] **Step 1: collectOrphanFiles 增扫** `ShotVariants/{hash}/{shotId}/*` 与 `ShotThumbnails/{hash}/*`（仿 ReplacedPictures 两级枚举；ShotVariants 是三级，注意多下一层）。
- [ ] **Step 2: runOrphanGC 加引用** — 遍历所有 Segment 的 `physicalShots`：加 `shot.thumbnailPath`、每个 `variant.resultVideoPath`/`variant.thumbnailPath` 到 referenced（非 nil 时）。
- [ ] **Step 3: 编译** → SUCCEEDED
- [ ] **Step 4: 检查点**

## Phase 6：验收

> **新文件登记 pbxproj**：`Sources/MixCutCore/ShotPartitionEditor.swift` 与 `MixCut/Views/SegmentLibrary/RangeVideoPlayer.swift` 必须加进 MixCut app target（用 ruby `xcodeproj` gem，仿之前脚本），否则链接失败。编译检查点会暴露，但先记住。

### Task 6: 全链路 + 人工验收

- [ ] **Step 1: MixCutCore 全绿** — `swift test`。
- [ ] **Step 2: 编译 + 重启** — 无崩。
- [ ] **Step 3: 人工验收（对照 spec §8）**
  1. 悬停每分镜头**能播**、看清切分；版本区原版/变体可播；同时只一个在播。
  2. 合并镜头1+2 → 一个镜头、时长相加、过 2s 变可编辑；总长不变。
  3. 拆分 → 两段、和不变。
  4. 拖动/±帧移动边界 → 两侧无缝、clamp、总长不变。
  5. 调整改动的镜头若已有变体 → 自动失效清除 + 缩略图重生；未动镜头变体保留。
  6. **合成后再回来调整分镜头 → 替换画面自动作废**（切换按钮消失、导出回原画面），不会导出陈旧合成片。
  7. 合成产物与外层分镜等长。
  8. 既有：生成/占位选择/合成/切换画面 不回归。
- [ ] **Step 4: 汇总** — 交用户复测清单。

---

## 附：改动点
| | 位置 |
|---|---|
| 分区纯逻辑 | `Sources/MixCutCore/ShotPartitionEditor.swift`（新） |
| 失效抽取 | `Segment.invalidateReplacedPicture()`（Segment.swift） |
| 编辑应用/对账/单播 | `ShotEditViewModel`（mergeShots/splitShot/moveBoundary/applyPartition/playingID） |
| 播放组件 | `RangeVideoPlayer.swift`（新，解耦 Segment） |
| 工作区 UI | `ShotEditSheet.swift`（轨道可播+分界手柄/合并/拆分/帧微调+版本区可播） |
