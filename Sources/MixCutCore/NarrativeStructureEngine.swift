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
}
