import Foundation

/// 叙事结构中的一段：顺序 + 一组标签（SemanticType 的 rawValue 字符串）
public struct NarrativeSlot: Codable, Equatable, Sendable {
    public var order: Int
    public var tags: [String]
    public init(order: Int, tags: [String]) {
        self.order = order
        self.tags = tags
    }
}

/// 分镜的轻量描述（供匹配/校验，不依赖 SwiftData）
public struct SegmentDescriptor: Equatable, Sendable {
    public let id: UUID
    public let tags: [String]
    public let text: String
    public let duration: Double
    public let quality: Double
    public init(id: UUID, tags: [String], text: String, duration: Double, quality: Double) {
        self.id = id
        self.tags = tags
        self.text = text
        self.duration = duration
        self.quality = quality
    }
}
