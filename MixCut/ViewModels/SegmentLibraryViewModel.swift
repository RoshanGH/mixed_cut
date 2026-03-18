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
        applyFilter()
    }

    /// 按视频分组的筛选结果
    var groupedSegments: [VideoSegmentGroup] {
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

        return videoOrder.compactMap { id in
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
