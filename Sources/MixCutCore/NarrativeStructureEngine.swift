import Foundation

public enum NarrativeStructureEngine {
    /// 二级目录名：各段按 order 排序，段内多标签用 "/"，段间用 " · "
    public static func structureName(for slots: [NarrativeSlot]) -> String {
        slots.sorted { $0.order < $1.order }
            .map { $0.tags.joined(separator: "/") }
            .joined(separator: " · ")
    }
}
