import SwiftUI

/// 设计令牌：统一管理全局样式常量
enum DesignTokens {

    // MARK: - 圆角

    enum Corner {
        static let small: CGFloat = 4       // 缩略图、小图标
        static let medium: CGFloat = 8      // 卡片、输入框
        static let large: CGFloat = 12      // 面板、对话框
        static let extraLarge: CGFloat = 16 // 拖拽区域、大容器
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
        static let card: CGFloat = 10       // 卡片内部
        static let section: CGFloat = 20    // 内容区域
    }
}
