import Foundation
import SwiftData

/// 分镜"当前生效画面"来源（就地替换的单一真源）。播放/缩略图/导出统一读它。
struct EffectivePicture: Sendable {
    let videoPath: String
    let startTime: Double
    let endTime: Double
    let startFrame: Int
    let endFrame: Int
    let fps: Double
    let thumbnailPath: String?
    let isReplaced: Bool
}

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

    /// 配音变体池（每个 = 该分镜的一个 改写版×音色 变体）
    @Relationship(deleteRule: .cascade, inverse: \SegmentDub.segment)
    var segmentDubs: [SegmentDub] = []

    /// 分镜头（物理镜头）列表：进入"分镜头替换"工作区时按需切分并持久化
    @Relationship(deleteRule: .cascade, inverse: \PhysicalShot.parentSegment)
    var physicalShots: [PhysicalShot] = []

    // MARK: - 就地画面替换（分镜头 AI 替换产物）

    /// 替换画面合成 mp4 路径；nil = 尚无替换画面
    var replacedPictureVideoPath: String?
    /// 替换画面缩略图路径
    var replacedPictureThumbnailPath: String?
    /// 替换画面实际帧数（合成时探测存下，供帧区间消费点用）
    var replacedPictureFrameCount: Int = 0
    /// 当前生效哪版画面（仅当存在替换画面时有意义）
    var pictureShowsReplaced: Bool = false

    var createdAt: Date

    // MARK: - 配音改写相关（P1）

    /// 是否"保留原声"（明星出镜镜头 = true，不可重配）
    var isVoiceLocked: Bool = false

    /// 原版是否参与导出组合（默认参与）；配合 SegmentDub.participatesInCombination 收敛组合数
    var originalParticipatesInCombination: Bool = true

    /// 原片该分镜是否有硬字幕，需要遮挡
    var hasHardSubtitle: Bool = false

    /// 遮挡矩形（归一化 0~1，原点左上），默认底部带状区
    var maskX: Double = 0.0
    var maskY: Double = 0.80
    var maskWidth: Double = 1.0
    var maskHeight: Double = 0.12

    /// 遮挡样式（MaskStyle.rawValue：blur/solid/dim）
    var maskStyleRaw: String = "blur"

    /// 遮挡矩形（桥接四个归一化 Double）
    var maskRect: SubtitleMaskRect {
        get { SubtitleMaskRect(x: maskX, y: maskY, width: maskWidth, height: maskHeight) }
        set {
            let c = newValue.clamped()
            maskX = c.x; maskY = c.y; maskWidth = c.width; maskHeight = c.height
        }
    }

    /// 遮挡样式
    var maskStyle: MaskStyle {
        get { MaskStyle(rawValue: maskStyleRaw) ?? .blur }
        set { maskStyleRaw = newValue.rawValue }
    }

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
        let changed = (startFrame != self.startFrame || endFrame != self.endFrame)
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.startTime = FrameTime.seconds(frame: startFrame, fps: fps)
        self.endTime = FrameTime.seconds(frame: endFrame, fps: fps)
        // 边界变了 → 替换画面（内嵌原音频与长度）即失效，清除，避免导出错音画。
        if changed && replacedPictureVideoPath != nil {
            invalidateReplacedPicture()
        }
    }

    /// 作废就地替换画面（改边界 / 调整分镜头分区时调用）。旧文件留给孤儿 GC 回收。
    func invalidateReplacedPicture() {
        replacedPictureVideoPath = nil
        replacedPictureThumbnailPath = nil
        replacedPictureFrameCount = 0
        pictureShowsReplaced = false
    }

    // MARK: - 当前生效画面（就地替换的单一真源）

    /// 分镜当前应展示/导出的画面来源：有替换画面且生效时用替换片(整段)，否则用原源视频的帧区间。
    var effectivePicture: EffectivePicture {
        if pictureShowsReplaced,
           let p = replacedPictureVideoPath,
           FileManager.default.fileExists(atPath: p) {
            let d = duration
            let fc = max(1, replacedPictureFrameCount)
            return EffectivePicture(videoPath: p, startTime: 0, endTime: d,
                                    startFrame: 0, endFrame: fc,
                                    fps: d > 0 ? Double(fc) / d : (video?.fps ?? 30),
                                    thumbnailPath: replacedPictureThumbnailPath, isReplaced: true)
        }
        return EffectivePicture(videoPath: video?.localPath ?? "",
                                startTime: startTime, endTime: endTime,
                                startFrame: startFrame, endFrame: endFrame,
                                fps: video?.fps ?? 30,
                                thumbnailPath: thumbnailPath, isReplaced: false)
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
