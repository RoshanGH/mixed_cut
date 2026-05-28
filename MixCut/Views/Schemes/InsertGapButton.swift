import SwiftUI

/// Storyboard 行间「+」插入按钮：默认透明，hover 时显示
struct InsertGapButton: View {
    let onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Rectangle()
                    .fill(isHovering ? Color.accentColor.opacity(0.12) : Color.clear)
                    .frame(width: isHovering ? 28 : 12)
                    .frame(maxHeight: .infinity)

                if isHovering {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: isHovering ? 28 : 12)
        .frame(maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .help("在此处插入分镜")
    }
}
