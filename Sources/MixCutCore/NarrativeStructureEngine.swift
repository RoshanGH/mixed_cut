import Foundation

public enum NarrativeStructureEngine {
    /// 二级目录名：各段按 order 排序，段内多标签用 "/"，段间用 " · "
    public static func structureName(for slots: [NarrativeSlot]) -> String {
        slots.sorted { $0.order < $1.order }
            .map { $0.tags.joined(separator: "/") }
            .joined(separator: " · ")
    }

    /// 候选池：分镜标签与该段标签有交集（并集匹配）即入选
    public static func candidatePool(for slot: NarrativeSlot, in segments: [SegmentDescriptor]) -> [SegmentDescriptor] {
        let slotTags = Set(slot.tags)
        return segments.filter { !slotTags.isDisjoint(with: Set($0.tags)) }
    }

    /// 喂 prompt 前每段取 Top-N：质量降序，质量相同按时长降序，再按 id 稳定排序
    public static func topCandidates(_ pool: [SegmentDescriptor], limit: Int) -> [SegmentDescriptor] {
        let sorted = pool.sorted {
            if $0.quality != $1.quality { return $0.quality > $1.quality }
            if $0.duration != $1.duration { return $0.duration > $1.duration }
            return $0.id.uuidString < $1.id.uuidString
        }
        return Array(sorted.prefix(max(0, limit)))
    }
}
