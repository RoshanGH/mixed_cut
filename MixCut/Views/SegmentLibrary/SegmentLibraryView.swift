import SwiftUI
import AVKit

struct SegmentLibraryView: View {
    let project: Project
    @Bindable var viewModel: SegmentLibraryViewModel

    var body: some View {
        VStack(spacing: 0) {
            filterToolbar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()

            if viewModel.filteredSegments.isEmpty {
                emptyState
            } else {
                segmentContent
            }
        }
        .onAppear {
            viewModel.loadSegments(for: project)
        }
        .onChange(of: project.id) {
            viewModel.loadSegments(for: project)
        }
        .navigationTitle("分镜素材库")
    }

    // MARK: - 筛选工具栏

    private var filterToolbar: some View {
        VStack(spacing: 10) {
            // 搜索 + 视图切换 + 排序
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    TextField("搜索台词或关键词...", text: $viewModel.filter.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .onChange(of: viewModel.filter.searchText) { _, _ in
                            viewModel.applyFilter()
                        }
                    if !viewModel.filter.searchText.isEmpty {
                        Button {
                            viewModel.filter.searchText = ""
                            viewModel.applyFilter()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Picker("视图", selection: $viewModel.isGridView) {
                    Image(systemName: "square.grid.2x2").tag(true)
                    Image(systemName: "list.bullet").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 80)

                Picker("排序", selection: $viewModel.sortByQuality) {
                    Text("时间").tag(false)
                    Text("质量").tag(true)
                }
                .onChange(of: viewModel.sortByQuality) { _, _ in
                    viewModel.applyFilter()
                }
                .frame(width: 100)
            }

            // 语义类型筛选芯片
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(SemanticType.allCases) { type in
                        FilterChip(
                            label: type.rawValue,
                            color: SemanticTypeTag.color(for: type),
                            isSelected: viewModel.filter.semanticTypes.contains(type)
                        ) {
                            if viewModel.filter.semanticTypes.contains(type) {
                                viewModel.filter.semanticTypes.remove(type)
                            } else {
                                viewModel.filter.semanticTypes.insert(type)
                            }
                            viewModel.applyFilter()
                        }
                    }
                }
            }

            // 统计 + 重置
            HStack(spacing: 8) {
                Text("\(viewModel.filteredSegments.count)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                +
                Text(" / \(viewModel.segments.count) 个分镜")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Spacer()

                if !viewModel.filter.semanticTypes.isEmpty || !viewModel.filter.searchText.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            viewModel.resetFilter()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                            Text("重置")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.5))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 按视频分组的内容区

    private var segmentContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(viewModel.groupedSegments) { group in
                    videoSection(group)
                }
            }
            .padding(16)
        }
    }

    private func videoSection(_ group: VideoSegmentGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 视频标题栏
            HStack(spacing: 10) {
                if let thumbPath = group.video.thumbnailPath,
                   let image = NSImage(contentsOfFile: thumbPath) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 36, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(.white.opacity(0.08), lineWidth: 1)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.quaternary)
                        .frame(width: 36, height: 28)
                        .overlay {
                            Image(systemName: "film")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.video.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text("\(group.segments.count) 个分镜 · \(String(format: "%.0f", group.video.duration))s")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Spacer()
            }
            .padding(.horizontal, 4)

            // 分镜卡片/行
            if viewModel.isGridView {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 360, maximum: 460))
                ], spacing: 12) {
                    ForEach(group.segments) { segment in
                        SegmentCard(segment: segment, viewModel: viewModel)
                    }
                }
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(group.segments) { segment in
                        SegmentRow(segment: segment, viewModel: viewModel)
                    }
                }
            }
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text("暂无分镜")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("请先导入视频并完成分析")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 分镜卡片

/// 用于让左面板高度传递给右面板
private struct SegmentLeftHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct SegmentCard: View {
    let segment: Segment
    @Bindable var viewModel: SegmentLibraryViewModel

    @State private var isHovering = false
    @State private var leftHeight: CGFloat = 180
    @State private var showDeleteConfirm = false

    private var isSelected: Bool {
        viewModel.selectedSegment?.id == segment.id
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 左侧：视频 + 标签 + 时间调整
            leftPanel
                .frame(width: 200)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: SegmentLeftHeightKey.self, value: geo.size.height)
                    }
                )

            // 分隔线
            Rectangle()
                .fill(.quaternary)
                .frame(width: 1)
                .padding(.vertical, 8)

            // 右侧：台词可滚动
            rightPanel
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: leftHeight)
                .clipped()
        }
        .onPreferenceChange(SegmentLeftHeightKey.self) { leftHeight = $0 }
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.06)
                      : isHovering
                        ? Color(.controlBackgroundColor).opacity(0.8)
                        : Color(.controlBackgroundColor).opacity(0.5))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor.opacity(0.5) : .white.opacity(0.04), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("删除分镜", systemImage: "trash")
            }
        }
        .alert("确认删除", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                viewModel.deleteSegment(segment)
            }
        } message: {
            Text("确定要删除这个分镜吗？此操作不可恢复。")
        }
    }

    // MARK: - 左侧面板
    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 播放器
            SegmentInlinePlayer(segment: segment, viewModel: viewModel)

            // 标签行：语义类型 + 位置
            FlowLayout(spacing: 3) {
                ForEach(segment.semanticTypes, id: \.self) { type in
                    SemanticTypeTag(type: type)
                }
                PositionTypeTag(type: segment.positionType)
                QualityBadge(score: segment.qualityScore)
            }

            // 边界微调
            BoundaryAdjustRow(segment: segment, viewModel: viewModel)
        }
        .padding(8)
    }

    // MARK: - 右侧台词面板
    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "text.quote")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text("台词")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(segment.text.count)字")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if segment.text.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "waveform.slash")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                    Text("暂无台词")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(segment.text)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
            }
        }
    }
}

// MARK: - 缩略图缓存（避免 View body 中反复磁盘 IO）

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [String: NSImage] = [:]

    func image(for path: String) -> NSImage? {
        if let cached = cache[path] { return cached }
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        cache[path] = img
        return img
    }

    func clear() { cache.removeAll() }
}

// MARK: - 分镜原地播放器（hover 播放，全局唯一播放，原始比例）

struct SegmentInlinePlayer: View {
    let segment: Segment
    @Bindable var viewModel: SegmentLibraryViewModel

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var timeObserver: Any?
    @State private var currentTime: Double = 0
    @State private var isHovering = false
    @State private var hoverTimer: Timer?

    /// 视频原始宽高比
    private var videoAspectRatio: CGFloat {
        guard let video = segment.video, video.width > 0, video.height > 0 else {
            return 16.0 / 9.0
        }
        return CGFloat(video.width) / CGFloat(video.height)
    }

    /// 显示用宽高比：竖版视频限制不超过 4:5，避免卡片过高
    private var displayAspectRatio: CGFloat {
        return max(videoAspectRatio, 4.0 / 5.0)
    }

    private var segmentDuration: Double {
        segment.endTime - segment.startTime
    }

    var body: some View {
        ZStack {
            if isPlaying, let player {
                // 播放器也用 fill + clip，和缩略图一样大小
                PlayerRepresentable(player: player)
                    .aspectRatio(videoAspectRatio, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(displayAspectRatio, contentMode: .fit)
                    .clipped()
            } else {
                thumbnailView
            }

            // 右下角时长角标（非 hover、非播放时显示）
            if !isPlaying && !isHovering {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(String(format: "%.1fs", segmentDuration))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.55))
                            .clipShape(Capsule())
                    }
                }
                .padding(5)
            }

            // hover 等待播放提示
            if isHovering && !isPlaying {
                Color.black.opacity(0.15)
                Image(systemName: "play.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.3), radius: 4)
            }

            // 播放中：底部进度条
            if isPlaying {
                VStack {
                    Spacer()
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.3)).frame(height: 3)
                            Capsule().fill(.white)
                                .frame(width: progressWidth(in: geo.size.width), height: 3)
                        }
                    }
                    .frame(height: 3)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                hoverTimer?.invalidate()
                hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
                    Task { @MainActor in
                        guard isHovering else { return }
                        viewModel.requestPlay(segment: segment)
                    }
                }
            } else {
                hoverTimer?.invalidate()
                hoverTimer = nil
                if isPlaying {
                    stopPlayback()
                    viewModel.stopCurrentPlayback()
                }
            }
        }
        .onChange(of: viewModel.playingSegmentID) { _, newID in
            if newID != segment.id && isPlaying {
                stopPlayback()
            }
        }
        .onChange(of: viewModel.previewRequest) { _, newRequest in
            guard let request = newRequest,
                  request.segmentID == segment.id else { return }
            play(from: request.from, to: request.to)
            viewModel.previewRequest = nil
        }
        .onDisappear {
            hoverTimer?.invalidate()
            stopPlayback()
        }
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        guard segmentDuration > 0 else { return 0 }
        let elapsed = currentTime - segment.startTime
        return totalWidth * max(0, min(1, elapsed / segmentDuration))
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbPath = segment.thumbnailPath,
           let image = ThumbnailCache.shared.image(for: thumbPath) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity)
                .aspectRatio(displayAspectRatio, contentMode: .fit)
                .clipped()
        } else {
            Rectangle()
                .fill(Color(.windowBackgroundColor).opacity(0.3))
                .aspectRatio(displayAspectRatio, contentMode: .fit)
                .overlay {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                }
        }
    }

    private func play(from startTime: Double, to endTime: Double) {
        stopPlayback()

        guard let videoPath = segment.video?.localPath,
              FileManager.default.fileExists(atPath: videoPath) else { return }

        let item = AVPlayerItem(url: URL(fileURLWithPath: videoPath))
        let avPlayer = AVPlayer(playerItem: item)
        self.player = avPlayer
        isPlaying = true

        let startCMTime = CMTime(seconds: startTime, preferredTimescale: 600)
        avPlayer.seek(to: startCMTime, toleranceBefore: .zero, toleranceAfter: .zero)

        let endCMTime = CMTime(seconds: endTime, preferredTimescale: 600)
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [self] time in
            currentTime = CMTimeGetSeconds(time)
            if time >= endCMTime {
                Task { @MainActor in
                    stopPlayback()
                    viewModel.stopCurrentPlayback()
                }
            }
        }

        avPlayer.play()
    }

    private func stopPlayback() {
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

// MARK: - 分镜行（列表模式）

struct SegmentRow: View {
    let segment: Segment
    @Bindable var viewModel: SegmentLibraryViewModel
    @State private var isHovering = false

    private var isSelected: Bool {
        viewModel.selectedSegment?.id == segment.id
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SegmentInlinePlayer(segment: segment, viewModel: viewModel)
                .frame(width: 160)

            VStack(alignment: .leading, spacing: 6) {
                // 标签行
                HStack(spacing: 4) {
                    ForEach(segment.semanticTypes.prefix(3), id: \.self) { type in
                        SemanticTypeTag(type: type)
                    }
                    PositionTypeTag(type: segment.positionType)
                    Spacer()
                    QualityBadge(score: segment.qualityScore)
                }

                Text(segment.text)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .foregroundStyle(.secondary)

                BoundaryAdjustRow(segment: segment, viewModel: viewModel)
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.06)
                      : isHovering
                        ? Color(.controlBackgroundColor).opacity(0.8)
                        : Color(.controlBackgroundColor).opacity(0.5))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.5) : .white.opacity(0.04), lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .onTapGesture {
            viewModel.selectedSegment = segment
        }
    }
}

// MARK: - 质量分徽章

struct QualityBadge: View {
    let score: Double

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "star.fill")
                .font(.system(size: 7))
            Text(String(format: "%.1f", score))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(badgeColor)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(badgeColor.opacity(0.1))
        .clipShape(Capsule())
    }

    private var badgeColor: Color {
        if score >= 9.0 { return .green }
        if score >= 8.0 { return .blue }
        if score >= 7.0 { return .orange }
        return .red
    }
}

// MARK: - 语义类型标签

struct SemanticTypeTag: View {
    let type: SemanticType

    var body: some View {
        Text(type.rawValue)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Self.color(for: type).opacity(0.12))
            .foregroundStyle(Self.color(for: type))
            .clipShape(Capsule())
    }

    static func color(for type: SemanticType) -> Color {
        switch type {
        case .hook: return .red
        case .painPoint: return .orange
        case .solution: return .blue
        case .results: return .green
        case .socialProof: return .purple
        case .priceAnchor: return .yellow
        case .promotion: return .pink
        case .callToAction: return .mint
        case .productPositioning: return .teal
        case .usageEducation: return .indigo
        case .transition: return .gray
        }
    }
}

// MARK: - 位置类型标签

struct PositionTypeTag: View {
    let type: PositionType

    var body: some View {
        Text(type.rawValue)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.secondary.opacity(0.08))
            .clipShape(Capsule())
    }
}

// MARK: - 筛选芯片

struct FilterChip: View {
    let label: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? color.opacity(0.15) : Color.secondary.opacity(0.06))
                .foregroundStyle(isSelected ? color : .secondary)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(isSelected ? color.opacity(0.3) : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 边界微调行

struct BoundaryAdjustRow: View {
    let segment: Segment
    @Bindable var viewModel: SegmentLibraryViewModel

    private enum TimeField: Hashable {
        case start, end
    }

    @State private var startTimeText: String = ""
    @State private var endTimeText: String = ""
    @FocusState private var focusedField: TimeField?

    var body: some View {
        HStack(spacing: 4) {
            // IN 时间组
            HStack(spacing: 2) {
                adjustButton(systemName: "minus") {
                    viewModel.adjustStartTime(for: segment, by: -0.1)
                }
                TextField("", text: $startTimeText)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(focusedField == .start ? .primary : .secondary)
                    .focused($focusedField, equals: .start)
                    .onSubmit { commitStartTime() }
                    .frame(width: 32, height: 16)
                    .background(focusedField == .start ? Color.accentColor.opacity(0.08) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                adjustButton(systemName: "plus") {
                    viewModel.adjustStartTime(for: segment, by: 0.1)
                }
            }

            Text("–")
                .font(.system(size: 9))
                .foregroundStyle(.quaternary)

            // OUT 时间组
            HStack(spacing: 2) {
                adjustButton(systemName: "minus") {
                    viewModel.adjustEndTime(for: segment, by: -0.1)
                }
                TextField("", text: $endTimeText)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(focusedField == .end ? .primary : .secondary)
                    .focused($focusedField, equals: .end)
                    .onSubmit { commitEndTime() }
                    .frame(width: 32, height: 16)
                    .background(focusedField == .end ? Color.accentColor.opacity(0.08) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                adjustButton(systemName: "plus") {
                    viewModel.adjustEndTime(for: segment, by: 0.1)
                }
            }

            Spacer(minLength: 0)

            // 类型编辑 + 删除
            Menu {
                ForEach(SemanticType.allCases) { type in
                    Button {
                        viewModel.toggleSemanticType(for: segment, type: type)
                    } label: {
                        HStack {
                            Text(type.rawValue)
                            if segment.semanticTypes.contains(type) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
                ForEach(PositionType.allCases) { type in
                    Button {
                        viewModel.updatePositionType(for: segment, to: type)
                    } label: {
                        HStack {
                            Text(type.rawValue)
                            if segment.positionType == type {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, height: 18)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .onChange(of: focusedField) { oldField, _ in
            // 焦点离开时自动保存
            if oldField == .start { commitStartTime() }
            if oldField == .end { commitEndTime() }
        }
        .onAppear {
            startTimeText = String(format: "%.1f", segment.startTime)
            endTimeText = String(format: "%.1f", segment.endTime)
        }
        .onChange(of: segment.startTime) { _, newVal in
            if focusedField != .start {
                startTimeText = String(format: "%.1f", newVal)
            }
        }
        .onChange(of: segment.endTime) { _, newVal in
            if focusedField != .end {
                endTimeText = String(format: "%.1f", newVal)
            }
        }
    }

    private func commitStartTime() {
        guard let newValue = Double(startTimeText), newValue >= 0 else { return }
        // 不允许开始时间 >= 结束时间
        guard newValue < segment.endTime else {
            startTimeText = String(format: "%.2f", segment.startTime)
            return
        }
        if abs(newValue - segment.startTime) > 0.01 {
            viewModel.setStartTime(for: segment, to: newValue)
        }
    }

    private func commitEndTime() {
        guard let newValue = Double(endTimeText), newValue > 0 else { return }
        // 不允许结束时间 <= 开始时间
        guard newValue > segment.startTime else {
            endTimeText = String(format: "%.2f", segment.endTime)
            return
        }
        if abs(newValue - segment.endTime) > 0.01 {
            viewModel.setEndTime(for: segment, to: newValue)
        }
    }

    private func adjustButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 7, weight: .heavy))
                .foregroundStyle(.tertiary)
                .frame(width: 18, height: 18)
                .background(.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(.secondary.opacity(0.1), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
}
