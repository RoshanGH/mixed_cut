import SwiftUI

/// 紧凑分镜卡片（用于抽屉/选择器场景）
/// 包含缩略图、语义类型标签、台词预览、时长
struct SegmentCardCompact: View {
    let segment: Segment
    let isDisabled: Bool          // true 时整卡片置灰禁用
    let disabledReason: String?   // 置灰原因 tooltip
    let onTap: () -> Void

    @State private var isHovering = false

    private let cardWidth: CGFloat = 140
    // 信息流广告 9:16 手机端比例（见 CLAUDE.md）
    private var imageHeight: CGFloat { cardWidth * 16.0 / 9.0 }

    var body: some View {
        Button(action: { if !isDisabled { onTap() } }) {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .topLeading) {
                    thumbnail
                    if isDisabled {
                        Image(systemName: "nosign")
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.black.opacity(0.45))
                            .clipShape(Circle())
                            .padding(4)
                    }
                }
                .frame(width: cardWidth, height: imageHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                semanticTags

                Text(segment.text.isEmpty ? "—" : segment.text)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(width: cardWidth, alignment: .leading)

                Text(String(format: "%.1fs", segment.duration))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: cardWidth)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovering && !isDisabled
                          ? Color(.controlBackgroundColor).opacity(0.95)
                          : Color(.controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.secondary.opacity(isHovering ? 0.18 : 0.06), lineWidth: 1)
            )
            .opacity(isDisabled ? 0.4 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering in
            if !isDisabled {
                isHovering = hovering
            }
        }
        .help(isDisabled ? (disabledReason ?? "已禁用") : segment.text)
    }

    /// 语义类型标签行（semanticTypes 只解码一次，避免同一卡片 body 内 3 次 JSON 解码）
    private var semanticTags: some View {
        let types = segment.semanticTypes
        return HStack(spacing: 3) {
            ForEach(Array(types.prefix(2)), id: \.self) { type in
                SemanticTypeTag(type: type)
            }
            if types.count > 2 {
                Text("+\(types.count - 2)")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let path = segment.effectivePicture.thumbnailPath,
           let image = ThumbnailCache.shared.image(for: path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Rectangle()
                .fill(.quaternary)
                .overlay(
                    Image(systemName: "film")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                )
        }
    }
}
