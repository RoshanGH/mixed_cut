import Foundation
import SwiftData

/// 分镜筛选条件
struct SegmentFilter {
    var semanticTypes: Set<SemanticType> = []
    var positionTypes: Set<PositionType> = []
    var sourceVideoID: UUID?
    var minQualityScore: Double = 0
    var searchText: String = ""
}

/// 按视频分组的分镜
struct VideoSegmentGroup: Identifiable {
    let video: Video
    let segments: [Segment]
    var id: UUID { video.id }
}

/// 分镜素材库 ViewModel
@MainActor
@Observable
final class SegmentLibraryViewModel {
    var segments: [Segment] = []
    var filteredSegments: [Segment] = []
    var selectedSegment: Segment?
    var filter = SegmentFilter()
    var sortByQuality = false
    var isGridView = true

    /// 微调后触发预览播放的回调信号
    var previewRequest: SegmentPreviewRequest?

    /// 当前正在播放的分镜 ID（全局唯一，确保只有一个播放）
    var playingSegmentID: UUID?

    /// 请求播放某个分镜（自动停止其他播放）
    func requestPlay(segment: Segment, from startTime: Double? = nil, to endTime: Double? = nil) {
        let from = startTime ?? segment.startTime
        let to = endTime ?? segment.endTime
        playingSegmentID = segment.id
        previewRequest = SegmentPreviewRequest(
            segmentID: segment.id,
            from: from,
            to: to
        )
    }

    /// 停止当前播放
    func stopCurrentPlayback() {
        playingSegmentID = nil
    }

    private var modelContext: ModelContext?

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    /// 加载项目的所有分镜
    func loadSegments(for project: Project) {
        // 重载前先把待删除项真正删除，避免「界面已隐藏但数据库未删」在重载后又冒出来
        PendingDeletionCenter.shared.flushNow()
        // 切项目铁律：清空多选 / 预览 / 选中状态（避免 A 项目状态残留到 B）
        selectedSegment = nil
        isSelectionMode = false
        selectedSegmentIDs.removeAll()
        selectionOrderedIDs.removeAll()
        previewRequest = nil
        playingSegmentID = nil

        var allSegments: [Segment] = []
        for video in project.videos {
            allSegments.append(contentsOf: video.segments)
        }
        segments = allSegments
        applyFilter()   // applyFilter 内部会调用 recomputeAllDerived
    }

    // MARK: - 批量导出多选

    /// 是否处于多选模式
    var isSelectionMode: Bool = false

    /// 已选分镜 ID 集合
    var selectedSegmentIDs: Set<UUID> = []

    /// 每视频内的分镜编号映射（按 startTime 升序，每视频独立 1-based）
    /// 缓存到 stored property，避免 SwiftUI 重绘时反复重算
    private(set) var numberByVideo: [UUID: [UUID: Int]] = [:]

    /// 取得分镜在所属视频内的编号；找不到返回 0
    func number(for segment: Segment) -> Int {
        guard let videoID = segment.video?.id else { return 0 }
        return numberByVideo[videoID]?[segment.id] ?? 0
    }

    /// 重新计算 numberByVideo（仅在 segments 变化时调用）
    private func recomputeNumberByVideo() {
        var result: [UUID: [UUID: Int]] = [:]
        var byVideo: [UUID: [Segment]] = [:]
        for seg in segments {
            guard let videoID = seg.video?.id else { continue }
            byVideo[videoID, default: []].append(seg)
        }
        for (videoID, segs) in byVideo {
            let sorted = segs.sorted { $0.startTime < $1.startTime }
            var map: [UUID: Int] = [:]
            for (i, seg) in sorted.enumerated() {
                map[seg.id] = i + 1
            }
            result[videoID] = map
        }
        numberByVideo = result
    }

    /// 用户勾选先后顺序（与 selectedSegmentIDs 同步维护）
    /// 注意：Set 本身无序，所以单独用一个 [UUID] 记录"第一次勾选 → 最后一次勾选"的顺序
    /// 给「组合为方案」用：用户期望按勾选顺序拼接，不是按视频+时间排序
    var selectionOrderedIDs: [UUID] = []

    func toggleSelection(_ segment: Segment) {
        if selectedSegmentIDs.contains(segment.id) {
            selectedSegmentIDs.remove(segment.id)
            selectionOrderedIDs.removeAll { $0 == segment.id }
        } else {
            selectedSegmentIDs.insert(segment.id)
            selectionOrderedIDs.append(segment.id)
        }
    }

    /// 全选当前筛选后可见的所有分镜（顺序 = 当前 filteredSegments 渲染顺序）
    func selectAllVisible() {
        let ids = filteredSegments.map(\.id)
        selectedSegmentIDs = Set(ids)
        selectionOrderedIDs = ids
    }

    /// 反选（针对当前筛选后可见的所有分镜）
    /// 反选后的顺序按 filteredSegments 渲染顺序重建（无法保留"勾选先后"语义）
    func invertSelectionVisible() {
        let visible = Set(filteredSegments.map(\.id))
        let newSelection = visible.subtracting(selectedSegmentIDs)
        selectedSegmentIDs = newSelection
        selectionOrderedIDs = filteredSegments.map(\.id).filter { newSelection.contains($0) }
    }

    func clearSelection() {
        selectedSegmentIDs.removeAll()
        selectionOrderedIDs.removeAll()
    }

    /// 进入/退出多选模式（退出时自动清空已选）
    func setSelectionMode(_ enabled: Bool) {
        isSelectionMode = enabled
        if !enabled {
            selectedSegmentIDs.removeAll()
            selectionOrderedIDs.removeAll()
        }
    }

    /// 当前已选的分镜列表（按视频 + startTime 排序）
    /// **用途：批量导出**（同一视频按时间走拼接顺序合理）
    /// 不要用于"组合为方案"，那个要用 orderedSelectedSegments
    var selectedSegments: [Segment] {
        let selected = segments.filter { selectedSegmentIDs.contains($0.id) }
        return selected.sorted { a, b in
            let aVid = a.video?.id.uuidString ?? ""
            let bVid = b.video?.id.uuidString ?? ""
            if aVid != bVid { return aVid < bVid }
            return a.startTime < b.startTime
        }
    }

    /// 当前已选的分镜列表（按"勾选先后顺序"）
    /// **用途：组合为方案**（用户期望按勾选顺序拼接）
    var orderedSelectedSegments: [Segment] {
        let lookup = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        return selectionOrderedIDs.compactMap { lookup[$0] }
    }

    /// 每个语义类型对应的镜头数量（基于全部 segments，不随筛选变化）
    /// 缓存到 stored property
    private(set) var countByType: [SemanticType: Int] = [:]

    /// 按视频分组的筛选结果
    /// 缓存到 stored property（每次 filteredSegments 变化时重算）
    private(set) var groupedSegments: [VideoSegmentGroup] = []

    /// 数据变化时统一重算所有派生属性
    private func recomputeAllDerived() {
        // 1) countByType（基于全部 segments）
        var counts: [SemanticType: Int] = [:]
        for type in SemanticType.allCases { counts[type] = 0 }
        for seg in segments {
            for t in seg.semanticTypes {
                counts[t, default: 0] += 1
            }
        }
        countByType = counts

        // 2) numberByVideo（基于全部 segments）
        recomputeNumberByVideo()

        // 3) groupedSegments（基于 filteredSegments）
        recomputeGroupedSegments()
    }

    private func recomputeGroupedSegments() {
        var videoMap: [UUID: (video: Video, segments: [Segment])] = [:]
        var videoOrder: [UUID] = []
        for seg in filteredSegments {
            guard let video = seg.video else { continue }
            if videoMap[video.id] == nil {
                videoMap[video.id] = (video: video, segments: [])
                videoOrder.append(video.id)
            }
            videoMap[video.id]?.segments.append(seg)
        }
        groupedSegments = videoOrder.compactMap { id in
            guard let entry = videoMap[id] else { return nil }
            return VideoSegmentGroup(video: entry.video, segments: entry.segments)
        }
    }

    /// 应用筛选条件
    func applyFilter() {
        var result = segments

        if !filter.semanticTypes.isEmpty {
            result = result.filter { seg in
                seg.semanticTypes.contains(where: { filter.semanticTypes.contains($0) })
            }
        }

        if !filter.positionTypes.isEmpty {
            result = result.filter { filter.positionTypes.contains($0.positionType) }
        }

        if let videoID = filter.sourceVideoID {
            result = result.filter { $0.video?.id == videoID }
        }

        if filter.minQualityScore > 0 {
            result = result.filter { $0.qualityScore >= filter.minQualityScore }
        }

        if !filter.searchText.isEmpty {
            let query = filter.searchText.lowercased()
            result = result.filter {
                $0.text.lowercased().contains(query) ||
                $0.keywords.contains(where: { $0.lowercased().contains(query) })
            }
        }

        if sortByQuality {
            result.sort { $0.qualityScore > $1.qualityScore }
        } else {
            result.sort { $0.startTime < $1.startTime }
        }

        filteredSegments = result
        recomputeAllDerived()
    }

    /// 切换分镜的语义类型（多选：添加或移除）
    func toggleSemanticType(for segment: Segment, type: SemanticType) {
        modelContext?.undoManager?.setActionName("修改类型")
        var types = segment.semanticTypes
        if let idx = types.firstIndex(of: type) {
            // 移除，但至少保留一个类型
            if types.count > 1 {
                types.remove(at: idx)
            }
        } else {
            types.append(type)
        }
        segment.semanticTypes = types
        modelContext?.safeSave()
        applyFilter()
    }

    /// 更新分镜的位置类型
    func updatePositionType(for segment: Segment, to newType: PositionType) {
        modelContext?.undoManager?.setActionName("修改位置")
        segment.positionType = newType
        modelContext?.safeSave()
        applyFilter()
    }

    /// 重置筛选
    func resetFilter() {
        filter = SegmentFilter()
        applyFilter()
    }

    // MARK: - 边界微调

    /// 调整开始帧（±frames），调整后从新起点播放预览
    func adjustStartFrame(for segment: Segment, by frames: Int) {
        guard let fps = segment.video?.fps, fps > 0 else { return }
        let newStart = max(0, segment.startFrame + frames)
        guard newStart < segment.endFrame - 1 else { return }
        modelContext?.undoManager?.setActionName("修改边界")
        segment.setFrameRange(startFrame: newStart, endFrame: segment.endFrame, fps: fps)
        reExtractText(for: segment)
        modelContext?.safeSave()

        let toFrame = min(newStart + Int((2 * fps).rounded()), segment.endFrame)
        requestPlay(segment: segment, from: segment.startTime, to: FrameTime.seconds(frame: toFrame, fps: fps))
    }

    /// 调整结束帧（±frames），调整后播放到结束
    func adjustEndFrame(for segment: Segment, by frames: Int) {
        guard let fps = segment.video?.fps, fps > 0 else { return }
        let maxFrame = segment.video.map { FrameTime.frame(seconds: $0.duration, fps: fps) } ?? Int.max
        let newEnd = min(maxFrame, segment.endFrame + frames)
        guard newEnd > segment.startFrame + 1 else { return }
        modelContext?.undoManager?.setActionName("修改边界")
        segment.setFrameRange(startFrame: segment.startFrame, endFrame: newEnd, fps: fps)
        reExtractText(for: segment)
        modelContext?.safeSave()

        let fromFrame = max(segment.startFrame, newEnd - Int(fps.rounded()))
        requestPlay(segment: segment, from: FrameTime.seconds(frame: fromFrame, fps: fps), to: segment.endTime)
    }

    /// 根据当前时间范围重新从 ASR 提取台词（中心点匹配，避免跨段重复）
    private func reExtractText(for segment: Segment) {
        guard let video = segment.video else { return }
        let words = video.asrWords
        let matched = words.filter { w in
            let center = (w.start + w.end) / 2
            return center >= segment.startTime && center < segment.endTime
        }
        let text = matched.map(\.word).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            segment.text = text
        }
    }

    /// 直接设置开始帧（输入框提交帧号）
    func setStartFrame(for segment: Segment, to newStart: Int) {
        guard let fps = segment.video?.fps, fps > 0 else { return }
        let clamped = max(0, newStart)
        guard clamped < segment.endFrame - 1 else { return }
        modelContext?.undoManager?.setActionName("修改边界")
        segment.setFrameRange(startFrame: clamped, endFrame: segment.endFrame, fps: fps)
        reExtractText(for: segment)
        modelContext?.safeSave()
        let toFrame = min(clamped + Int((2 * fps).rounded()), segment.endFrame)
        requestPlay(segment: segment, from: segment.startTime, to: FrameTime.seconds(frame: toFrame, fps: fps))
    }

    /// 直接设置结束帧（输入框提交帧号）
    func setEndFrame(for segment: Segment, to newEnd: Int) {
        guard let fps = segment.video?.fps, fps > 0 else { return }
        let maxFrame = segment.video.map { FrameTime.frame(seconds: $0.duration, fps: fps) } ?? Int.max
        let clamped = min(maxFrame, max(0, newEnd))
        guard clamped > segment.startFrame + 1 else { return }
        modelContext?.undoManager?.setActionName("修改边界")
        segment.setFrameRange(startFrame: segment.startFrame, endFrame: clamped, fps: fps)
        reExtractText(for: segment)
        modelContext?.safeSave()
        let fromFrame = max(segment.startFrame, clamped - Int(fps.rounded()))
        requestPlay(segment: segment, from: FrameTime.seconds(frame: fromFrame, fps: fps), to: segment.endTime)
    }

    /// 删除分镜（延迟删除 + 撤销浮条：先隐藏，5 秒内可撤销，不撤才真删）
    func deleteSegment(_ segment: Segment) {
        guard modelContext != nil else { return }
        let id = segment.id
        if selectedSegment?.id == id { selectedSegment = nil }
        // 界面隐藏（不真删）
        segments.removeAll { $0.id == id }
        selectedSegmentIDs.remove(id)
        selectionOrderedIDs.removeAll { $0 == id }
        applyFilter()
        PendingDeletionCenter.shared.schedule(
            message: "已删除分镜",
            commit: { [weak self] in
                guard let context = self?.modelContext else { return }
                // 手动先删级联子项再删 Segment（避免自动级联的边角问题，与 deleteVideo 同款）
                for ss in Array(segment.schemeSegments) { context.delete(ss) }
                context.delete(segment)
                context.safeSave()
            },
            undo: { [weak self] in
                guard let self else { return }
                self.segments.append(segment)   // 放回（applyFilter 会按质量/时间重新排序，与顺序无关）
                self.applyFilter()
            }
        )
    }

    /// 批量删除当前选中的分镜（延迟删除 + 撤销浮条）
    func deleteSelectedSegments() {
        guard modelContext != nil else { return }
        let idsToDelete = selectedSegmentIDs
        let segs = segments.filter { idsToDelete.contains($0.id) }
        guard !segs.isEmpty else { return }
        // 界面隐藏（不真删）
        if let sel = selectedSegment?.id, idsToDelete.contains(sel) { selectedSegment = nil }
        segments.removeAll { idsToDelete.contains($0.id) }
        selectedSegmentIDs.removeAll()
        selectionOrderedIDs.removeAll()
        applyFilter()
        PendingDeletionCenter.shared.schedule(
            message: "已删除 \(segs.count) 个分镜",
            commit: { [weak self] in
                guard let context = self?.modelContext else { return }
                for seg in segs {
                    for ss in Array(seg.schemeSegments) { context.delete(ss) }
                    context.delete(seg)
                }
                context.safeSave()
            },
            undo: { [weak self] in
                guard let self else { return }
                self.segments.append(contentsOf: segs)
                self.applyFilter()
            }
        )
    }

    // MARK: - 阿里 ASR 重提取台词

    /// 正在用阿里 ASR 重提取台词的分镜（控制按钮 loading / 禁用）
    var busyASRSegmentIDs: Set<UUID> = []
    private let asrClient = QwenASRClient()
    private let asrFFmpeg = FFmpegRunner()

    /// 用阿里 paraformer 对单个分镜重识别，只更新 segment.text（whisper 流程不动）
    func reextractTranscript(_ segment: Segment, context: ModelContext) async {
        guard let video = segment.video, !video.localPath.isEmpty,
              FileManager.default.fileExists(atPath: video.localPath) else {
            ToastCenter.shared.show("找不到原视频文件", icon: "exclamationmark.triangle.fill", style: .warning)
            return
        }
        guard !busyASRSegmentIDs.contains(segment.id) else { return }
        busyASRSegmentIDs.insert(segment.id)
        defer { busyASRSegmentIDs.remove(segment.id) }

        let fps = video.fps > 0 ? video.fps : 30
        let start = Double(segment.startFrame) / fps
        let end = Double(segment.endFrame) / fps
        let pcmURL = FileHelper.tempDirectory.appendingPathComponent("asr-\(UUID().uuidString).pcm")
        defer { try? FileManager.default.removeItem(at: pcmURL) }

        do {
            try await asrFFmpeg.extractSegmentPCM(from: video.localPath, start: start, end: end, to: pcmURL.path)
            let text = try await asrClient.transcribe(pcmPath: pcmURL.path)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                ToastCenter.shared.show("未识别到语音，保留原台词", icon: "waveform.slash", style: .warning)
                return
            }
            segment.text = trimmed
            try? context.save()
            ToastCenter.shared.show("已用阿里 ASR 重提取台词", icon: "checkmark.circle.fill", style: .success)
        } catch {
            ToastCenter.shared.show("重提取失败：\(error.localizedDescription)", icon: "exclamationmark.triangle.fill", style: .warning, duration: 3.5)
        }
    }

    /// 统计信息
    var statistics: (total: Int, byType: [SemanticType: Int], avgQuality: Double) {
        var byType: [SemanticType: Int] = [:]
        for seg in segments {
            for t in seg.semanticTypes {
                byType[t, default: 0] += 1
            }
        }
        let avg = segments.isEmpty ? 0 : segments.reduce(0.0) { $0 + $1.qualityScore } / Double(segments.count)
        return (segments.count, byType, avg)
    }
}

/// 预览播放请求（用于微调后触发播放器跳转）
struct SegmentPreviewRequest: Equatable {
    let segmentID: UUID
    let from: Double
    let to: Double
}
