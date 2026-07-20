import SwiftUI

/// 流式布局：用于排不固定宽度的标签（语义类型、关键词等）
/// 当一行装不下时自动换行，行内元素左对齐
///
/// ⚠️ 性能：SwiftUI 一次布局会先调 `sizeThatFits` 再调 `placeSubviews`，且 `sizeThatFits`
/// 可能被调用多次。原实现两个方法各自完整跑一遍 `arrange`（内含对每个 subview 的
/// `sizeThatFits(.unspecified)` 测量），实际是 2–4 倍冗余测量。
/// 逐句字幕编辑器里一行台词会拆成**每字一个 Text + 一个 Button**，40 字 = 80 个 subview，
/// 冗余测量的代价非常明显。这里实现 `Layout.Cache`，同一宽度只算一次。
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    /// 布局缓存：记录上次计算所用的宽度与结果；宽度没变就直接复用。
    struct Cache {
        var proposedWidth: CGFloat?
        var positions: [CGPoint] = []
        var sizes: [CGSize] = []
        var totalSize: CGSize = .zero
        /// 上次布局所依据的**各子视图理想尺寸**指纹。
        /// ⚠️ 只比数量是不够的：标签数量不变、但某个标签文案变长/变短时（改语义类型、编辑关键词），
        /// 复用旧的 positions/sizes 会让新内容按旧宽度摆放，出现重叠或异常空白，
        /// 而且要等窗口 resize 或增删标签才会自愈。
        var contentFingerprint: [CGSize] = []
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        // 用「各子视图的理想尺寸」当指纹：数量变化和文案长度变化都能被它捕捉到。
        // 测量本身很便宜（只问 ideal size，不做排版），真正省下来的是整轮换行计算。
        let fingerprint = subviews.map { $0.sizeThatFits(.unspecified) }
        if cache.contentFingerprint != fingerprint {
            cache.proposedWidth = nil
            cache.contentFingerprint = fingerprint
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        ensureArranged(proposal: proposal, subviews: subviews, cache: &cache)
        return cache.totalSize
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        ensureArranged(proposal: proposal, subviews: subviews, cache: &cache)
        for (index, position) in cache.positions.enumerated() where index < subviews.count {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: ProposedViewSize(cache.sizes[index])
            )
        }
    }

    /// 只有「宽度变了」或「缓存为空」时才真正重排。
    private func ensureArranged(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let width = proposal.width
        if cache.proposedWidth == width, cache.sizes.count == subviews.count { return }

        let maxWidth = width ?? .infinity
        var positions: [CGPoint] = []
        var sizes: [CGSize] = []
        positions.reserveCapacity(subviews.count)
        sizes.reserveCapacity(subviews.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            sizes.append(size)
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        cache.proposedWidth = width
        cache.positions = positions
        cache.sizes = sizes
        cache.totalSize = CGSize(width: maxX, height: y + rowHeight)
    }
}
