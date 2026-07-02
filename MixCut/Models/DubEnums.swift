import Foundation

/// 方案的音色一致性模式
enum VoiceMode: String, Codable, CaseIterable {
    case unified   // 整片统一音色（从选定音色里指定一个）
    case mixed     // 片内混用（各槽位可不同音色）
}

/// 单分镜配音（SegmentDub）的状态
enum SegmentDubStatus: String, Codable, CaseIterable {
    case pending      // 待生成
    case generated    // 已生成音频
    case failed       // 生成失败（可单独重生成）
}

/// 硬字幕遮挡样式
enum MaskStyle: String, Codable, CaseIterable, Identifiable {
    case blur         // 高斯模糊
    case solid        // 纯色
    case dim          // 半透明

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blur: return "模糊"
        case .solid: return "纯色"
        case .dim: return "半透明"
        }
    }
}

/// 烧录字幕字号（全局统一）。以「相对成片宽度的连续比例」存储，导出时按分辨率换算像素，
/// 任意分辨率下观感一致（根治小分辨率素材上字幕巨大的问题）。
/// 参考实拍原字幕≈画面宽 7%，故范围取 3%~8.5%（可小可匹配大号原字幕），默认 5.5%。
/// 全局存 UserDefaults（避免 SwiftData 迁移；导出路径与 UI 预览共用同一键）。
enum SubtitleFontSize {
    /// UserDefaults 键（与 UI 的 @AppStorage 共用同一键，值为 Double 比例）。
    static let userDefaultsKey = "subtitleFontRatio"

    static let minRatio: Double = 0.030      // 最小（很小）
    static let maxRatio: Double = 0.085      // 最大（匹配/略超大号原字幕）
    static let defaultRatio: Double = 0.055  // 默认

    /// 夹取到合法区间。
    static func clamp(_ ratio: Double) -> Double { min(maxRatio, max(minRatio, ratio)) }

    /// 当前全局比例；无值/越界回退默认并夹取。
    static var currentRatio: Double {
        let stored = UserDefaults.standard.object(forKey: userDefaultsKey) as? Double
        return clamp(stored ?? defaultRatio)
    }

    /// 按成片宽度换算字号像素（下限 12px 兜底极小分辨率）。
    static func fontSize(forOutputWidth outputWidth: Int) -> Double {
        max(12, Double(outputWidth) * currentRatio)
    }
}

/// 分镜「字幕处理」方式（导出时对字幕区域背景的处理）。
/// 为避免数据库迁移，映射到底层 (hasHardSubtitle, maskStyle) 两字段。
enum SubtitleTreatment: String, CaseIterable, Identifiable {
    case direct   // 直接烧录：不处理背景，直接把新字幕烧上去
    case blur     // 模糊虚化：把字幕区域糊掉再烧（不管原片有没有旧字幕都可用）
    case solid    // 纯色遮挡：深色条盖住该区域再烧

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .direct: return "直接烧录"
        case .blur:   return "模糊虚化"
        case .solid:  return "纯色遮挡"
        }
    }

    /// 是否需要遮挡框（blur/solid 需要定位区域；direct 不需要）
    var needsMask: Bool { self != .direct }

    /// 对应底层 maskStyle（direct 无需遮挡样式）
    var maskStyle: MaskStyle? {
        switch self {
        case .direct: return nil
        case .blur:   return .blur
        case .solid:  return .solid
        }
    }

    /// 从底层字段还原。旧的「半透明 dim」统一归入「模糊虚化」。
    static func from(hasHardSubtitle: Bool, maskStyle: MaskStyle) -> SubtitleTreatment {
        guard hasHardSubtitle else { return .direct }
        return maskStyle == .solid ? .solid : .blur
    }
}
