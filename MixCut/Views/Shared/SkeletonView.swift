import SwiftUI

/// 通用 Loading 骨架屏（带 shimmer 微动画）
struct SkeletonView: View {
    enum Layout {
        case projectOverview   // 项目概览：统计 + 视频卡片
        case importMedia       // 素材导入：拖拽区 + 视频卡片列表
        case segmentLibrary    // 分镜库：网格
    }

    let layout: Layout
    @State private var shimmer: CGFloat = -1

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.spacious) {
            switch layout {
            case .projectOverview:
                projectOverviewSkeleton
            case .importMedia:
                importMediaSkeleton
            case .segmentLibrary:
                segmentLibrarySkeleton
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                shimmer = 1
            }
        }
    }

    @ViewBuilder
    private var projectOverviewSkeleton: some View {
        // 标题
        bar(width: 220, height: 24)
        bar(width: 140, height: 12)
            .padding(.bottom, 8)

        // 统计卡片
        HStack(spacing: DesignTokens.Spacing.normal) {
            ForEach(0..<3, id: \.self) { _ in
                // 与重设计后的 StatCard 实际高度对齐，避免加载完成时整页跳动
                shimmerBlock(height: 76)
            }
        }

        bar(width: 60, height: 11)
            .padding(.top, 8)

        // 视频卡片
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 250))], spacing: DesignTokens.Spacing.normal) {
            ForEach(0..<3, id: \.self) { _ in
                // 真实卡片 = 9:16 缩略图 + 文件名 + 元信息；骨架必须同高，否则加载完成时布局大幅位移
                shimmerBlock(height: DesignTokens.Size.videoHeight(forWidth: 225) + 44)
            }
        }
    }

    @ViewBuilder
    private var importMediaSkeleton: some View {
        // 拖拽区
        shimmerBlock(height: 180)
        bar(width: 100, height: 12)
            .padding(.top, 8)
        // 视频卡片
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 380, maximum: 440))], spacing: DesignTokens.Spacing.comfortable) {
            ForEach(0..<2, id: \.self) { _ in
                shimmerBlock(height: 220)
            }
        }
    }

    @ViewBuilder
    private var segmentLibrarySkeleton: some View {
        // 工具栏
        HStack(spacing: DesignTokens.Spacing.normal) {
            shimmerBlock(height: 32).frame(width: 220)
            shimmerBlock(height: 32).frame(width: 80)
            shimmerBlock(height: 32).frame(width: 80)
            Spacer()
        }
        // 类型芯片
        HStack(spacing: 6) {
            ForEach(0..<8, id: \.self) { _ in
                Capsule()
                    .fill(.quaternary.opacity(0.4))
                    .frame(width: 70, height: 24)
                    .overlay(shimmerOverlay)
            }
        }
        // 网格
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 360, maximum: 460))], spacing: DesignTokens.Spacing.normal) {
            ForEach(0..<4, id: \.self) { _ in
                // 分镜卡实测约 410 高（9:16 播放器 + 标签行 + 字幕控件），原来的 160 会造成明显跳动
                shimmerBlock(height: 410)
            }
        }
    }

    // MARK: - 通用占位元素

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(.quaternary.opacity(0.5))
            .frame(width: width, height: height)
            .overlay(shimmerOverlay.mask(RoundedRectangle(cornerRadius: 4, style: .continuous)))
    }

    private func shimmerBlock(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.quaternary.opacity(0.4))
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay(shimmerOverlay.mask(RoundedRectangle(cornerRadius: 10, style: .continuous)))
    }

    private var shimmerOverlay: some View {
        GeometryReader { geo in
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.25), location: 0.5),
                    .init(color: .clear, location: 1),
                ]),
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: geo.size.width * 0.5)
            .offset(x: geo.size.width * shimmer)
        }
    }
}
