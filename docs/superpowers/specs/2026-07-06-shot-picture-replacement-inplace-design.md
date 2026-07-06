# 分镜头 AI 画面替换：改为「就地可切换画面」 — 设计文档

> 日期：2026-07-06
> 状态：设计已与用户逐段对齐，待 spec 评审 → 用户复核 → writing-plans
> 关系：**修订并取代** `2026-07-03-shot-level-prompt-edit-design.md` 中「合成→新增分镜」相关部分（§3.4、§4.3、§8、Task 13b 相邻分组）。分镜头切分、变体生成、`wan2.7-videoedit`、Phase 0 结论、2–10s 资格、占位式选择等**仍然有效、不变**。

---

## 1. 变更背景

上一轮实现：分镜头替换合成后**新建一条 Segment**（`sourceSegmentID` 指回原分镜），与原分镜**并存**于分镜库。

**问题**：新增分镜会打乱后续排列组合的分镜数量与策略逻辑。

**新方案（就地替换、可切换）**：合成后**不新增分镜**，而是给**原分镜**挂一版"替换画面"（合成 mp4）。同一条分镜此时拥有**两版画面：原画面 + 替换画面**，卡片只展示当前生效的一版，提供**切换按钮**在两版间来回切；原画面始终保留 → 切回即恢复。

**关键正交性**：画面替换只换"视频画面"这一层。分镜的**音频、台词、字幕烧录参数（遮挡框/是否烧录/字号）、时长边界**全部属于分镜本身，**切换画面不影响它们**；配音/文案变体的排列组合是分镜内选项层级，与画面替换层级正交，照旧运作。因替换画面与原分镜**等长**，音画与字幕时间轴对齐。

---

## 2. 数据模型改动（`Segment`）

**移除**：`Segment.sourceSegmentID`（不再新增分镜，作废）。

**新增**（全局持久化，随共享 Segment）：
- `var replacedPictureVideoPath: String?` — 替换画面合成 mp4 路径；`nil` = 尚无替换画面。
- `var replacedPictureThumbnailPath: String?` — 替换画面缩略图。
- `var replacedPictureFrameCount: Int = 0` — 替换画面实际帧数（合成时探测存下，供帧区间消费点用）。
- `var pictureShowsReplaced: Bool = false` — 当前生效哪版（仅当有替换画面时有意义）。

**保留不变**：`video`(原源视频)、`startFrame/endFrame`(原画面在源视频的帧区间)、`thumbnailPath`(原画面缩略图)、`physicalShots`、`PhysicalShot`、`ShotVariant`。

---

## 3. 单一真源：分镜"当前生效画面"

在 `Segment` 上加一个解析属性，作为**所有消费点的唯一入口**：

```swift
struct EffectivePicture {
    let videoPath: String
    let startTime: Double     // 秒；替换版=0
    let endTime: Double       // 秒；替换版=duration
    let startFrame: Int       // 替换版=0
    let endFrame: Int         // 替换版=replacedPictureFrameCount
    let fps: Double           // 替换版 = frameCount/duration（其余=video.fps）
    let thumbnailPath: String?
    let isReplaced: Bool
}

extension Segment {
    var effectivePicture: EffectivePicture {
        if pictureShowsReplaced,
           let p = replacedPictureVideoPath,
           FileManager.default.fileExists(atPath: p) {
            let d = duration                     // = endTime-startTime（原分镜时长）
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

> 替换 mp4 是"整段独立片"，故替换版按 `0..duration` / `0..frameCount` 播/裁；原版仍按源视频的 `[startFrame,endFrame]`。两者时长相同 → 分镜的音频（仍取自原源/配音）逐帧对齐。

---

## 4. 消费点改造（全部改走 `effectivePicture`）

以下现直接读 `segment.video?.localPath` + `startFrame/endFrame`（或 `startTime/endTime`）的点，改为读 `segment.effectivePicture`：

| # | 位置 | 现状 → 改动 |
|---|---|---|
| 1 | **播放** `SegmentInlinePlayer.play`（`SegmentLibraryView.swift:1068-1088`） | 用 `effectivePicture.videoPath` + 生效区间播；`videoAspectRatio/segmentDuration`（`:919,:932`）读源处同理兜底。播放请求的默认区间：替换版用 `0..duration`（见下）。 |
| 2 | **播放请求** `requestPlay`（`SegmentLibraryViewModel.swift:38-47`）默认区间 | 卡片预览调用时，若替换版生效则 from/to = `0..duration`（可由播放器内部按 `effectivePicture` 决定，避免污染帧微调调用点）。 |
| 3 | **缩略图** `SegmentInlinePlayer.thumbnailView`（`:1046-1049`）、`SegmentCardCompact`（`Shared/SegmentCardCompact.swift:82-84`） | 读 `effectivePicture.thumbnailPath`（替换版显示替换缩略图）。 |
| 4 | **普通导出** `ExportInput.from`（`ExportService.swift:148-160`） | `(path,start,end)` 改用 `effectivePicture.videoPath` + `startTime/endTime`。 |
| 5 | **配音导出** `DubExportInput.from`（`DubExportService.swift:54/63/74`）构造 `DubSegmentSpec` | `videoPath/startFrame/endFrame/fps` 改用 `effectivePicture`（`renderSegment :215/:272` 与 `DubSegmentGraphBuilder` 无需改，吃到的就是生效画面）。字幕烧录/配音/BGM 全照旧（属分镜本身）。 |
| 6 | **单/批量导出** `VariantBatchExportService.swift:67-76` | 同 5，`DubSegmentSpec` 与 `.original(sourcePath:...)` 改用 `effectivePicture`。 |

> **帧微调（BoundaryAdjustRow）** 仍作用于**原画面**的源帧区间（定义分镜在源视频的时长/边界，属分镜本身）。
> **⚠️ 改边界后自动失效替换画面（防陈旧音频导出）**：一旦分镜边界（`setFrameRange`/帧微调）改变，替换画面的内嵌音频与长度即与新边界不符，若仍生效会导出错的音画。故**边界一旦改变 → 自动清除替换画面**（`replacedPictureVideoPath/Thumbnail/FrameCount = nil/0`、`pictureShowsReplaced=false`，并删对应文件），用户需重新进工作区合成。不用"非阻塞提示"兜（易被忽略）。实现落点：`Segment.setFrameRange` 或其调用点检测帧区间变化后清理。

> **播放缓存键**：`SegmentInlinePlayer` 用 `segment.video?.contentHash`（`SegmentLibraryView.swift:1105` 附近）作帧跳转缓存键；替换版生效时该键需改用 `effectivePicture` 的标识（如替换 mp4 路径），否则会用原画面缓存播错帧。改造 #1 时一并处理。

---

## 5. 合成逻辑改造（`ShotEditViewModel.compose`）

**去掉** `makeCompositeSegment`（建新 Video+Segment、`sourceSegmentID`、`sha256`、`copyVideoToGlobal`）。改为：

1. `ShotCompositionService.compose(...)` 产出合成 mp4（临时目录，**逻辑不变**）。
   > **关键耦合（勿破坏）**：本方案"切换画面不影响音频"依赖 `ShotCompositionService` **在合成时把原分镜音频 mux 回合成片**（现有 §8.4 步骤）。因此配音导出 `renderSegment` 的"保留原声"路径从合成片输入取到的就是原音频、无需改。未来若重构 compose，**必须保留这一 mux 原声步骤**，否则会静默破坏锁定/兜底音频导出。
2. 探测合成 mp4 实际帧数 `fc`（`ffprobe -count_frames`，复用 `ShotCompositionService` 已有探测或补一次）。
3. 把 mp4 移到 `FileHelper.replacedPictureURL(videoHash:segmentId:)`；生成缩略图到 `FileHelper.replacedPictureThumbnailURL(...)`。
4. 写回**原分镜**：`replacedPictureVideoPath` / `replacedPictureThumbnailPath` / `replacedPictureFrameCount = fc` / `pictureShowsReplaced = true`；`try? save()`。**不新增任何 Segment/Video。**
5. 再次合成 → 覆盖上述文件与字段（同一分镜只有一版替换画面）。

`ShotEditSheet` 里 `if await vm.compose(...) { dismiss() }` 改为按新返回（成功 Bool）。

**落盘**：`FileHelper` 新增 `replacedPictureURL(videoHash:segmentId:)` = `AppSupport/MixCut/ReplacedPictures/{videoHash}/{segmentId}.mp4` + 同目录 `.jpg` 缩略图。

---

## 6. UI 改动

**① 入口移到右键菜单**：`SegmentCard` 的 `.contextMenu`（`SegmentLibraryView.swift:595-638`）新增「**分镜头替换**」项 → 打开 `ShotEditSheet(segment:)`。
- 卡片是独立 struct，经 VM 传递：`SegmentLibraryViewModel` 加 `var shotEditRequestSegment: Segment?`（@Observable），菜单项设置它；父视图 `.sheet(item: $viewModel.shotEditRequestSegment)` 挂 `ShotEditSheet`。
- **移除**上一轮加的顶部工具栏「分镜头替换」按钮（`:290-307`）与 `@State shotEditSegment`（`:14`）、旧 `.sheet(item:$shotEditSegment)`（`:71-72`）。
- **回退**搜索框 `.frame(maxWidth: 420)`（`:251`，当初为给工具栏按钮腾位，现按钮已移走）。

**② 切换画面按钮**：`SegmentCard` 上加一个小胶囊按钮（仿方案卡 `SchemeDetailView.swift:447-473` 的 pill 范式），**仅当 `replacedPictureVideoPath != nil` 时显示**：
- 两态：`原画面` ↔ `替换画面`（显示当前生效版，点击翻转 `pictureShowsReplaced` 并 `save()`）。
- 切换后卡片缩略图/预览随 `effectivePicture` 变化。
- 可在菜单里附「删除替换画面」（清 4 个字段 + 删文件，回到只有原画面）。

**③ 右键菜单同时可加**「恢复原画面」（= 设 `pictureShowsReplaced=false`）作为便捷项（与切换按钮等效，可选）。

---

## 7. 回退/清理（上一轮遗留）

- 删 `Segment.sourceSegmentID`（`Segment.swift:85`）。
- `SegmentLibraryViewModel` 回退 Task 13b：`recomputeGroupedSegments`（`:209-232`）恢复为"按 `seg.video.id` 分组"；删 `orderGroupSegments`（`:236-249`）及 `displayVideo` 里的 `sourceSegmentID` 分支。
- **孤儿 GC**：`MixCutApp.runOrphanGC`（`:904-917`）的 referenced 路径集合**新增** `replacedPictureVideoPath` / `replacedPictureThumbnailPath`，避免被回收。
- **Schema**：删字段 + 加字段。库当前有恢复出的数据；若 SwiftData 轻量迁移不兼容 → 允许清库（用户已同意"老数据不要了"）。改前备份 `MixCut.store`。

---

## 8. 非目标（YAGNI）

- 不做"同一分镜保留多版替换画面随时切换"——只一版替换画面（原 ↔ 替换二态），重合成即覆盖。
- 不改分镜头切分/变体生成/`wan2.7-videoedit`/Phase 0 那些（沿用 2026-07-03）。
- 不改配音/文案变体的排列组合逻辑（那是另一份 spec：`2026-07-06-variant-combination-participation-design.md`）。
- 不改帧微调对源边界的语义。

---

## 9. 测试策略

- **纯逻辑**：`effectivePicture` 依赖 SwiftData `Segment`，不进 MixCutCore 纯单测；改由集成/人工验收。（`ShotSegmentationEngine`/`ShotEditRules`/`FrameCountAligner` 既有测试不受影响。）
- **人工验收（app 内，需一条已生成变体并合成过的分镜）**：
  1. 右键分镜卡 → 「分镜头替换」→ 工作区正常（切分/生成/占位选择照旧）。
  2. 合成 → **不新增分镜**（分镜总数不变）；该分镜卡出现「切换画面」按钮，默认显示替换画面。
  3. 点切换 → 卡片缩略图/内嵌预览在 原画面 ↔ 替换画面 间切换；台词/时长/字幕参数不变。
  4. 生效替换版时：普通导出、配音导出、单/批量导出**产出的画面 = 替换版**，音频/配音/字幕烧录照旧、音画同步。
  5. 切回原版 → 导出/预览恢复原画面。
  6. 排列组合分镜数量、策略、配音变体组合**完全不受影响**（分镜没多没少）。
  7. 切换项目联动、卡片既有能力（双击编辑/选中复制/删除/多选）不回归。
