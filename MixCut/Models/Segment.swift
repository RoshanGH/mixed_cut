import Foundation
import SwiftData

/// 语义类型（来自 segment_types_definition.md）
enum SemanticType: String, Codable, CaseIterable, Identifiable {
    case hook = "噱头引入"
    case painPoint = "痛点"
    case solution = "产品方案"
    case results = "效果展示"
    case socialProof = "信任背书"
    case priceAnchor = "价格对比"
    case promotion = "活动福利"
    case callToAction = "行动号召"
    case productPositioning = "产品定位"
    case usageEducation = "产品使用教育"
    case transition = "过渡"

    var id: String { rawValue }

    /// 显示颜色标签（SwiftUI Color name）
    var colorName: String {
        switch self {
        case .hook: return "red"
        case .painPoint: return "orange"
        case .solution: return "blue"
        case .results: return "green"
        case .socialProof: return "purple"
        case .priceAnchor: return "yellow"
        case .promotion: return "pink"
        case .callToAction: return "mint"
        case .productPositioning: return "teal"
        case .usageEducation: return "indigo"
        case .transition: return "gray"
        }
    }
}

/// 位置类型
enum PositionType: String, Codable, CaseIterable, Identifiable {
    case opening = "开头"
    case middle = "中间"
    case ending = "结尾"

    var id: String { rawValue }
}

@Model
final class Segment: Identifiable {
    @Attribute(.unique) var id: UUID
    var segmentIndex: String   // seg_001 格式
    // 边界「真相」：以帧号存储（永不差帧）。startTime/endTime 是 = 帧号/fps 的精确派生缓存，
    // 仅供显示和未改造的读取点用，编辑一律走 setFrameRange / adjust*Frame。
    var startFrame: Int = 0
    var endFrame: Int = 0
    var startTime: Double      // 派生缓存：FrameTime.seconds(frame: startFrame, fps: video.fps)
    var endTime: Double        // 派生缓存：FrameTime.seconds(frame: endFrame, fps: video.fps)
    var text: String
    var semanticTypesData: Data?  // [SemanticType] 编码存储（可多个）
    var positionType: PositionType
    var confidence: Double
    var qualityScore: Double
    var visualDescription: String?
    var thumbnailPath: String?

    /// 关键词
    var keywordsData: Data?  // [String] 编码存储

    /// 数据质量详情
    var qualityReasoning: String?

    var video: Video?

    @Relationship(deleteRule: .cascade, inverse: \SchemeSegment.segment)
    var schemeSegments: [SchemeSegment] = []

    var createdAt: Date

    /// 语义类型（支持多个）
    var semanticTypes: [SemanticType] {
        get {
            guard let data = semanticTypesData else { return [] }
            return (try? JSONDecoder().decode([SemanticType].self, from: data)) ?? []
        }
        set {
            semanticTypesData = try? JSONEncoder().encode(newValue)
        }
    }

    /// 主语义类型（第一个，兼容旧代码）
    /// ⚠️ Deprecated：旧版单字段，set 时会悄悄丢弃其他类型（多类型已迁移到 `semanticTypes`）
    /// 新代码请用 `segment.semanticTypes` 读写完整多类型；只读首项请用 `semanticTypes.first ?? .transition`
    @available(*, deprecated, message: "use semanticTypes (set 会丢失非首项)")
    var semanticType: SemanticType {
        get { semanticTypes.first ?? .transition }
        set {
            if semanticTypes.isEmpty {
                semanticTypes = [newValue]
            } else {
                var types = semanticTypes
                types[0] = newValue
                semanticTypes = types
            }
        }
    }

    init(
        segmentIndex: String,
        startTime: Double,
        endTime: Double,
        text: String,
        semanticTypes: [SemanticType],
        positionType: PositionType,
        qualityScore: Double = 8.0
    ) {
        self.id = UUID()
        self.segmentIndex = segmentIndex
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.positionType = positionType
        self.confidence = 0.8
        self.qualityScore = qualityScore
        self.createdAt = Date()
        self.semanticTypes = semanticTypes
    }

    /// 时长（保证非负）
    var duration: Double {
        max(0, endTime - startTime)
    }

    /// 分镜帧数
    var frameCount: Int { max(0, endFrame - startFrame) }

    /// 以帧号为准设置边界，并同步秒缓存（fps 来自所属视频）。所有边界编辑都应走这里。
    func setFrameRange(startFrame: Int, endFrame: Int, fps: Double) {
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.startTime = FrameTime.seconds(frame: startFrame, fps: fps)
        self.endTime = FrameTime.seconds(frame: endFrame, fps: fps)
    }

    /// 用所属视频的 fps，把当前秒边界 round 成帧号回填（迁移/兜底用）
    func backfillFramesFromSeconds() {
        let fps = video?.fps ?? 0
        guard fps > 0 else { return }
        startFrame = FrameTime.frame(seconds: startTime, fps: fps)
        endFrame = FrameTime.frame(seconds: endTime, fps: fps)
        // 同步秒缓存到精确帧栅格点
        startTime = FrameTime.seconds(frame: startFrame, fps: fps)
        endTime = FrameTime.seconds(frame: endFrame, fps: fps)
    }

    /// 关键词
    var keywords: [String] {
        get {
            guard let data = keywordsData else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        set {
            keywordsData = try? JSONEncoder().encode(newValue)
        }
    }
}
