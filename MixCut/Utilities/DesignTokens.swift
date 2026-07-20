import AppKit
import SwiftUI

/// 设计令牌：全局视觉规范的唯一真相来源。
///
/// 目标是对齐 Apple HIG —— 视图里**不应再出现魔法数字**（字号 / 圆角 / 间距 / 颜色 / 动效时长）。
/// 新增视图一律从这里取值；改全局风格只改这一个文件。
enum DesignTokens {

    // MARK: - 圆角

    /// 四档圆角。macOS 自 Big Sur 起统一使用**连续曲率**（`.continuous`），
    /// 与系统按钮 / 窗口 / Sheet 的曲率一致；请始终配合 `Corner.style` 使用。
    enum Corner {
        static let small: CGFloat = 6        // 缩略图、徽章、小图标
        static let medium: CGFloat = 10      // 卡片、输入框
        static let large: CGFloat = 14       // 面板、对话框
        static let extraLarge: CGFloat = 18  // 拖拽区域、大容器

        /// 统一的连续曲率。用法：`RoundedRectangle(cornerRadius: Corner.medium, style: Corner.style)`
        static let style: RoundedCornerStyle = .continuous
    }

    // MARK: - 间距

    enum Spacing {
        static let tight: CGFloat = 4
        static let compact: CGFloat = 8
        static let normal: CGFloat = 12
        static let comfortable: CGFloat = 16
        static let spacious: CGFloat = 20
        static let generous: CGFloat = 24
    }

    // MARK: - 内边距

    enum Padding {
        /// 页面级边距。**所有主视图都用它**，避免切换导航时正文横向跳动。
        static let page: CGFloat = 20
        static let card: CGFloat = 10       // 卡片内部
        static let section: CGFloat = 20    // 内容区域
        static let control: CGFloat = 8     // 控件内部
    }

    // MARK: - 字体

    /// 语义化字号阶梯（macOS 正文基准 13pt）。
    ///
    /// 规则：
    /// - **最小 10pt**（HIG 下限），严禁 6-9pt —— 在 Intel 非 Retina 屏上会糊成灰块。
    /// - `design: .rounded` **只用于数值型统计**（`metric`），不用于标题正文。
    /// - `design: .monospaced` **只用于时间码**（`timecode`）。
    /// - 字重收敛为 regular / medium / semibold / bold 四档，不用 `.light` / `.heavy`。
    enum Typography {
        static let pageTitle = Font.system(size: 20, weight: .semibold)     // 页面标题
        static let sectionTitle = Font.system(size: 15, weight: .semibold)  // 区块标题
        static let cardTitle = Font.system(size: 13, weight: .medium)       // 卡片主标题
        static let body = Font.system(size: 13)                             // 正文
        static let label = Font.system(size: 12)                            // 控件文字
        static let caption = Font.system(size: 11)                          // 次要信息
        static let micro = Font.system(size: 10, weight: .medium)           // 徽章 / 角标（下限）
        static let timecode = Font.system(size: 11, design: .monospaced)    // 时间码
        static let metric = Font.system(size: 22, weight: .bold, design: .rounded) // 统计数字

        // MARK: 强调变体
        // 同一字号的加重版本。命名规则 = 基础名 + Emphasis(semibold) / Strong(medium)，
        // 避免各处再写 `.system(size:weight:)` 造成字号字重两两组合式发散。
        static let microEmphasis = Font.system(size: 10, weight: .semibold)   // 角标强调
        static let captionStrong = Font.system(size: 11, weight: .medium)     // 次要信息加重
        static let captionEmphasis = Font.system(size: 11, weight: .semibold) // 小标题
        static let labelStrong = Font.system(size: 12, weight: .medium)       // 控件文字加重
        static let labelEmphasis = Font.system(size: 12, weight: .semibold)   // 区块小标题
        static let bodyEmphasis = Font.system(size: 13, weight: .semibold)    // 正文强调

        // MARK: 10pt 档（下限）的常用变体
        // 说明：全应用大量角标/辅助信息落在 10pt。这里把出现频次高的组合固化成令牌，
        // 避免继续在各处写 `.system(size:weight:design:)` 造成字号×字重×字族的组合式发散。
        static let microRegular = Font.system(size: 10)                        // 角标常规
        static let microBold = Font.system(size: 10, weight: .bold)            // 角标加粗
        static let microMono = Font.system(size: 10, design: .monospaced)      // 角标等宽（帧号/时间）
        static let microMonoStrong = Font.system(size: 10, weight: .medium, design: .monospaced)
        static let microRounded = Font.system(size: 10, design: .rounded)      // 角标圆体（计数）
        static let microMetric = Font.system(size: 10, weight: .bold, design: .rounded) // 小号统计数字

        // MARK: 其它常用档
        static let labelMono = Font.system(size: 12, design: .monospaced)      // 控件等宽文字
        static let bodyLarge = Font.system(size: 14)                           // 稍大正文
        static let bodyLargeEmphasis = Font.system(size: 14, weight: .semibold)
        static let title = Font.system(size: 16, weight: .semibold)            // 区块标题
        static let headline = Font.system(size: 18)                            // 大标题
    }

    // MARK: - 颜色

    /// 语义色。⚠️ 本应用**强制浅色外观**（见 `MixCutApp.init`），
    /// 因此严禁使用为暗色设计的 `.white.opacity(0.04~0.08)` 描边 —— 浅色底上完全不可见。
    enum Palette {
        static let cardFill = Color(nsColor: .controlBackgroundColor)
        static let border = Color(nsColor: .separatorColor).opacity(0.6)
        static let borderHover = Color(nsColor: .separatorColor)
        static let selectionFill = Color.accentColor.opacity(0.12)
        static let overlayScrim = Color.black.opacity(0.5)
        /// 9:16 letterbox 留边统一用纯黑，避免各处深浅不一。
        static let letterbox = Color.black

        enum Status {
            static let success = Color.green
            static let warning = Color.orange
            static let danger = Color.red
        }

        /// 分层透明度：收敛为 4 级，替代散落的 20+ 种 opacity。
        enum Alpha {
            static let subtle: Double = 0.06
            static let light: Double = 0.12
            static let medium: Double = 0.24
            static let strong: Double = 0.5
        }
    }

    // MARK: - 动效

    /// 三档动效。同类交互必须用同一档，避免同屏两种手感。
    /// 动效令牌。
    ///
    /// 全部尊重系统「辅助功能 → 显示 → 减弱动态效果」开关：打开后弹簧/位移动画会退化为
    /// 极短的淡入淡出。这是 Apple HIG 的硬性要求——前庭功能敏感的用户会被弹簧和位移动画诱发眩晕。
    ///
    /// ⚠️ 用 `NSWorkspace` 而不是 `@Environment(\.accessibilityReduceMotion)`：这些是 static 属性，
    /// 取不到 SwiftUI 环境；而且很多调用点在 `withAnimation {}` 里，本来就没有 View 上下文。
    enum Motion {
        /// 系统是否开启了「减弱动态效果」
        static var reduceMotion: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }

        /// 减弱动态效果时统一退化成的动画：保留极短淡入淡出，避免界面"瞬间跳变"同样难受
        private static let reduced = Animation.easeOut(duration: 0.1)

        /// hover / 悬停高亮
        static var hover: Animation {
            reduceMotion ? reduced : .easeOut(duration: 0.15)
        }
        /// 状态切换、展开收起
        static var transition: Animation {
            reduceMotion ? reduced : .easeOut(duration: 0.22)
        }
        /// 强调（出现、成功反馈）——弹簧是最容易诱发不适的一种，必须降级
        static var emphasis: Animation {
            reduceMotion ? reduced : .spring(response: 0.35, dampingFraction: 0.7)
        }
    }

    // MARK: - 尺寸

    /// ⚠️ 9:16 铁律的唯一真相来源。
    ///
    /// MixCut 所有素材都是投放手机端的信息流广告，**任何展示视频/缩略图的视图都必须 9:16 竖屏**。
    /// 新增视图请用 `Size.videoHeight(forWidth:)` 计算高度，不要手写数字。
    enum Size {
        static let videoAspect: CGFloat = 9.0 / 16.0

        /// 给定宽度求 9:16 对应高度。例：140 → 248.9
        static func videoHeight(forWidth width: CGFloat) -> CGFloat {
            width * 16.0 / 9.0
        }

        /// 给定高度求 9:16 对应宽度。例：36 → 20.25
        static func videoWidth(forHeight height: CGFloat) -> CGFloat {
            height * 9.0 / 16.0
        }

        /// HIG 最小点击目标，避免 16×16 这类过小的按钮。
        static let hitTargetMin: CGFloat = 20
        static let sidebarWidth: CGFloat = 220
        static let cardWidthCompact: CGFloat = 140
    }
}
