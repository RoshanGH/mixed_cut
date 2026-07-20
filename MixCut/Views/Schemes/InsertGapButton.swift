import SwiftUI

/// Storyboard 行间「+」插入按钮：常驻一个小蓝「+」，可见可点；hover 仅轻微提亮，无背景
struct InsertGapButton: View {
    let onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor.opacity(isHovering ? 1.0 : 0.65))
                .frame(width: 22)            // 22pt 宽热区，易命中
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())   // 整列都可点
        }
        .buttonStyle(.plain)
        .animation(DesignTokens.Motion.hover, value: isHovering)
        .onHover { isHovering = $0 }
        .help("在此处插入分镜")
        .accessibilityLabel("在此插入分镜")
    }
}
