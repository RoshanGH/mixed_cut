import Foundation

/// 一版配音（DubVariant）的生成状态
enum DubVariantStatus: String, Codable, CaseIterable {
    case draft        // 台词待确认 / 未生成
    case generating   // 改写+配音进行中
    case ready        // 全部生成完成
    case failed       // 整版失败
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
