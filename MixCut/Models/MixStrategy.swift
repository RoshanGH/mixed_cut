import Foundation
import SwiftData

/// 混剪策略（一个策略下包含多个排列组合变体）
@Model
final class MixStrategy: Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    var style: String
    var strategyDescription: String
    var targetAudience: String
    var narrativeStructure: String
    var targetDuration: Double
    var strategyReasoning: String?
    var differentiation: String?

    var project: Project?

    @Relationship(deleteRule: .cascade, inverse: \MixScheme.strategy)
    var schemes: [MixScheme] = []

    var createdAt: Date

    init(
        name: String,
        style: String,
        description: String,
        targetAudience: String = "",
        narrativeStructure: String = "",
        targetDuration: Double = 60
    ) {
        self.id = UUID()
        self.name = name
        self.style = style
        self.strategyDescription = description
        self.targetAudience = targetAudience
        self.narrativeStructure = narrativeStructure
        self.targetDuration = targetDuration
        self.createdAt = Date()
    }

    /// 变体数量
    var schemeCount: Int { schemes.count }

    /// 按创建时间排序的变体
    var orderedSchemes: [MixScheme] {
        schemes.sorted { $0.variationIndex < $1.variationIndex }
    }
}
