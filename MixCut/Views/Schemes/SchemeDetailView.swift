import SwiftUI

struct SchemeDetailView: View {
    let scheme: MixScheme
    @Bindable var viewModel: SchemeViewModel
    @Bindable var segmentLibraryVM: SegmentLibraryViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                schemeHeader

                Divider()

                narrativeStructureBar

                Divider()

                storyboardView

                // 策略说明
                if let reasoning = scheme.strategyReasoning, !reasoning.isEmpty {
                    infoSection(title: "策略说明", icon: "lightbulb", text: reasoning)
                }

                // 差异化说明
                if let diff = scheme.differentiation, !diff.isEmpty {
                    infoSection(title: "差异化", icon: "arrow.triangle.branch", text: diff)
                }
            }
            .padding(24)
        }
    }

    // MARK: - 方案头部

    private var schemeHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(scheme.name)
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                Text(String(format: "%.1f", scheme.totalDuration))
                    .font(.system(size: 24, weight: .light, design: .rounded))
                    .foregroundStyle(.secondary)
                +
                Text("s")
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(.tertiary)
            }

            if !scheme.schemeDescription.isEmpty {
                Text(scheme.schemeDescription)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }

            HStack(spacing: 8) {
                InfoChip(icon: "paintpalette", text: scheme.style)
                InfoChip(icon: "person.2", text: scheme.targetAudience)
                InfoChip(icon: "film.stack", text: "\(scheme.segmentCount) 分镜")
            }

            if !scheme.narrativeStructure.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right.arrow.left")
                        .font(.system(size: 9))
                        .foregroundStyle(.blue)
                    Text(scheme.narrativeStructure)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.blue.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - 叙事结构条

    private var narrativeStructureBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("叙事结构")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(scheme.orderedSegments) { schemeSeg in
                        if let segment = schemeSeg.segment {
                            let width = max(
                                30,
                                geo.size.width * (segment.duration / max(scheme.totalDuration, 1))
                            )
                            RoundedRectangle(cornerRadius: 4)
                                .fill(SemanticTypeTag.color(for: segment.semanticType))
                                .frame(width: width)
                                .overlay {
                                    Text(segment.semanticTypes.map(\.rawValue).joined(separator: "/"))
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                        .padding(.horizontal, 2)
                                }
                                .help("\(segment.semanticTypes.map(\.rawValue).joined(separator: "/")) - \(String(format: "%.1fs", segment.duration))")
                        }
                    }
                }
            }
            .frame(height: 28)

            // 图例
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(usedTypes, id: \.self) { type in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(SemanticTypeTag.color(for: type))
                                .frame(width: 6, height: 6)
                            Text(type.rawValue)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Storyboard 视图

    private var storyboardView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("分镜序列")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(scheme.orderedSegments) { schemeSeg in
                        StoryboardCard(schemeSeg: schemeSeg, segmentLibraryVM: segmentLibraryVM)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    // MARK: - 辅助

    private func infoSection(title: String, icon: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var usedTypes: [SemanticType] {
        let types = scheme.orderedSegments.flatMap { $0.segment?.semanticTypes ?? [] }
        return Array(Set(types)).sorted { $0.rawValue < $1.rawValue }
    }
}

// MARK: - Storyboard 卡片

struct StoryboardCard: View {
    let schemeSeg: SchemeSegment
    @Bindable var segmentLibraryVM: SegmentLibraryViewModel
    @State private var isHovering = false

    private let cardWidth: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let segment = schemeSeg.segment {
                // 视频播放器 + 序号叠加
                ZStack(alignment: .topLeading) {
                    SegmentInlinePlayer(segment: segment, viewModel: segmentLibraryVM)
                        .frame(width: cardWidth)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    // 序号角标
                    Text("#\(schemeSeg.position)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                }

                VStack(alignment: .leading, spacing: 5) {
                    // 类型标签
                    HStack(spacing: 3) {
                        ForEach(segment.semanticTypes.prefix(2), id: \.self) { type in
                            SemanticTypeTag(type: type)
                        }
                        if segment.semanticTypes.count > 2 {
                            Text("+\(segment.semanticTypes.count - 2)")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // 台词（hover 显示完整）
                    Text(segment.text)
                        .font(.system(size: 10))
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineSpacing(2)
                        .help(segment.text)

                    // 紧凑时间调整
                    StoryboardTimeRow(segment: segment, viewModel: segmentLibraryVM)
                }
                .padding(.horizontal, 6)
                .padding(.top, 6)
                .padding(.bottom, 8)
            } else {
                VStack(spacing: 6) {
                    Text("#\(schemeSeg.position)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.tertiary)
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 14))
                        .foregroundStyle(.orange)
                    Text("分镜数据缺失")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(width: cardWidth, height: 80)
            }
        }
        .frame(width: cardWidth)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovering
                      ? Color(.controlBackgroundColor).opacity(0.9)
                      : Color(.controlBackgroundColor).opacity(0.5))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.secondary.opacity(isHovering ? 0.15 : 0.06), lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - 分镜序列专用时间调整行

struct StoryboardTimeRow: View {
    let segment: Segment
    @Bindable var viewModel: SegmentLibraryViewModel

    var body: some View {
        HStack(spacing: 0) {
            // IN 调整
            miniAdjustButton(icon: "minus") {
                viewModel.adjustStartTime(for: segment, by: -0.1)
            }
            Text(String(format: "%.1f", segment.startTime))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .center)
            miniAdjustButton(icon: "plus") {
                viewModel.adjustStartTime(for: segment, by: 0.1)
            }

            // 分隔
            Text("–")
                .font(.system(size: 8))
                .foregroundStyle(.quaternary)
                .padding(.horizontal, 2)

            // OUT 调整
            miniAdjustButton(icon: "minus") {
                viewModel.adjustEndTime(for: segment, by: -0.1)
            }
            Text(String(format: "%.1f", segment.endTime))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .center)
            miniAdjustButton(icon: "plus") {
                viewModel.adjustEndTime(for: segment, by: 0.1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func miniAdjustButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 6, weight: .heavy))
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 16)
                .background(.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 信息芯片

struct InfoChip: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.secondary.opacity(0.06))
        .clipShape(Capsule())
    }
}
