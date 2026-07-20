import SwiftUI

/// 调整分镜顺序的模态 Sheet
/// 用户点击"组合为方案"后弹出，确认顺序并触发 AI 反推生成
struct ArrangeOrderSheet: View {
    let initialSegments: [Segment]
    let onCancel: () -> Void
    let onConfirm: (_ orderedSegments: [Segment]) async -> Void

    @State private var orderedSegments: [Segment] = []
    @State private var isGenerating = false

    private var totalDuration: Double {
        orderedSegments.reduce(0.0) { $0 + $1.duration }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 360)
        .onAppear { orderedSegments = initialSegments }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("调整顺序")
                    .font(DesignTokens.Typography.title)
                Text("\(orderedSegments.count) 个分镜 · 预计 \(String(format: "%.1fs", totalDuration))")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("用左右箭头调整顺序")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(DesignTokens.Spacing.comfortable)
    }

    private var list: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: DesignTokens.Spacing.normal) {
                ForEach(Array(orderedSegments.enumerated()), id: \.element.id) { idx, seg in
                    arrangeCard(segment: seg, index: idx)
                }
            }
            .padding(DesignTokens.Spacing.comfortable)
        }
    }

    private func arrangeCard(segment: Segment, index: Int) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text("#\(index + 1)")
                    .font(DesignTokens.Typography.microMetric)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { moveLeft(index) }) {
                    Image(systemName: "arrow.left.circle")
                        .font(DesignTokens.Typography.label)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("左移")
                .disabled(index == 0)

                Button(action: { moveRight(index) }) {
                    Image(systemName: "arrow.right.circle")
                        .font(DesignTokens.Typography.label)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("右移")
                .disabled(index == orderedSegments.count - 1)
            }
            .padding(.horizontal, 4)

            SegmentCardCompact(
                segment: segment,
                isDisabled: false,
                disabledReason: nil,
                onTap: {}
            )
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("取消", action: onCancel)
                .buttonStyle(.bordered)
                .disabled(isGenerating)
                .keyboardShortcut(.cancelAction)   // Esc 关闭（macOS sheet 默认不响应 Esc，必须显式挂）

            Button(action: confirm) {
                HStack {
                    if isGenerating {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isGenerating ? "生成中..." : "生成方案 (\(orderedSegments.count))")
                }
                .frame(minWidth: 100)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isGenerating || orderedSegments.count < 2)
        }
        .padding(DesignTokens.Spacing.comfortable)
    }

    private func moveLeft(_ index: Int) {
        guard index > 0 else { return }
        orderedSegments.swapAt(index, index - 1)
    }

    private func moveRight(_ index: Int) {
        guard index < orderedSegments.count - 1 else { return }
        orderedSegments.swapAt(index, index + 1)
    }

    private func confirm() {
        Task {
            isGenerating = true
            await onConfirm(orderedSegments)
            isGenerating = false
        }
    }
}
