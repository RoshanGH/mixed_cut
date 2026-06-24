import Foundation

/// 字幕遮挡渲染模式（纯 Core 表示，与 App 的 MaskStyle/hasHardSubtitle 解耦）。
public enum SubtitleMaskMode: String, Equatable, Sendable, CaseIterable {
    case none    // 原片无硬字幕：不遮挡，仅叠新字幕
    case blur    // 模糊遮挡旧字幕
    case solid   // 纯色字幕条遮挡旧字幕
    case dim     // 半透明压暗（遮挡力度弱，一般不用）

    /// 从 App 层「是否有硬字幕 + maskStyle 原始值」映射到渲染模式。
    /// hasHardSubtitle == false → .none（无视 style）；否则按 style 取，未知退回 .blur。
    public static func from(hasHardSubtitle: Bool, maskStyleRaw: String) -> SubtitleMaskMode {
        guard hasHardSubtitle else { return .none }
        switch maskStyleRaw {
        case "blur":  return .blur
        case "solid": return .solid
        case "dim":   return .dim
        default:      return .blur
        }
    }
}
