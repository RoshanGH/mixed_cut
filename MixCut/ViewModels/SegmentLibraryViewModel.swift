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

    func toggleSelection(_ segment: Segment) {
        if selectedSegmentIDs.contains(segment.id) {
            selectedSegmentIDs.remove(segment.id)
        } else {
            selectedSegmentIDs.insert(segment.id)
        }
    }

    /// 全选当前筛选后可见的所有分镜
    func selectAllVisible() {
        selectedSegmentIDs = Set(filteredSegments.map(\.id))
    }

    /// 反选（针对当前筛选后可见的所有分镜）
    func invertSelectionVisible() {
        let visible = Set(filteredSegments.map(\.id))
        let newSelection = visible.subtracting(selectedSegmentIDs)
        selectedSegmentIDs = newSelection
    }

    func clearSelection() {
        selectedSegmentIDs.removeAll()
    }

    /// 进入/退出多选模式（退出时自动清空已选）
    func setSelectionMode(_ enabled: Bool) {
        isSelectionMode = enabled
        if !enabled { selectedSegmentIDs.removeAll() }
    }

    /// 当前已选的分镜列表（按视频 + startTime 排序，导出时用）
    var selectedSegments: [Segment] {
        let selected = segments.filter { selectedSegmentIDs.contains($0.id) }
        return selected.sorted { a, b in
            let aVid = a.video?.id.uuidString ?? ""
            let bVid = b.video?.id.uuidString ?? ""
            if aVid != bVid { return aVid < bVid }
            return a.startTime < b.startTime
        }
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

    /// 调整开始时间（+/- step），调整后直接播放到对应时间
    func adjustStartTime(for segment: Segment, by step: Double) {
        let newStart = max(0, segment.startTime + step)
        guard newStart < segment.endTime - 0.2 else { return }
        segment.startTime = newStart
        reExtractText(for: segment)
        modelContext?.safeSave()

        // 直接从新开始时间播放 2 秒
        requestPlay(segment: segment, from: newStart, to: min(newStart + 2, segment.endTime))
    }

    /// 调整结束时间（+/- step），调整后直接播放到对应时间
    func adjustEndTime(for segment: Segment, by step: Double) {
        let videoDuration = segment.video?.duration ?? Double.greatestFiniteMagnitude
        let newEnd = min(videoDuration, segment.endTime + step)
        guard newEnd > segment.startTime + 0.2 else { return }
        segment.endTime = newEnd
        reExtractText(for: segment)
        modelContext?.safeSave()

        // 从结束时间前 1 秒播放到结束
        requestPlay(segment: segment, from: max(segment.startTime, newEnd - 1), to: newEnd)
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

    /// 直接设置开始时间
    func setStartTime(for segment: Segment, to newStart: Double) {
        let clamped = max(0, newStart)
        guard clamped < segment.endTime - 0.2 else { return }
        segment.startTime = clamped
        reExtractText(for: segment)
        modelContext?.safeSave()
        requestPlay(segment: segment, from: clamped, to: min(clamped + 2, segment.endTime))
    }

    /// 直接设置结束时间
    func setEndTime(for segment: Segment, to newEnd: Double) {
        let videoDuration = segment.video?.duration ?? Double.greatestFiniteMagnitude
        let clamped = min(videoDuration, newEnd)
        guard clamped > segment.startTime + 0.2 else { return }
        segment.endTime = clamped
        reExtractText(for: segment)
        modelContext?.safeSave()
        requestPlay(segment: segment, from: max(segment.startTime, clamped - 1), to: clamped)
    }

    /// 删除分镜
    func deleteSegment(_ segment: Segment) {
        guard let context = modelContext else { return }
        if selectedSegment?.id == segment.id {
            selectedSegment = nil
        }
        context.delete(segment)
        context.safeSave()
        segments.removeAll { $0.id == segment.id }
        selectedSegmentIDs.remove(segment.id)
        applyFilter()
    }

    /// 批量删除当前选中的分镜
    func deleteSelectedSegments() {
        guard let context = modelContext else { return }
        let idsToDelete = selectedSegmentIDs
        let segs = segments.filter { idsToDelete.contains($0.id) }
        for seg in segs {
            if selectedSegment?.id == seg.id {
                selectedSegment = nil
            }
            context.delete(seg)
        }
        context.safeSave()
        segments.removeAll { idsToDelete.contains($0.id) }
        selectedSegmentIDs.removeAll()
        applyFilter()
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
