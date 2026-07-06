# 分镜头 AI 画面替换 → 就地可切换画面（返工）Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把已实现的"合成→新增分镜"改成"就地给原分镜挂一版可切换的替换画面（原↔替换二态、可恢复、不新增分镜）"，让排列组合与配音变体逻辑完全不受影响。

**Architecture:** 给 `Segment` 加"当前生效画面"单一真源 `effectivePicture`，所有读分镜视频源的消费点（播放/缩略图/普通导出/配音导出/单批量导出）改走它；合成写回原分镜的替换画面字段而非建新分镜；改边界自动失效替换画面；入口移到分镜卡右键菜单 + 卡上加切换按钮；回退上一轮的新增分镜/相邻分组/工具栏按钮。

**Tech Stack:** Swift 5.10 / SwiftUI / SwiftData / macOS 14；xcodebuild（app 编译）。多数改动为 app 层，验证靠编译 + 人工自测。

**参考 spec：** `docs/superpowers/specs/2026-07-06-shot-picture-replacement-inplace-design.md`（修订自 `2026-07-03-shot-level-prompt-edit-design.md`）

---

## ⚠️ 执行前必读（同项目铁律）
1. 不自动 git 提交；在 feature 分支做。
2. 改 UI 后必须 编译 → `pkill -x MixCut; open <app>` → 截图/自测。
3. Schema 变更（删 `sourceSegmentID`、加 4 字段）前 `cp ~/Library/Application\ Support/MixCut/MixCut.store{,.bak}`；若 SwiftData 轻量迁移不兼容 → 删 `MixCut.store*`（用户已同意"老数据不要了"），app 会重建。
4. 勿破坏分镜卡既有能力（双击编辑台词/选中复制/在 Finder 显示/删除/多选）、切换项目联动。
5. app 编译：`xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build`；DerivedData：`/Users/menggang/Library/Developer/Xcode/DerivedData/MixCut-byytuggmhodpumcmwnwrtzwkmavr/`。

**这是返工**：涉及删已实现代码。不确定某段作用时先读 `git blame`，别误删相邻功能。

---

## 文件结构（改动清单）

- `MixCut/Models/Segment.swift` — 删 `sourceSegmentID`；加 4 字段 + `effectivePicture` 扩展；`setFrameRange` 加"改边界清替换画面"
- `MixCut/Utilities/FileHelper.swift` — 加 `replacedPictureURL`/`replacedPictureThumbnailURL`
- `MixCut/Services/ShotEdit/ShotCompositionService.swift` — `Result` 返回**探测到的**合成片实际帧数
- `MixCut/ViewModels/ShotEditViewModel.swift` — `compose` 改就地写回；删 `makeCompositeSegment`
- `MixCut/Views/SegmentLibrary/ShotEditSheet.swift` — `compose` 返回值适配
- `MixCut/Views/SegmentLibrary/SegmentLibraryView.swift` — 播放/缩略图/缓存键走 `effectivePicture`；右键菜单加入口；删工具栏按钮 + 回退 maxWidth；加切换按钮
- `MixCut/Views/Shared/SegmentCardCompact.swift` — 缩略图走 `effectivePicture`
- `MixCut/ViewModels/SegmentLibraryViewModel.swift` — 加 `shotEditRequestSegment`；回退 Task 13b 分组
- `MixCut/Services/Export/ExportService.swift` — `ExportInput.from` 走 `effectivePicture`
- `MixCut/Services/Export/DubExportService.swift` — `DubExportInput.from` 走 `effectivePicture`
- `MixCut/Services/Export/VariantBatchExportService.swift` — 同上
- `MixCut/App/MixCutApp.swift` — 孤儿 GC referenced 集合加 replacedPicture 两路径

---

## Phase 1：数据模型 + 落盘

### Task 1: Segment 字段 + effectivePicture + FileHelper 路径

**Files:** Modify `MixCut/Models/Segment.swift`、`MixCut/Utilities/FileHelper.swift`

- [ ] **Step 1: 备份库** — `cp ~/Library/Application\ Support/MixCut/MixCut.store{,.bak}`（不存在则跳过）。
- [ ] **Step 2: Segment 删旧字段 + 加新字段** — 删 `var sourceSegmentID: UUID?`（`:85`）；加：
```swift
// 就地画面替换（分镜头 AI 替换产物）；nil = 尚无替换画面
var replacedPictureVideoPath: String?
var replacedPictureThumbnailPath: String?
var replacedPictureFrameCount: Int = 0
var pictureShowsReplaced: Bool = false
```
- [ ] **Step 3: 加 effectivePicture 扩展**（Segment.swift 内或同文件 extension）：
```swift
struct EffectivePicture: Sendable {
    let videoPath: String
    let startTime: Double
    let endTime: Double
    let startFrame: Int
    let endFrame: Int
    let fps: Double
    let thumbnailPath: String?
    let isReplaced: Bool
}
extension Segment {
    var effectivePicture: EffectivePicture {
        if pictureShowsReplaced,
           let p = replacedPictureVideoPath,
           FileManager.default.fileExists(atPath: p) {
            let d = duration
            let fc = max(1, replacedPictureFrameCount)
            return EffectivePicture(videoPath: p, startTime: 0, endTime: d,
                                    startFrame: 0, endFrame: fc,
                                    fps: d > 0 ? Double(fc) / d : (video?.fps ?? 30),
                                    thumbnailPath: replacedPictureThumbnailPath, isReplaced: true)
        }
        return EffectivePicture(videoPath: video?.localPath ?? "",
                                startTime: startTime, endTime: endTime,
                                startFrame: startFrame, endFrame: endFrame,
                                fps: video?.fps ?? 30,
                                thumbnailPath: thumbnailPath, isReplaced: false)
    }
}
```
- [ ] **Step 4: FileHelper 加路径**（仿 `shotVariantURL`）：
```swift
static func replacedPictureURL(videoHash: String, segmentId: UUID) -> URL {
    let dir = appSupportDirectory.appendingPathComponent("ReplacedPictures", isDirectory: true)
        .appendingPathComponent(videoHash, isDirectory: true)
    ensureDirectory(at: dir)
    return dir.appendingPathComponent("\(segmentId.uuidString).mp4")
}
static func replacedPictureThumbnailURL(videoHash: String, segmentId: UUID) -> URL {
    let dir = appSupportDirectory.appendingPathComponent("ReplacedPictures", isDirectory: true)
        .appendingPathComponent(videoHash, isDirectory: true)
    ensureDirectory(at: dir)
    return dir.appendingPathComponent("\(segmentId.uuidString).jpg")
}
```
- [ ] **Step 5: 暂不要求整体编译过** — 删 `sourceSegmentID` 后，其两个引用文件会编译失败：`ShotEditViewModel.swift:242`（Task 3 修）和 `SegmentLibraryViewModel.swift:214/237/238/240`（Task 3 一并回退 Task13b）。**首个"BUILD SUCCEEDED"检查点在 Task 3 末尾**（那时两处引用都清掉）。本步只肉眼确认 Segment/FileHelper 自身语法无误。
- [ ] **Step 6: 检查点**（不 build）

### Task 2: 改边界自动失效替换画面（防陈旧音频导出）

**Files:** Modify `MixCut/Models/Segment.swift`（`setFrameRange`，`:172` 附近）

- [ ] **Step 1: setFrameRange 检测帧变化并清替换画面** —
```swift
func setFrameRange(startFrame: Int, endFrame: Int, fps: Double) {
    let changed = (startFrame != self.startFrame || endFrame != self.endFrame)
    self.startFrame = startFrame
    self.endFrame = endFrame
    self.startTime = FrameTime.seconds(frame: startFrame, fps: fps)
    self.endTime = FrameTime.seconds(frame: endFrame, fps: fps)
    // 边界变了 → 替换画面（内嵌原音频与长度）即失效，清除，避免导出错音画
    if changed && replacedPictureVideoPath != nil {
        replacedPictureVideoPath = nil
        replacedPictureThumbnailPath = nil
        replacedPictureFrameCount = 0
        pictureShowsReplaced = false
        // 文件留给孤儿 GC 回收（依赖 Task 7 让 GC 增扫 ReplacedPictures/，否则会泄漏）
    }
}
```
（保持原有 setFrameRange 其余逻辑；只加 changed 判断与清理。读原实现确认秒缓存回填方式后套用。）
- [ ] **Step 2: 暂不要求整体编译过**（首绿在 Task 3 末尾）；肉眼确认本改动语法无误。
- [ ] **Step 3: 检查点**（不 build）

---

## Phase 2：合成改为就地写回

### Task 3: ShotCompositionService 返回实际帧数 + compose 就地写回

**Files:** Modify `MixCut/Services/ShotEdit/ShotCompositionService.swift`、`MixCut/ViewModels/ShotEditViewModel.swift`、`MixCut/Views/SegmentLibrary/ShotEditSheet.swift`

- [ ] **Step 1: ShotCompositionService.compose 探测最终 mp4 实际帧数** — 在返回前用已有的 `probeFrameCount(finalURL.path)` 探测，`Result` 增加/替换为 `actualFrameCount`：
```swift
let actual = try await probeFrameCount(finalURL.path)   // 复用已有私有方法
return Result(compositeVideoPath: finalURL.path, totalFrames: actual, duration: duration)
```
（`totalFrames` 语义改为"探测到的实际帧数"，用于 effectivePicture。）
- [ ] **Step 2: ShotEditViewModel.compose 改就地写回** — 删 `makeCompositeSegment`（`:210`）及 `sha256`/建 Video/Segment；`compose` 改为：
```swift
@discardableResult
func compose(segment: Segment, modelContext: ModelContext) async -> Bool {
    errorMessage = nil
    guard canCompose else { errorMessage = "每个分镜头位置都要选一个版本"; return false }
    guard let video = segment.video, video.fps > 0, let hash = video.contentHash else {
        errorMessage = "缺少视频信息"; return false
    }
    isComposing = true; defer { isComposing = false }
    // …组装 slots（沿用现有逻辑）…
    do {
        let result = try await compositionService.compose(
            sourceVideoPath: video.localPath, fps: video.fps, slots: slots,
            segmentStart: segment.startTime, segmentEnd: segment.endTime)
        let destURL = FileHelper.replacedPictureURL(videoHash: hash, segmentId: segment.id)
        try? FileManager.default.removeItem(at: destURL)
        try FileManager.default.moveItem(at: URL(fileURLWithPath: result.compositeVideoPath), to: destURL)
        let thumbURL = FileHelper.replacedPictureThumbnailURL(videoHash: hash, segmentId: segment.id)
        try? await FFmpegRunner().generateThumbnail(from: destURL.path, at: 0.0, to: thumbURL.path)
        segment.replacedPictureVideoPath = destURL.path
        segment.replacedPictureThumbnailPath = thumbURL.path
        segment.replacedPictureFrameCount = result.totalFrames
        segment.pictureShowsReplaced = true
        try? modelContext.save()
        return true
    } catch {
        errorMessage = "合成失败：\(error.localizedDescription)"; return false
    }
}
```
（`compositionService` 已是 VM 成员；`FFmpegRunner` 直接用于缩略图。删掉 `import CryptoKit` 若不再用。）
- [ ] **Step 3: ShotEditSheet 适配返回值** — `ShotEditSheet.swift:71`：`if await vm.compose(segment: segment, modelContext: modelContext) { dismiss() }`（Bool）。
- [ ] **Step 4: 同批回退 Task 13b 分组（清掉另一处 `sourceSegmentID` 引用，才能编译过）** — 改 `MixCut/ViewModels/SegmentLibraryViewModel.swift`：
  - `recomputeGroupedSegments`（`:209-232`）恢复为按 `seg.video.id` 分组（删 `displayVideo` 里的 `sourceSegmentID` 分支 `:213-214`，直接用 `seg.video`）；
  - 删 `orderGroupSegments`（`:236-249`）及其调用（组内顺序恢复为 filteredSegments 顺序）；
  - 参照 git 里 Task 13b 之前的版本还原。
- [ ] **Step 5: 编译** → **首个 BUILD SUCCEEDED**（此时 `sourceSegmentID` 两处引用——compose 与分组——都已清除）
- [ ] **Step 6: 检查点**

---

## Phase 3：消费点改走 effectivePicture

### Task 4: 播放 + 缩略图 + 缓存键

**Files:** Modify `MixCut/Views/SegmentLibrary/SegmentLibraryView.swift`、`MixCut/Views/Shared/SegmentCardCompact.swift`

- [ ] **Step 1: 读现状** — 通读 `SegmentInlinePlayer`（`:901-1110`），列出它读 `segment.video`/`startTime`/`endTime`/`thumbnailPath`/`contentHash` 的点。
- [ ] **Step 2: 播放走 effectivePicture** — `play(from:to:)`（`:1068-1088`）：`videoPath` 用 `segment.effectivePicture.videoPath`；预览默认区间用 `effectivePicture.startTime/endTime`（替换版=0..duration）。`videoAspectRatio`/`segmentDuration`（`:919,:932`）读源处按 effectivePicture 兜底（宽高比仍可用 `video` 的，替换版等比）。
- [ ] **Step 3: 缓存键** — `:1105` 附近用 `contentHash` 作帧跳转缓存键处，改用能区分替换版的键（如 `effectivePicture.isReplaced ? effectivePicture.videoPath : (video?.contentHash ?? "")`）。
- [ ] **Step 4: 缩略图** — `thumbnailView`（`:1046-1049`）与 `SegmentCardCompact`（`:82-84`）读 `segment.effectivePicture.thumbnailPath`。
- [ ] **Step 5: 编译 + 重启 + 自测** — 播放/缩略图在原版下与改造前一致（无替换画面时 effectivePicture 回退原值，行为不变）。
- [ ] **Step 6: 检查点**

### Task 5: 三条导出路径走 effectivePicture

**Files:** Modify `ExportService.swift`、`DubExportService.swift`、`VariantBatchExportService.swift`

- [ ] **Step 1: 普通导出** — `ExportInput.from`（`ExportService.swift:148-160`）：`segments.append` 改用 `let ep = segment.effectivePicture; (path: ep.videoPath, start: ep.startTime, end: ep.endTime)`。宽高仍取 `video.width/height`。
- [ ] **Step 2: 配音导出** — `DubExportInput.from`（`DubExportService.swift:54/63/74`）三处构造 `DubSegmentSpec` 时 `videoPath/startFrame/endFrame/fps` 改用 `segment.effectivePicture` 的对应值；字幕/配音/BGM 字段不变。（`renderSegment:215/:272`、`DubSegmentGraphBuilder` 不改。）
- [ ] **Step 3: 单/批量导出** — `VariantBatchExportService.swift:67-76`：`DubSegmentSpec`（`:68`）与 `.original(sourcePath:startTime:endTime:)`（`:76`）都改用 `seg.effectivePicture`。
- [ ] **Step 4: 编译** → SUCCEEDED
- [ ] **Step 5: 检查点**（导出实际产出画面在 Phase 7 人工验收）

---

## Phase 4：UI（入口右键 + 切换按钮 + 回退）

### Task 6: 右键入口 + 切换按钮 + 移除工具栏按钮

**Files:** Modify `MixCut/Views/SegmentLibrary/SegmentLibraryView.swift`、`MixCut/ViewModels/SegmentLibraryViewModel.swift`

- [ ] **Step 1: VM 加请求字段** — `SegmentLibraryViewModel` 加 `var shotEditRequestSegment: Segment?`（@Observable 自动可观察）。
- [ ] **Step 2: 右键菜单加入口** — `SegmentCard` 的 `.contextMenu`（`:595-638`）加：
```swift
Button { viewModel.shotEditRequestSegment = segment } label: {
    Label("分镜头替换", systemImage: "wand.and.stars")
}
```
（放在"编辑台词"附近，Divider 之上。）
- [ ] **Step 3: sheet 改绑 VM 字段** — 把 `:71-72` 的 `.sheet(item: $shotEditSegment)` 改为 `.sheet(item: $viewModel.shotEditRequestSegment) { seg in ShotEditSheet(segment: seg) }`；删 `@State shotEditSegment`（`:14`）。
- [ ] **Step 4: 删顶部工具栏按钮 + 回退 maxWidth** — 删 `:290-307` 的「分镜头替换」Button；删 `:251` 的 `.frame(maxWidth: 420)`（恢复搜索框原样）。
- [ ] **Step 5: 卡上加「切换画面」按钮** — 在 `SegmentCard` 合适处（缩略图角标/卡片工具区），**仅当 `segment.replacedPictureVideoPath != nil`** 显示一个胶囊按钮（仿 `SchemeDetailView.swift:447-473` pill）：
```swift
if segment.replacedPictureVideoPath != nil {
    Button {
        segment.pictureShowsReplaced.toggle()
        try? modelContext.save()
    } label: {
        Label(segment.pictureShowsReplaced ? "替换画面" : "原画面",
              systemImage: "photo.on.rectangle.angled")
            .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(segment.pictureShowsReplaced ? Color.green.opacity(0.15) : Color.gray.opacity(0.12)))
    }.buttonStyle(.plain)
}
```
- [ ] **Step 6:（可选）右键加「删除替换画面」** — 清 4 字段 + 删文件（`replacedPictureURL`/缩略图），仅当存在时显示。
- [ ] **Step 7: 编译 + 重启 + 截图自测** — 右键出现「分镜头替换」；顶部无旧按钮；有替换画面的卡出现切换按钮、点击切换缩略图；9:16 比例。
- [ ] **Step 8: 回归自测** — 双击编辑台词/选中复制/在 Finder 显示/删除/多选、切换项目联动均正常。
- [ ] **Step 9: 检查点**

---

## Phase 5：回退遗留 + GC

### Task 7: 孤儿 GC 纳管 ReplacedPictures/

> Task 13b 分组回退已在 Task 3 Step 4 完成，此处不再重复。

**Files:** Modify `MixCut/Utilities/FileHelper.swift`（`collectOrphanFiles` `:221-243`）、`MixCut/App/MixCutApp.swift`（`runOrphanGC` `:904-917`）

- [ ] **Step 1: collectOrphanFiles 增扫 ReplacedPictures/** — 现有 `collectOrphanFiles` 只枚举 `globalVideoDirectory`(Videos/) 与 `globalThumbnailDirectory`(Thumbnails/)，**不扫 `ReplacedPictures/`** → 加对 `appSupportDirectory/ReplacedPictures/{hash}/*.mp4|*.jpg` 两级目录的枚举，纳入孤儿候选。**否则以下加引用是空操作、且改边界/删除后旧合成片永久泄漏。**
- [ ] **Step 2: runOrphanGC 加引用路径** — `runOrphanGC`（`:904-917`）收集 referenced 路径处，新增每个 Segment 的 `replacedPictureVideoPath` 与 `replacedPictureThumbnailPath`（非 nil 时加入），保护生效中的替换画面不被回收。
  - 效果：Task 2 改边界清字段后、Task 6 删除替换画面后，旧 `ReplacedPictures/*` 文件在下次启动 GC 被正确回收；生效中的被引用保护。
- [ ] **Step 3: 编译** → SUCCEEDED
- [ ] **Step 4: 检查点**

---

## Phase 6：端到端验收

### Task 8: 全链路 + 人工验收

- [ ] **Step 1: 全量编译 + 启动** — `xcodebuild … build` → 重启 → 无崩（若 schema 迁移崩 → 删 `MixCut.store*` 重启，用户已允许清库）。
- [ ] **Step 2: MixCutCore 回归** — `swift test`（本返工不动纯算法，应保持全绿）。
- [ ] **Step 3: 人工验收（app 内，取一条 2–10s、已生成过画面变体的分镜）**
  1. 右键分镜卡 → 「分镜头替换」→ 工作区正常（切分/生成变体/占位选择照旧）。
  2. 合成 → **分镜总数不变**（不新增分镜）；该卡出现「切换画面」按钮，默认显示替换画面。
  3. 切换按钮 原画面 ↔ 替换画面：卡片缩略图/内嵌预览随之切换；台词/时长/字幕参数不变。
  4. 生效替换版时：普通导出 / 配音导出 / 单批量导出 产出画面 = 替换版，音频/配音/字幕烧录照旧、音画同步。
  5. 切回原版 → 预览/导出恢复原画面。
  6. **改分镜边界（帧微调）→ 替换画面自动消失**（切换按钮消失、回到原画面），重进工作区可重合成。
  7. 排列组合分镜数量/策略、配音变体组合完全不受影响。
  8. 项目切换联动、卡片既有能力不回归。
- [ ] **Step 4: 汇总** — 列"已自测通过"与"需用户复测"清单交用户。

---

## 附：消费点对照（全部改走 `segment.effectivePicture`）

| 消费点 | 位置 |
|---|---|
| 播放 | `SegmentLibraryView.swift:1068-1088`(play) + 缓存键 `:1105` |
| 缩略图 | `SegmentLibraryView.swift:1046-1049`、`SegmentCardCompact.swift:82-84` |
| 普通导出 | `ExportService.swift:148-160` |
| 配音导出 | `DubExportService.swift:54/63/74`（renderSegment/graphBuilder 不改） |
| 单/批量导出 | `VariantBatchExportService.swift:67-76` |
| 入口/切换 UI | `SegmentLibraryView.swift` 右键菜单 `:595-638`、切换 pill 仿 `SchemeDetailView.swift:447-473` |
| 回退 | `sourceSegmentID`(Segment.swift)、Task13b(`SegmentLibraryViewModel.swift:209-249`)、工具栏按钮/maxWidth(`SegmentLibraryView.swift:251/290-307`) |
| GC | `MixCutApp.swift:904-917` |
