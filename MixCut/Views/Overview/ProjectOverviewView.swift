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

    var body: some View {
        if isLoading {
            SkeletonView(layout: .projectOverview)
                .task(id: project.id) {
                    let t0 = Date()
                    // 一次性读取所有 SwiftData 关系字段
                    let videos = project.videos
                    let segCount = videos.reduce(0) { $0 + $1.segments.count }
                    videosCached = videos
                    videoCount = videos.count
                    segmentCount = segCount
                    schemeCount = project.schemeCount

                    let thumbPaths = videos.compactMap(\.thumbnailPath)
                    ThumbnailCache.shared.prewarm(paths: thumbPaths)
                    MixLog.info("[Perf] ProjectOverview: \(Int(Date().timeIntervalSince(t0) * 1000))ms / videos=\(videoCount) segs=\(segmentCount)")
                    // 立即切换（无动画），让 SwiftUI 直接渲染 mainContent
                    isLoading = false
                }
        } else {
            mainContent
        }
    }

    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 项目标题
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.name)
                            .font(.system(size: 24, weight: .bold))
                        Text("创建于 \(project.createdAt.formatted())")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    StatusBadge(status: project.status)
                }

                // 统计卡片（用缓存的数值，避免每次重绘触发 SwiftData 关系遍历）
                HStack(spacing: 12) {
                    StatCard(title: "视频", value: "\(videoCount)", icon: "film", color: .blue) {
                        withAnimation(.easeOut(duration: 0.18)) { selectedNavItem = .importMedia }
                    }
                    StatCard(title: "分镜", value: "\(segmentCount)", icon: "film.stack", color: .green) {
                        if segmentCount > 0 {
                            withAnimation(.easeOut(duration: 0.18)) { selectedNavItem = .segmentLibrary }
                        }
                    }
                    StatCard(title: "方案", value: "\(schemeCount)", icon: "list.bullet.clipboard", color: .purple) {
                        if schemeCount > 0 {
                            withAnimation(.easeOut(duration: 0.18)) { selectedNavItem = .schemes }
                        }
                    }
                }

                // 快速操作
                VStack(alignment: .leading, spacing: 10) {
                    Text("快速操作")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        ActionButton(
                            title: "导入视频",
                            icon: "square.and.arrow.down",
                            color: .blue
                        ) {
                            selectedNavItem = .importMedia
                        }

                        ActionButton(
                            title: "生成方案",
                            icon: "wand.and.stars",
                            color: .purple,
                            disabled: segmentCount == 0
                        ) {
                            selectedNavItem = .schemes
                        }

                        ActionButton(
                            title: "导出视频",
                            icon: "square.and.arrow.up",
                            color: .green,
                            disabled: schemeCount == 0
                        ) {
                            selectedNavItem = .export
                        }
                    }
                }

                Divider()

                // 视频列表预览（用缓存数组，避免重绘时反复触发 SwiftData fetch）
                if videosCached.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)
                        Text("暂无视频素材")
                            .font(.system(size: 14, weight: .medium))
                        Text("点击下方按钮或拖拽视频文件到「素材导入」页面")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Button {
                            withAnimation(.easeOut(duration: 0.18)) {
                                selectedNavItem = .importMedia
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("立即导入视频")
                                    .font(.system(size: 12, weight: .semibold))
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
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 6) {
                            Text("已导入视频")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text("\(videoCount)")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.secondary.opacity(0.08))
                                .clipShape(Capsule())
                        }

                        LazyVGrid(columns: [
                            GridItem(.adaptive(minimum: 200, maximum: 250))
                        ], spacing: 12) {
                            ForEach(videosCached) { video in
                                VideoCard(video: video)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("项目概览")
    }   // end mainContent
}

// MARK: - 子组件

struct StatusBadge: View {
    let status: ProjectStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.system(size: 11, weight: .medium))
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
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(color)
                    .frame(width: 36, height: 36)
                    .background(color.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovering
                          ? Color(.controlBackgroundColor).opacity(0.95)
                          : Color(.controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isHovering ? color.opacity(0.4) : .white.opacity(0.04), lineWidth: 1)
            )
            .scaleEffect(isHovering ? 1.015 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    var disabled: Bool = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(disabled ? color.opacity(0.03) :
                          isHovering ? color.opacity(0.12) : color.opacity(0.07))
            )
            .foregroundStyle(disabled ? .secondary : color)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

struct VideoCard: View {
    let video: Video
    @State private var isHovering = false

    private var videoAspectRatio: CGFloat {
        guard video.width > 0, video.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(video.width) / CGFloat(video.height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 纯静态缩略图（不创建 InlineVideoPlayer），项目概览只是预览，
            // 想播放请去素材导入页。这极大减少 ProjectOverview 加载开销。
            staticThumbnail
                .aspectRatio(videoAspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(video.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(formatDuration(video.duration))
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(video.resolution)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(video.segments.count) 分镜")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovering
                      ? Color(.controlBackgroundColor).opacity(0.8)
                      : Color(.controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.white.opacity(0.04), lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
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
