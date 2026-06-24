import Foundation
import SwiftData

/// 混剪方案（一个具体的分镜排列组合）
@Model
final class MixScheme: Identifiable {
    @Attribute(.unique) var id: UUID
    var variationIndex: Int         // 在策略内的序号（从 1 开始）
    var schemeIndex: String         // scheme_001 格式（全局）
    var name: String                // 简短变体名
    var style: String
    var schemeDescription: String
    var targetAudience: String
    var narrativeStructure: String
    var estimatedDuration: Double

    /// AI 生成的策略说明（保留兼容）
    var strategyReasoning: String?
    var differentiation: String?

    var strategy: MixStrategy?
    var project: Project?

    // MARK: - 三层结构（G3）：同一原分镜序列(模板)的多条变体视频共享 templateGroupId
    /// 模板组 ID：同一序列(模板)展开出的变体视频共享此 ID；nil = 旧数据/未分组（各自独立成组）
    var templateGroupId: UUID?
    /// 模板组内的变体视频序号（0-based）
    var templateVariantIndex: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \SchemeSegment.scheme)
    var schemeSegments: [SchemeSegment] = []

    var createdAt: Date

    /// true = AI 方案被用户手动改过分镜（添加/删除/替换/换序任一动作触发）
    var isManuallyEdited: Bool = false

    // MARK: - 配音（P5）
    var voiceModeRaw: String = "unified"   // VoiceMode.rawValue
    var unifiedVoiceId: String?            // 统一模式选的音色（混用时 nil）

    var voiceMode: VoiceMode {
        get { VoiceMode(rawValue: voiceModeRaw) ?? .unified }
        set { voiceModeRaw = newValue.rawValue }
    }

    init(
        variationIndex: Int = 1,
        schemeIndex: String = "",
        name: String = "",
        style: String = "",
        description: String = "",
        targetAudience: String = "",
        narrativeStructure: String = ""
    ) {
        self.id = UUID()
        self.variationIndex = variationIndex
        self.schemeIndex = schemeIndex
        self.name = name
        self.style = style
        self.schemeDescription = description
        self.targetAudience = targetAudience
        self.narrativeStructure = narrativeStructure
        self.estimatedDuration = 0
        self.createdAt = Date()
    }

    /// 按顺序排列的分镜
    var orderedSegments: [SchemeSegment] {
        schemeSegments.sorted {
            $0.position == $1.position
                ? $0.id.uuidString < $1.id.uuidString
                : $0.position < $1.position
        }
    }

    /// 实际总时长
    var totalDuration: Double {
        schemeSegments.reduce(0.0) { $0 + ($1.segment?.duration ?? 0) }
    }

    /// 分镜数量
    var segmentCount: Int {
        schemeSegments.count
    }
}
