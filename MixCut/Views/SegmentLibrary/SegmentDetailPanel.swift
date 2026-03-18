import SwiftUI
import AVKit

/// 分镜详情面板（右侧 340px）
struct SegmentDetailPanel: View {
    let segment: Segment
    @Bindable var viewModel: SegmentLibraryViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 预览播放器
                SegmentPreviewPlayer(segment: segment, viewModel: viewModel)

                // 基本信息
                infoSection

                Divider()

                // 台词
                if !segment.text.isEmpty {
                    textSection
                    Divider()
                }

                // 关键词
                if !segment.keywords.isEmpty {
                    keywordsSection
                    Divider()
                }

                // 质量评分
                qualitySection

                // 类型修改
                typePickerSection
            }
            .padding(16)
        }
    }

    // MARK: - 基本信息

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("基本信息")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            LabeledContent("索引") {
                Text(segment.segmentIndex)
                    .font(.system(size: 11))
            }

            if let video = segment.video {
                LabeledContent("来源视频") {
                    Text(video.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
            }

            LabeledContent("置信度") {
                Text(String(format: "%.0f%%", segment.confidence * 100))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
        }
    }

    // MARK: - 台词

    private var textSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("台词")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            EditableSegmentText(segment: segment)
        }
    }

    // MARK: - 关键词

    private var keywordsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("关键词")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            FlowLayout(spacing: 4) {
                ForEach(segment.keywords, id: \.self) { keyword in
                    Text(keyword)
                        .font(.system(size: 10))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.08))
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - 质量评分

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("质量评分")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f", segment.qualityScore))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(qualityColor)
            }

            if let reasoning = segment.qualityReasoning, !reasoning.isEmpty {
                Text(reasoning)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineSpacing(2)
            }
        }
    }

    private var qualityColor: Color {
        if segment.qualityScore >= 9.0 { return .green }
        if segment.qualityScore >= 8.0 { return .blue }
        if segment.qualityScore >= 7.0 { return .orange }
        return .red
    }

    // MARK: - 类型修改

    private var typePickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("类型修改")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("语义类型")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            FlowLayout(spacing: 4) {
                ForEach(SemanticType.allCases) { type in
                    let isActive = segment.semanticTypes.contains(type)
                    Button {
                        viewModel.toggleSemanticType(for: segment, type: type)
                    } label: {
                        Text(type.rawValue)
                            .font(.system(size: 10))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(isActive ? SemanticTypeTag.color(for: type).opacity(0.12) : Color.secondary.opacity(0.06))
                            .foregroundStyle(isActive ? SemanticTypeTag.color(for: type) : Color.secondary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            Picker("位置类型", selection: Binding(
                get: { segment.positionType },
                set: { viewModel.updatePositionType(for: segment, to: $0) }
            )) {
                ForEach(PositionType.allCases) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .controlSize(.small)
        }
    }
}

// MARK: - 预览播放器（响应 ViewModel 的 previewRequest）

struct SegmentPreviewPlayer: View {
    let segment: Segment
    @Bindable var viewModel: SegmentLibraryViewModel

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var timeObserver: Any?
    @State private var currentTime: Double = 0
    @State private var playEndTime: Double = 0

    private var aspectRatio: CGFloat {
        guard let video = segment.video, video.width > 0, video.height > 0 else {
            return 16.0 / 9.0
        }
        return CGFloat(video.width) / CGFloat(video.height)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let player {
                    PlayerRepresentable(player: player)
                        .aspectRatio(aspectRatio, contentMode: .fit)
                } else {
                    thumbnailView
                }

                if !isPlaying {
                    Color.black.opacity(0.15)
                    Button {
                        play(from: segment.startTime, to: segment.endTime)
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.3), radius: 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // 时间指示
            HStack {
                if isPlaying {
                    Button {
                        stopPlayback()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Text(isPlaying ?
                     String(format: "%.2f / %.2f - %.2fs", currentTime, segment.startTime, segment.endTime) :
                     String(format: "%.2f - %.2fs (%.1fs)", segment.startTime, segment.endTime, segment.duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        .onChange(of: viewModel.previewRequest) { _, newRequest in
            guard let request = newRequest,
                  request.segmentID == segment.id else { return }
            play(from: request.from, to: request.to)
            // 消费掉请求
            viewModel.previewRequest = nil
        }
        .onDisappear {
            cleanup()
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbPath = segment.thumbnailPath,
           let image = NSImage(contentsOfFile: thumbPath) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(aspectRatio, contentMode: .fit)
        } else {
            Rectangle()
                .fill(.quaternary)
                .aspectRatio(aspectRatio, contentMode: .fit)
                .overlay {
                    Image(systemName: "play.rectangle")
                        .foregroundStyle(.secondary)
                }
        }
    }

    private func play(from startTime: Double, to endTime: Double) {
        cleanup()

        guard let videoPath = segment.video?.localPath,
              FileManager.default.fileExists(atPath: videoPath) else { return }

        let item = AVPlayerItem(url: URL(fileURLWithPath: videoPath))
        let avPlayer = AVPlayer(playerItem: item)
        self.player = avPlayer
        self.playEndTime = endTime
        self.isPlaying = true

        let startCMTime = CMTime(seconds: startTime, preferredTimescale: 600)
        avPlayer.seek(to: startCMTime, toleranceBefore: .zero, toleranceAfter: .zero)

        let endCMTime = CMTime(seconds: endTime, preferredTimescale: 600)
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            currentTime = CMTimeGetSeconds(time)
            if time >= endCMTime {
                stopPlayback()
            }
        }

        avPlayer.play()
    }

    private func stopPlayback() {
        player?.pause()
        isPlaying = false
    }

    private func cleanup() {
        if let observer = timeObserver, let p = player {
            p.removeTimeObserver(observer)
        }
        timeObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
    }
}

// MARK: - 可编辑分镜台词
struct EditableSegmentText: View {
    let segment: Segment
    @State private var editText = ""
    @FocusState private var isFocused: Bool
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isFocused {
                TextEditor(text: $editText)
                    .font(.system(size: 11))
                    .lineSpacing(2)
                    .frame(minHeight: 60)
                    .padding(4)
                    .focused($isFocused)
                    .background(Color.accentColor.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                    )
            } else {
                Text(segment.text)
                    .font(.system(size: 11))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .onTapGesture(count: 2) {
                        editText = segment.text
                        isFocused = true
                    }

                Text("双击编辑台词")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { commitEdit() }
        }
    }

    private func commitEdit() {
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != segment.text else { return }
        segment.text = trimmed
        modelContext.safeSave()
    }
}

// MARK: - 流式布局（用于关键词标签）

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: ProposedViewSize(result.sizes[index])
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], sizes: [CGSize], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var sizes: [CGSize] = []
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

        return (positions, sizes, CGSize(width: maxX, height: y + rowHeight))
    }
}
