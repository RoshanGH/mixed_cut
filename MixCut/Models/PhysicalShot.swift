import Foundation
import SwiftData

/// 分镜头（物理镜头）：一条逻辑分镜内部、按画面变化度切出的连贯镜头。
/// 有序（orderIndex），记源视频绝对帧号区间。按需切分并持久化。
@Model
final class PhysicalShot {
    @Attribute(.unique) var id: UUID
    /// 所属逻辑分镜（cascade 规则声明在 Segment.physicalShots 上）
    var parentSegment: Segment?

    /// 位置序（1 起，占位式重组时顺序锁死）
    var orderIndex: Int = 1

    /// 源视频绝对帧号区间（与 Segment 同一 fps 基准，保证切片对齐）
    var startFrame: Int = 0
    var endFrame: Int = 0

    /// 该坑选定的版本；nil = 用原分镜头
    var selectedVariantID: UUID?

    /// 该分镜头首帧缩略图（原画面），进工作区时按需生成
    var thumbnailPath: String?

    /// 该分镜头的所有 AI 编辑变体
    @Relationship(deleteRule: .cascade, inverse: \ShotVariant.shot)
    var variants: [ShotVariant] = []

    init(id: UUID = UUID(), orderIndex: Int, startFrame: Int, endFrame: Int) {
        self.id = id
        self.orderIndex = orderIndex
        self.startFrame = startFrame
        self.endFrame = endFrame
    }

    /// 帧数（派生）
    var frameCount: Int { max(0, endFrame - startFrame) }
}
