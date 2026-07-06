import Foundation
import SwiftData

/// 分镜头替换工作区的 VM：切分镜头 / 帧级微调 / 生成变体 / 占位选择 / 就地替换画面。
@MainActor
@Observable
final class ShotEditViewModel {
    // 服务
    private let slicer: ShotSlicerService
    private let variantService: ShotVariantService
    private let compositionService: ShotCompositionService

    // 可观察状态
    var shots: [PhysicalShot] = []                 // 当前分镜的分镜头（按 orderIndex 升序）
    var selections: [Int: SlotChoice] = [:]        // orderIndex -> 选定版本（默认 original）
    var busyVariantIDs: Set<UUID> = []             // 正在生成的变体 id（防重入 + UI 转圈）
    var progress: [UUID: String] = [:]             // 变体 id -> 状态文案
    var isSlicing = false
    var isComposing = false
    var errorMessage: String?
    var playingID: UUID?                            // 当前在播卡片（工作区本地单播协调）
    private var boundaryDirty = false               // 拖动边界是否真的动过（松手才提交）

    init(slicer: ShotSlicerService = ShotSlicerService(),
         variantService: ShotVariantService = ShotVariantService(),
         compositionService: ShotCompositionService = ShotCompositionService()) {
        self.slicer = slicer
        self.variantService = variantService
        self.compositionService = compositionService
    }

    // MARK: - 加载 / 切分镜头

    /// 进入工作区：已切过直接展示；没切过则按需切分并持久化。
    func loadShots(for segment: Segment, modelContext: ModelContext) async {
        errorMessage = nil
        let existing = segment.physicalShots.sorted { $0.orderIndex < $1.orderIndex }
        if !existing.isEmpty {
            shots = existing
            loadSelectionsFromShots()
            await ensureShotThumbnails(segment: segment, modelContext: modelContext)
            return
        }
        guard let video = segment.video, video.fps > 0 else {
            errorMessage = "该分镜缺少视频/帧率信息，无法切分镜头"
            return
        }
        isSlicing = true
        defer { isSlicing = false }
        do {
            let ranges = try await slicer.computeShots(
                videoPath: video.localPath,
                segmentStart: segment.startTime,
                segmentEnd: segment.endTime,
                fps: video.fps
            )
            for r in ranges {
                let shot = PhysicalShot(orderIndex: r.orderIndex, startFrame: r.startFrame, endFrame: r.endFrame)
                shot.parentSegment = segment
                modelContext.insert(shot)
            }
            try? modelContext.save()
            shots = segment.physicalShots.sorted { $0.orderIndex < $1.orderIndex }
            loadSelectionsFromShots()
            await ensureShotThumbnails(segment: segment, modelContext: modelContext)
        } catch {
            errorMessage = "分镜头切分失败：\(error.localizedDescription)"
        }
    }

    /// 从持久化的 PhysicalShot.selectedVariantID 恢复选择状态（重开工作区/调整后保持）。
    private func loadSelectionsFromShots() {
        var sel: [Int: SlotChoice] = [:]
        for s in shots {
            if let vid = s.selectedVariantID,
               s.variants.contains(where: { $0.id == vid && $0.status == .completed }) {
                sel[s.orderIndex] = .variant(vid)
            } else {
                sel[s.orderIndex] = .original
            }
        }
        selections = sel
    }

    /// 为缺缩略图的分镜头生成首帧缩略图（原画面），让轨道可预览。
    private func ensureShotThumbnails(segment: Segment, modelContext: ModelContext) async {
        guard let video = segment.video, video.fps > 0, let hash = video.contentHash else { return }
        let ffmpeg = FFmpegRunner()
        for shot in shots {
            let existingOK = shot.thumbnailPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
            if existingOK { continue }
            let url = FileHelper.shotThumbnailURL(videoHash: hash, shotId: shot.id)
            let at = Double(shot.startFrame) / video.fps
            do {
                try await ffmpeg.generateThumbnail(from: video.localPath, at: at, to: url.path)
                shot.thumbnailPath = url.path
            } catch { /* 缩略图失败不阻塞，保留占位 */ }
        }
        try? modelContext.save()
        // 触发视图刷新（缩略图路径已更新）
        shots = segment.physicalShots.sorted { $0.orderIndex < $1.orderIndex }
    }

    // MARK: - 帧级微调

    private func currentSpans() -> [ShotSpan] {
        shots.sorted { $0.orderIndex < $1.orderIndex }.map { ShotSpan(startFrame: $0.startFrame, endFrame: $0.endFrame) }
    }

    /// 合并 i 与 i+1（改变镜头数 → applyPartition）
    func mergeShots(at i: Int, segment: Segment, modelContext: ModelContext) {
        applyPartition(ShotPartitionEditor.merge(currentSpans(), at: i), segment: segment, modelContext: modelContext)
    }
    /// 中点拆分镜头 i
    func splitShot(at i: Int, segment: Segment, modelContext: ModelContext) {
        applyPartition(ShotPartitionEditor.splitAtMidpoint(currentSpans(), at: i), segment: segment, modelContext: modelContext)
    }

    /// 分区对账（按 (start,end) 相等保留，否则删/建）+ no-op 早返回 + 作废替换画面。
    private func applyPartition(_ newSpans: [ShotSpan], segment: Segment, modelContext: ModelContext) {
        guard newSpans != currentSpans() else { return }   // no-op：不误清替换画面
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
        for o in old where !reused.contains(o.id) { modelContext.delete(o) }  // 变体随 cascade 删
        segment.invalidateReplacedPicture()
        try? modelContext.save()
        shots = segment.physicalShots.sorted { $0.orderIndex < $1.orderIndex }
        loadSelectionsFromShots()
        Task { await ensureShotThumbnails(segment: segment, modelContext: modelContext) }
    }

    /// 拖动中：就地把第 b 个切分点移到 f（保持 PhysicalShot 身份，不落库）。
    func dragBoundary(boundaryIndex b: Int, toFrame f: Int) {
        let sorted = shots.sorted { $0.orderIndex < $1.orderIndex }
        guard b >= 0, b + 1 < sorted.count else { return }
        let spans = ShotPartitionEditor.moveBoundary(
            sorted.map { ShotSpan(startFrame: $0.startFrame, endFrame: $0.endFrame) },
            boundaryIndex: b, toFrame: f)
        let nf = spans[b].endFrame
        guard nf != sorted[b].endFrame else { return }   // 已到 clamp → 不脏
        sorted[b].endFrame = nf
        sorted[b + 1].startFrame = nf
        boundaryDirty = true
        shots = sorted
    }

    /// 松手 / ±帧后提交：对动过的两镜头失效变体、作废替换画面、重生缩略图。
    func endBoundaryEdit(boundaryIndex b: Int, segment: Segment, modelContext: ModelContext) {
        guard boundaryDirty else { return }
        boundaryDirty = false
        let sorted = shots.sorted { $0.orderIndex < $1.orderIndex }
        for idx in [b, b + 1] where idx >= 0 && idx < sorted.count {
            let s = sorted[idx]
            for v in s.variants {
                if let p = v.resultVideoPath { try? FileManager.default.removeItem(atPath: p) }
                if let t = v.thumbnailPath { try? FileManager.default.removeItem(atPath: t) }
                modelContext.delete(v)
            }
            s.selectedVariantID = nil
            s.thumbnailPath = nil
        }
        segment.invalidateReplacedPicture()
        try? modelContext.save()
        shots = segment.physicalShots.sorted { $0.orderIndex < $1.orderIndex }
        loadSelectionsFromShots()
        Task { await ensureShotThumbnails(segment: segment, modelContext: modelContext) }
    }

    /// ±帧微调第 b 个切分点（一次性提交）
    func nudgeBoundary(boundaryIndex b: Int, deltaFrames: Int, segment: Segment, modelContext: ModelContext) {
        let sorted = shots.sorted { $0.orderIndex < $1.orderIndex }
        guard b >= 0, b + 1 < sorted.count else { return }
        dragBoundary(boundaryIndex: b, toFrame: sorted[b].endFrame + deltaFrames)
        endBoundaryEdit(boundaryIndex: b, segment: segment, modelContext: modelContext)
    }

    /// 分镜头时长（秒）
    func duration(of shot: PhysicalShot, fps: Double) -> Double {
        fps > 0 ? Double(shot.frameCount) / fps : 0
    }

    /// 是否可编辑（时长在 [2,10]）
    func isEditable(_ shot: PhysicalShot, fps: Double) -> Bool {
        ShotEditRules.isEditable(durationSeconds: duration(of: shot, fps: fps))
    }

    func ineligibleReason(_ shot: PhysicalShot, fps: Double) -> String? {
        ShotEditRules.ineligibleReason(durationSeconds: duration(of: shot, fps: fps))
    }

    // MARK: - 生成变体

    func generateVariant(shot: PhysicalShot, prompt: String, segment: Segment, modelContext: ModelContext) async {
        errorMessage = nil
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorMessage = "请输入提示词"; return }
        guard let video = segment.video, video.fps > 0, let hash = video.contentHash else {
            errorMessage = "缺少视频信息，无法生成"; return
        }
        guard isEditable(shot, fps: video.fps) else {
            errorMessage = ineligibleReason(shot, fps: video.fps) ?? "该分镜头不可编辑"; return
        }

        let variant = ShotVariant(prompt: trimmed)
        variant.status = .generating
        variant.shot = shot
        modelContext.insert(variant)
        try? modelContext.save()

        let vid = variant.id
        busyVariantIDs.insert(vid)
        progress[vid] = "生成中"
        defer { busyVariantIDs.remove(vid); progress[vid] = nil }

        do {
            let result = try await variantService.generate(
                sourceVideoPath: video.localPath,
                videoHash: hash,
                shotId: shot.id,
                variantId: vid,
                startFrame: shot.startFrame,
                endFrame: shot.endFrame,
                fps: video.fps,
                prompt: trimmed,
                onStatus: { [weak self] s in Task { @MainActor in self?.progress[vid] = s } }
            )
            variant.resultVideoPath = result.resultVideoPath
            variant.thumbnailPath = result.thumbnailPath
            variant.status = .completed
            try? modelContext.save()
        } catch {
            variant.status = .failed
            variant.friendlyError = APIErrorClassifier.friendly(error)
            try? modelContext.save()
            errorMessage = variant.friendlyError
        }
    }

    /// 删除一个变体（连带落盘文件）
    func deleteVariant(_ variant: ShotVariant, modelContext: ModelContext) {
        if let p = variant.resultVideoPath { try? FileManager.default.removeItem(atPath: p) }
        if let t = variant.thumbnailPath { try? FileManager.default.removeItem(atPath: t) }
        // 若正被某坑选中，回退为原版
        for (slot, choice) in selections {
            if case .variant(let id) = choice, id == variant.id { selections[slot] = .original }
        }
        modelContext.delete(variant)
        try? modelContext.save()
    }

    // MARK: - 占位选择

    func select(orderIndex: Int, choice: SlotChoice, modelContext: ModelContext) {
        selections[orderIndex] = choice
        // 持久化到 PhysicalShot.selectedVariantID，重开工作区仍保持
        if let shot = shots.first(where: { $0.orderIndex == orderIndex }) {
            switch choice {
            case .original: shot.selectedVariantID = nil
            case .variant(let id): shot.selectedVariantID = id
            }
            try? modelContext.save()
        }
    }

    var canCompose: Bool {
        ShotEditRules.canCompose(slotCount: shots.count, selections: selections)
    }

    // MARK: - 合成新分镜

    /// 合成 → 就地给原分镜挂一版可切换的替换画面（不新增分镜）。成功返回 true。
    @discardableResult
    func compose(segment: Segment, modelContext: ModelContext) async -> Bool {
        errorMessage = nil
        guard canCompose else { errorMessage = "每个分镜头位置都要选一个版本"; return false }
        guard let video = segment.video, video.fps > 0, let hash = video.contentHash else {
            errorMessage = "缺少视频信息"; return false
        }
        isComposing = true
        defer { isComposing = false }

        // 组装占位输入（按 orderIndex 升序）
        let ordered = shots.sorted { $0.orderIndex < $1.orderIndex }
        var slots: [ShotCompositionService.SlotInput] = []
        for s in ordered {
            var variantPath: String? = nil
            if case .variant(let id) = selections[s.orderIndex] ?? .original,
               let v = s.variants.first(where: { $0.id == id }),
               v.status == .completed, let p = v.resultVideoPath {
                variantPath = p
            }
            slots.append(.init(startFrame: s.startFrame, endFrame: s.endFrame, variantVideoPath: variantPath))
        }

        do {
            let result = try await compositionService.compose(
                sourceVideoPath: video.localPath,
                fps: video.fps,
                slots: slots,
                segmentStart: segment.startTime,
                segmentEnd: segment.endTime
            )
            // 移动合成片到替换画面目录 + 生成缩略图
            let destURL = FileHelper.replacedPictureURL(videoHash: hash, segmentId: segment.id)
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: URL(fileURLWithPath: result.compositeVideoPath), to: destURL)
            let thumbURL = FileHelper.replacedPictureThumbnailURL(videoHash: hash, segmentId: segment.id)
            try? await FFmpegRunner().generateThumbnail(from: destURL.path, at: 0.0, to: thumbURL.path)
            // 就地写回原分镜（不新增 Segment/Video）
            segment.replacedPictureVideoPath = destURL.path
            segment.replacedPictureThumbnailPath = thumbURL.path
            segment.replacedPictureFrameCount = result.totalFrames   // = 探测到的实际帧数
            segment.pictureShowsReplaced = true
            try? modelContext.save()
            return true
        } catch {
            errorMessage = "合成失败：\(error.localizedDescription)"
            return false
        }
    }
}
