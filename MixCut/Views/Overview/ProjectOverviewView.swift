import SwiftUI

struct ProjectOverviewView: View {
    let project: Project
    @Bindable var projectVM: ProjectViewModel
    @Binding var selectedNavItem: NavigationItem?

    var body: some View {
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

                // 统计卡片
                HStack(spacing: 12) {
                    StatCard(title: "视频", value: "\(project.videoCount)", icon: "film", color: .blue)
                    StatCard(title: "分镜", value: "\(project.segmentCount)", icon: "film.stack", color: .green)
                    StatCard(title: "方案", value: "\(project.schemeCount)", icon: "list.bullet.clipboard", color: .purple)
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
                            disabled: project.segmentCount == 0
                        ) {
                            selectedNavItem = .schemes
                        }

                        ActionButton(
                            title: "导出视频",
                            icon: "square.and.arrow.up",
                            color: .green,
                            disabled: project.schemeCount == 0
                        ) {
                            selectedNavItem = .export
                        }
                    }
                }

                Divider()

                // 视频列表预览
                if project.videos.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)
                        Text("暂无视频素材")
                            .font(.system(size: 14, weight: .medium))
                        Text("请前往「素材导入」页面导入视频")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 6) {
                            Text("已导入视频")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text("\(project.videos.count)")
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
                            ForEach(project.videos) { video in
                                VideoCard(video: video)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("项目概览")
    }
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
    @State private var isHovering = false

    var body: some View {
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
            InlineVideoPlayer(
                videoPath: video.localPath,
                thumbnailPath: video.thumbnailPath,
                aspectRatio: videoAspectRatio
            )

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
}
