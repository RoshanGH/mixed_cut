import SwiftUI

struct ProjectOverviewView: View {
    let project: Project
    @Bindable var projectVM: ProjectViewModel
    @Binding var selectedNavItem: NavigationItem?

    @State private var isLoading = true
    // 缓存计算结果，避免 mainContent 反复访问 project.videoCount / segmentCount（每次都触发 SwiftData fetch）
    @State private var videoCount = 0
    @State private var segmentCount = 0
    @State private var schemeCount = 0
    @State private var videosCached: [Video] = []

    /// 当前该做的下一步 —— 按流水线进度推断，用来在「快速操作」里实心高亮那一个，
    /// 让用户一眼知道接下来干什么（而不是三个同等权重的按钮里瞎猜）。
    private var nextStep: NavigationItem {
        if videoCount == 0 { return .importMedia }
        if schemeCount == 0 { return .schemes }
        return .export
    }

    var body: some View {
        // ⚠️ 切换项目联动规则（CLAUDE.md 铁律）：
        // .task(id: project.id) 必须放在 body 最外层（Group 上），不能放进 if/else 子分支
        // 否则切换项目时如果当前是 mainContent 分支，SkeletonView 不渲染 → task 消失 → 不联动
        Group {
            if isLoading {
                SkeletonView(layout: .projectOverview)
            } else {
                mainContent
            }
        }
        .task(id: project.id) {
            let t0 = Date()
            isLoading = true   // 每次切换都重置，确保 skeleton 显示 + 数据刷新
            // 一次性读取所有 SwiftData 关系字段
            let allVideos = project.videos
            let realVideos = allVideos.filter { !$0.isUserUploaded }   // 成片视频（自建分镜不算「视频」，只在分镜库出现）
            let segCount = allVideos.reduce(0) { $0 + $1.segments.count }   // 分镜计数含自建分镜
            videosCached = realVideos
            videoCount = realVideos.count
            segmentCount = segCount
            schemeCount = project.schemeCount

            let thumbPaths = realVideos.compactMap(\.thumbnailPath)
            ThumbnailCache.shared.prewarm(paths: thumbPaths)
            MixLog.info("[Perf] ProjectOverview: \(Int(Date().timeIntervalSince(t0) * 1000))ms / videos=\(videoCount) segs=\(segmentCount)")
            isLoading = false
        }
    }

    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.generous) {
                // 项目标题
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.tight) {
                        Text(project.name)
                            .font(.system(size: 24, weight: .bold))
                        Text("创建于 \(project.createdAt.formatted())")
                            .font(DesignTokens.Typography.label)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    StatusBadge(status: project.status)
                }

                // 统计卡片（用缓存的数值，避免每次重绘触发 SwiftData 关系遍历）
                HStack(spacing: DesignTokens.Spacing.normal) {
                    StatCard(title: "视频", value: "\(videoCount)", icon: "film", color: .blue) {
                        withAnimation(DesignTokens.Motion.transition) { selectedNavItem = .importMedia }
                    }
                    StatCard(title: "分镜", value: "\(segmentCount)", icon: "film.stack", color: .green,
                             onTap: segmentCount > 0
                             ? { withAnimation(DesignTokens.Motion.transition) { selectedNavItem = .segmentLibrary } }
                             : nil)
                    StatCard(title: "方案", value: "\(schemeCount)", icon: "list.bullet.clipboard", color: .purple,
                             onTap: schemeCount > 0
                             ? { withAnimation(DesignTokens.Motion.transition) { selectedNavItem = .schemes } }
                             : nil)
                }

                // 快速操作
                VStack(alignment: .leading, spacing: 10) {
                    Text("快速操作")
                        .font(DesignTokens.Typography.labelEmphasis)
                        .foregroundStyle(.secondary)

                    HStack(spacing: DesignTokens.Spacing.compact) {
                        ActionButton(
                            title: "导入视频",
                            icon: "square.and.arrow.down",
                            color: .accentColor,
                            isPrimary: nextStep == .importMedia
                        ) {
                            selectedNavItem = .importMedia
                        }

                        ActionButton(
                            title: "生成方案",
                            icon: "wand.and.stars",
                            color: .accentColor,
                            disabled: segmentCount == 0,
                            isPrimary: nextStep == .schemes
                        ) {
                            selectedNavItem = .schemes
                        }

                        ActionButton(
                            title: "导出视频",
                            icon: "square.and.arrow.up",
                            color: .accentColor,
                            disabled: schemeCount == 0,
                            isPrimary: nextStep == .export
                        ) {
                            selectedNavItem = .export
                        }
                    }
                }

                Divider()

                // 视频列表预览（用缓存数组，避免重绘时反复触发 SwiftData fetch）
                if videosCached.isEmpty {
                    VStack(spacing: DesignTokens.Spacing.normal) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)
                        Text("暂无视频素材")
                            .font(.system(size: 14, weight: .medium))
                        Text("点击下方按钮或拖拽视频文件到「素材导入」页面")
                            .font(DesignTokens.Typography.label)
                            .foregroundStyle(.secondary)
                        Button {
                            withAnimation(DesignTokens.Motion.transition) {
                                selectedNavItem = .importMedia
                            }
                        } label: {
                            HStack(spacing: DesignTokens.Spacing.tight) {
                                Image(systemName: "square.and.arrow.down")
                                    .font(DesignTokens.Typography.captionEmphasis)
                                Text("立即导入视频")
                                    .font(DesignTokens.Typography.labelEmphasis)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.normal) {
                        HStack(spacing: 6) {
                            Text("已导入视频")
                                .font(DesignTokens.Typography.labelEmphasis)
                                .foregroundStyle(.secondary)
                            Text("\(videoCount)")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.secondary.opacity(DesignTokens.Palette.Alpha.subtle))
                                .clipShape(Capsule())
                        }

                        // ⚠️ 1920 宽窗口下内容区约 1700pt，不限制的话一行能排 7 张等权重卡片，
                        // 视觉上会完全压过上方的「项目状态 + 关键指标」，主次颠倒。
                        // 限制最大宽度 → 一行最多 4 张，靠尺寸差建立层级。
                        LazyVGrid(columns: [
                            GridItem(.adaptive(minimum: 200, maximum: 250))
                        ], spacing: DesignTokens.Spacing.normal) {
                            ForEach(videosCached) { video in
                                VideoCard(video: video)
                            }
                        }
                        .frame(maxWidth: 1060, alignment: .leading)
                    }
                }
            }
            .padding(DesignTokens.Padding.page)
        }
        .navigationTitle("项目概览")
    }   // end mainContent
}

// MARK: - 子组件

struct StatusBadge: View {
    let status: ProjectStatus

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.tight) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(DesignTokens.Typography.captionStrong)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(statusColor.opacity(0.1))
        .foregroundStyle(statusColor)
        .clipShape(Capsule())
    }

    private var statusText: String {
        switch status {
        case .created: return "新建"
        case .importing: return "导入中"
        case .analyzing: return "分析中"
        case .ready: return "就绪"
        case .generating: return "生成中"
        case .completed: return "已完成"
        case .archived: return "已归档"
        }
    }

    private var statusColor: Color {
        switch status {
        case .created: return .gray
        case .importing, .analyzing, .generating: return .orange
        case .ready: return .blue
        case .completed: return .green
        case .archived: return .secondary
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    var onTap: (() -> Void)? = nil
    @State private var isHovering = false

    var body: some View {
        Button {
            onTap?()
        } label: {
            // 左对齐的信息密度布局：数值是主角，图标与标题退居一行。
            // 之前是居中三段式，卡片被拉满整行时中间大片留白，像网页仪表盘而非 macOS 应用。
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.compact) {
                HStack(spacing: DesignTokens.Spacing.tight + 2) {
                    Image(systemName: icon)
                        .font(DesignTokens.Typography.labelStrong)
                        .foregroundStyle(color)
                    Text(title)
                        .font(DesignTokens.Typography.label)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if onTap != nil {
                        // 可进入的卡片才给指示符，避免"假装可点"
                        Image(systemName: "chevron.right")
                            .font(DesignTokens.Typography.microEmphasis)
                            .foregroundStyle(.tertiary)
                            .opacity(isHovering ? 1 : 0)
                    }
                }
                Text(value)
                    .font(DesignTokens.Typography.metric)
                    .foregroundStyle(onTap == nil ? .secondary : .primary)
                    .contentTransition(.numericText())   // 数值变化时平滑滚动，而非硬切
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignTokens.Spacing.comfortable)
            .padding(.vertical, DesignTokens.Spacing.normal)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Corner.medium, style: DesignTokens.Corner.style)
                    .fill(DesignTokens.Palette.cardFill.opacity(isHovering ? 1.0 : 0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Corner.medium, style: DesignTokens.Corner.style)
                    .stroke(isHovering ? color.opacity(DesignTokens.Palette.Alpha.medium) : DesignTokens.Palette.border,
                            lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
        .onHover { hovering in
            // 计数为 0（onTap == nil，禁用态）不做 hover 高亮，避免"假装可点"
            guard onTap != nil else { return }
            withAnimation(DesignTokens.Motion.hover) { isHovering = hovering }
        }
    }
}

struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    var disabled: Bool = false
    /// 是否是「当前该做的下一步」。同一时刻只应有一个为 true，用实心强调引导用户。
    var isPrimary: Bool = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            // 横向图标 + 文字：之前是竖排图标压文字塞在很宽很矮的块里，比例别扭；
            // 且三个按钮各用一种饱和粉彩底色，像网页仪表盘。现在统一中性表面，只有"下一步"用强调色。
            HStack(spacing: DesignTokens.Spacing.compact) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                Text(title)
                    .font(DesignTokens.Typography.cardTitle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignTokens.Spacing.normal)
            .foregroundStyle(foreground)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Corner.medium, style: DesignTokens.Corner.style)
                    .stroke(isPrimary ? .clear : DesignTokens.Palette.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering in
            guard !disabled else { return }
            withAnimation(DesignTokens.Motion.hover) { isHovering = hovering }
        }
    }

    private var foreground: some ShapeStyle {
        if disabled { return AnyShapeStyle(.tertiary) }
        return isPrimary ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary)
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Corner.medium, style: DesignTokens.Corner.style)
        if isPrimary && !disabled {
            shape.fill(color.opacity(isHovering ? 0.88 : 1.0))
        } else {
            shape.fill(DesignTokens.Palette.cardFill.opacity(disabled ? 0.3 : (isHovering ? 1.0 : 0.55)))
        }
    }
}

struct VideoCard: View {
    let video: Video
    @State private var isHovering = false

    private var videoAspectRatio: CGFloat {
        // 元数据缺失时兜底 9:16 竖屏（信息流广告铁律，见 CLAUDE.md），与导入页 ImportedVideoCard 一致
        guard video.width > 0, video.height > 0 else { return 9.0 / 16.0 }
        return CGFloat(video.width) / CGFloat(video.height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.compact) {
            // 纯静态缩略图（不创建 InlineVideoPlayer），项目概览只是预览，
            // 想播放请去素材导入页。这极大减少 ProjectOverview 加载开销。
            staticThumbnail
                .aspectRatio(videoAspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(video.name)
                    .font(DesignTokens.Typography.captionStrong)
                    .lineLimit(1)

                HStack(spacing: DesignTokens.Spacing.tight) {
                    Text(formatDuration(video.duration))
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(video.resolution)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(video.segments.count) 分镜")
                }
                .font(DesignTokens.Typography.microRegular)
                .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovering
                      ? Color(.controlBackgroundColor).opacity(0.8)
                      : Color(.controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DesignTokens.Palette.border, lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(DesignTokens.Motion.hover) {
                isHovering = hovering
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    @ViewBuilder
    private var staticThumbnail: some View {
        if let thumbPath = video.thumbnailPath,
           let image = ThumbnailCache.shared.image(for: thumbPath) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle()
                .fill(.quaternary.opacity(0.5))
                .overlay {
                    Image(systemName: "film")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                }
        }
    }
}
