# TRD 06 · 分镜拆分（技术方案）

> 配套：[06-分镜拆分-PRD](./06-分镜拆分-PRD.md)。本文只讲怎么实现。随 Mac 端改动同步更新。

---

## 1. 核心：Segment 实体拆分（现有不存在，需新建）
现有 `ShotEdit` 里的 split 是"画面替换"内部对 `PhysicalShot` 的切合，**不新增/删除 Segment**，与本功能**无关**。本功能要新建"把一个 `Segment` 拆成两个 `Segment`"的能力。

---

## 2. 入口与前置拦截
- 分镜卡右键菜单新增「拆分」项。
- 点击时先查 `segment.schemeSegments`（该分镜在各方案里的占位记录）：
  - **非空** → 弹提示（含引用数量），`return`，不打开拆分弹窗。
  - 为空 → 打开拆分弹窗。

---

## 3. 拆分预览弹窗（帧级 seek 预览）
- SwiftUI `.sheet`：内嵌 `AVPlayer(AVPlayerItem(url: 分镜来源视频))`。
  - 来源视频：普通分镜取 `segment.video.localPath`；自建分镜的载体视频同理（无特殊）。
- **拖动手柄** → `player.seek(to: CMTime(value: 帧, timescale: fps), toleranceBefore: .zero, toleranceAfter: .zero)`，**零容差**保证画面精确到该帧。
- 显示：`时间 = String(format: "%.1fs", frame/fps)`、`帧号 = frame`（相对来源视频的绝对帧或相对分镜起点，与 `startFrame` 口径一致）。
- 手柄范围 **clamp** 到 `[segment.startFrame + minFrames, segment.endFrame - minFrames]`（`minFrames` 取如 `max(1, round(0.3*fps))`），保证两段都非空。
- 默认位置：分镜中点 `(startFrame + endFrame)/2`。

---

## 4. 拆分执行 `splitSegment(_ seg:atFrame cut:)`
帧为真相（`startFrame/endFrame`），秒为派生缓存（复用 `setFrameRange` 口径）。步骤：
1. `guard seg.schemeSegments.isEmpty`（双保险）。
2. **切两段**：
   - `A` = 复用原 `seg`，`setFrameRange(start: seg.startFrame, end: cut)`。
   - `B` = 新建 `Segment`，`video = seg.video`，`setFrameRange(start: cut, end: seg.endFrame)`，`segmentIndex` 顺延。
3. **清空 A 的衍生物**（A 内容变了，原衍生物失效）：
   - `seg.segmentDubs` 全删（cascade，含 `captionLines`）。
   - `seg.physicalShots` + 其 `ShotVariant` 全删（cascade）。
   - `seg.invalidateReplacedPicture()`（清 `replacedPictureVideoPath / thumbnail / frameCount`，`pictureShowsReplaced = false`）。
   - `B` 为新建，天然无衍生物。
4. **缩略图**：A、B 各自重抽首帧（9:16）→ `thumbnailPath`。
5. **台词**：A、B 各自对**自己帧窗**切出音频 → **阿里 paraformer 重识别**（复用现有 `reidentifySegmentTexts` 的"切时间窗音频 + `QwenASRClient.transcribe(pcmPath:)`"模式）→ 写各自 `text`。异步、带处理态；失败则该段 `text` 留空 + 可重试，不回滚拆分。
6. **语义标签**：`B` 继承 `seg` 的 `semanticTypes / positionType / keywords`；`A` 保留原值。
7. `context.save()`；分镜库刷新（`recomputeGroupedSegments` + `numberByVideo` 按 `startTime` 重排编号）。

---

## 5. 关键约束
- **不可撤销**：拆分删除了衍生物，PRD 明确不可恢复。因此拆分**不入 undo**（或入 undo 也只恢复结构、不恢复已删衍生物——为避免误导，建议不提供撤销）。
- **schemeSegment 悬空防护**：靠 §2 的前置拦截保证——已在方案里的分镜根本进不了拆分，不会产生悬空引用。
- **自建分镜**：其来源=载体视频，拆分逻辑完全一致，无特殊分支。
- **最小段**：§3 的手柄 clamp 已保证；`splitSegment` 再兜底 `guard cut > seg.startFrame && cut < seg.endFrame`。

---

## 6. 落地清单（Windows）
- [ ] 右键「拆分」+ `schemeSegments` 非空拦截提示。
- [ ] 拆分弹窗：`AVPlayer` 帧级零容差 `seek` 预览 + 拖动手柄 + 时间/帧显示 + 手柄 clamp。
- [ ] `splitSegment`：帧切两段（A 复用 / B 新建）+ 清空 A 衍生物 + 各自重抽缩略图 + 各自阿里 ASR 重识别 + B 继承标签 + 保存 + 编号重排。
- [ ] 最小段限制；重识别失败不回滚；不提供撤销。
