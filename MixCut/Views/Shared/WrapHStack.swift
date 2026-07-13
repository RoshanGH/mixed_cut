import SwiftUI

/// 自动换行的横向排布（左对齐）。逐字字块等"排满一行折到下一行"的场景。
/// 复用项目已有的 `FlowLayout`（见 Views/Components/FlowLayout.swift）。
struct WrapHStack<Content: View>: View {
    var spacing: CGFloat = 4
    @ViewBuilder var content: () -> Content

    var body: some View {
        FlowLayout(spacing: spacing) { content() }
    }
}
