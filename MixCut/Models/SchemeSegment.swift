import Foundation
import SwiftData

/// 方案-分镜关联（有序）
@Model
final class SchemeSegment: Identifiable {
    @Attribute(.unique) var id: UUID
    var position: Int           // 在方案中的排列顺序（从 1 开始）
    var reasoning: String?      // AI 选择此分镜的理由
    var positionReasoning: String?  // 为什么放在这个位置

    var scheme: MixScheme?
    var segment: Segment?

    init(position: Int, reasoning: String? = nil, positionReasoning: String? = nil) {
        self.id = UUID()
        self.position = position
        self.reasoning = reasoning
        self.positionReasoning = positionReasoning
    }
}
