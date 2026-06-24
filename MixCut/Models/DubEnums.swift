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
