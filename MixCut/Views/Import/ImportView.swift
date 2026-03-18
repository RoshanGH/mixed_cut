import SwiftUI
import UniformTypeIdentifiers

/// 用于让右侧台词面板高度匹配左侧
private struct LeftPanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ImportView: View {
    let project: Project
    @Bindable var importVM: ImportViewModel
    @State private var isDragTargeted = false
    @State private var showingFilePicker = false

    var body: some View {
        VStack(spacing: 0) {
            if importVM.isProcessing {
                processingBanner
            }

            ScrollView {
                VStack(spacing: 20) {
                    importDropZone

                    errorBanner

                    if !project.videos.isEmpty {
                        videoListSection
                    }
                }
                .padding(24)
            }
        }
        .navigationTitle("素材导入")
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: ImportViewModel.supportedTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                var accessedURLs: [URL] = []
                for url in urls {
                    if url.startAccessingSecurityScopedResource() {
                        accessedURLs.append(url)
                    }
                }
                let videoURLs = accessedURLs.filter { isVideoFile($0) }
                guard !videoURLs.isEmpty else {
                    for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
                    return
                }
                Task {
                    await importVM.importVideos(urls: videoURLs, to: project)
                    for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
                }
            case .failure(let error):
                importVM.errorMessage = "选择文件失败: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - 处理进度
    private var processingBanner: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(importVM.phase.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                Text(importVM.progressDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ProgressView(value: importVM.progress)
                .frame(width: 120)
        }
        .padding(12)
        .background(.blue.opacity(0.06))
    }

    // MARK: - 拖拽导入区域
    private var importDropZone: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 48))
                .foregroundStyle(isDragTargeted ? Color.accentColor : Color.secondary)
            Text("拖拽视频文件到此处")
                .font(.system(size: 16, weight: .semibold))
            Text("支持 MP4, MOV, AVI 格式")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("选择文件") {
                showingFilePicker = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isDragTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [8])
                )
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isDragTargeted ? Color.accentColor.opacity(0.05) : .clear)
                )
        )
        .dropDestination(for: URL.self) { urls, _ in
            var accessedURLs: [URL] = []
            var securedURLs: [URL] = []
            for url in urls {
                if url.startAccessingSecurityScopedResource() {
                    securedURLs.append(url)
                }
                accessedURLs.append(url)
            }
            let videoURLs = accessedURLs.filter { isVideoFile($0) }
            guard !videoURLs.isEmpty else {
                for url in securedURLs { url.stopAccessingSecurityScopedResource() }
                return false
            }
            Task {
                await importVM.importVideos(urls: videoURLs, to: project)
                for url in securedURLs { url.stopAccessingSecurityScopedResource() }
            }
            return true
        } isTargeted: { targeted in
            isDragTargeted = targeted
        }
    }

    // MARK: - 已导入视频列表（网格并排）
    private var videoListSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("已导入视频")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(project.videos.count) 个视频")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // 每张卡片固定宽度约 400px (190*2 + 分隔线 + padding)，可并排
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380, maximum: 440))], alignment: .leading, spacing: 16) {
                ForEach(project.videos) { video in
                    ImportedVideoCard(video: video, onDelete: {
                        importVM.deleteVideo(video, from: project)
                    }, onRetryAI: {
                        Task {
                            await importVM.retryAIAnalysis(for: video, in: project)
                        }
                    })
                }
            }
        }
    }

    private func isVideoFile(_ url: URL) -> Bool {
        let videoExtensions = ["mp4", "mov", "avi", "m4v", "mkv"]
        return videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// 错误提示 banner（显示在视频列表上方）
    @ViewBuilder
    private var errorBanner: some View {
        if let error = importVM.errorMessage, !error.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    importVM.errorMessage = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .background(.orange.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - 视频卡片（左右等宽：左视频+信息 | 右台词可滚动）
struct ImportedVideoCard: View {
    let video: Video
    var onDelete: (() -> Void)?
    var onRetryAI: (() -> Void)?

    private let panelWidth: CGFloat = 190

    @State private var showDeleteConfirm = false
    @State private var isRetrying = false
    @State private var leftHeight: CGFloat = 300

    private var videoAspectRatio: CGFloat {
        guard video.width > 0, video.height > 0 else { return 9.0 / 16.0 }
        return CGFloat(video.width) / CGFloat(video.height)
    }

    private var isProcessing: Bool {
        switch video.status {
        case .detectingScenes, .transcribing, .analyzing: return true
        default: return false
        }
    }

    /// 用 ASR 时间戳数据构建语义句子
    private var formattedSentences: [(index: Int, text: String, time: String)] {
        let words = video.asrWords
        let transcript = video.transcript ?? ""

        // 优先用 Whisper 原生句子 + words 构建
        if !words.isEmpty || !video.asrSentences.isEmpty {
            let result = TranscriptionResult(
                text: transcript,
                words: words,
                rawSentences: video.asrSentences,
                language: "zh",
                duration: video.duration
            )
            let sentences = result.sentences
            guard !sentences.isEmpty else { return [] }
            return sentences.enumerated().map { i, s in
                let timeStr = String(format: "%d:%02d", Int(s.startTime) / 60, Int(s.startTime) % 60)
                return (index: i + 1, text: s.text, time: timeStr)
            }
        }

        guard !transcript.isEmpty else { return [] }
        var sentences: [String] = []
        var current = ""
        for char in transcript {
            current.append(char)
            if "。！？.!?".contains(char) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
        }
        let remainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty { sentences.append(remainder) }
        return sentences.enumerated().map { (index: $0.offset + 1, text: $0.element, time: "") }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 左侧：视频 + 信息（自然高度，决定整体高度）
            leftPanel
                .frame(width: panelWidth)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: LeftPanelHeightKey.self, value: geo.size.height)
                    }
                )

            // 分隔线
            Rectangle()
                .fill(.quaternary)
                .frame(width: 1)
                .padding(.vertical, 12)

            // 右侧：台词（等宽等高，内部滚动）
            rightPanel
                .frame(width: panelWidth, height: leftHeight, alignment: .top)
                .clipped()
        }
        .onPreferenceChange(LeftPanelHeightKey.self) { leftHeight = $0 }
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.large, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        .contextMenu {
            Button("删除视频", role: .destructive) {
                showDeleteConfirm = true
            }
        }
        .onChange(of: video.status) { _, newStatus in
            if newStatus != .analyzing { isRetrying = false }
        }
        .onChange(of: video.segments.count) { _, newCount in
            if newCount > 0 { isRetrying = false }
        }
        .alert("确认删除", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { onDelete?() }
        } message: {
            Text("确定要删除「\(video.name)」吗？视频文件和相关分镜数据都将被删除，此操作不可恢复。")
        }
    }

    // MARK: - 左侧面板
    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 视频播放器
            ZStack {
                if !isProcessing && video.status != .failed {
                    InlineVideoPlayer(
                        videoPath: video.localPath,
                        thumbnailPath: video.thumbnailPath,
                        aspectRatio: videoAspectRatio
                    )
                } else {
                    thumbnailOrPlaceholder
                }

                if isProcessing {
                    Color.black.opacity(0.55)
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(.white)
                        Text(processingLabel)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }

                if video.status == .failed {
                    Color.red.opacity(0.4)
                    VStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                        Text("处理失败")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            // 文件名
            Text(video.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)

            // 元数据
            HStack(spacing: 6) {
                if video.duration > 0 {
                    Label(formatDuration(video.duration), systemImage: "clock")
                }
                if video.width > 0 {
                    Label(video.resolution, systemImage: "rectangle.on.rectangle")
                }
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)

            // 流水线
            pipelineRow

            // 状态 + 操作
            HStack(spacing: 4) {
                VideoStatusBadge(status: video.status)
                Spacer()

                if video.segments.isEmpty && !isRetrying && !isProcessing {
                    Button {
                        isRetrying = true
                        onRetryAI?()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                            Text(video.errorMessage != nil ? "重试" : "AI分析")
                        }
                        .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }

                if isRetrying {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("分析中…")
                            .font(.system(size: 10))
                            .foregroundStyle(.blue)
                    }
                }
            }

            // 错误信息
            if let errorMsg = video.errorMessage, !errorMsg.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                        Text(errorMsg)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .textSelection(.enabled)
                    }
                }
            }

            // 分镜标签
            if !video.segments.isEmpty {
                segmentTags
            }
        }
        .padding(10)
    }

    // MARK: - 右侧面板（台词，可滚动）
    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题
            HStack(spacing: 5) {
                Image(systemName: "text.quote")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text("台词")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                if let transcript = video.transcript, !transcript.isEmpty {
                    Text("\(transcript.count)字")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.6))
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if formattedSentences.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "waveform.slash")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                    Text("暂无台词")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(formattedSentences, id: \.index) { item in
                            EditableSentenceRow(
                                time: item.time.isEmpty ? "\(item.index)" : item.time,
                                text: item.text,
                                sentenceIndex: item.index - 1,
                                video: video
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
        }
    }

    // MARK: - 缩略图占位
    @ViewBuilder
    private var thumbnailOrPlaceholder: some View {
        if let thumbPath = video.thumbnailPath,
           let image = NSImage(contentsOfFile: thumbPath) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(videoAspectRatio, contentMode: .fit)
        } else {
            Rectangle()
                .fill(.quaternary)
                .aspectRatio(videoAspectRatio, contentMode: .fit)
                .overlay {
                    Image(systemName: "film")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                }
        }
    }

    private var processingLabel: String {
        switch video.status {
        case .detectingScenes: return "1/3 视频分析中..."
        case .transcribing: return "2/3 语音识别中..."
        case .analyzing: return "3/3 AI 分析中..."
        default: return ""
        }
    }

    // MARK: - 处理流水线
    private var pipelineRow: some View {
        HStack(spacing: 2) {
            pipelineChip(
                label: "视频",
                isDone: video.status != .imported && video.status != .detectingScenes,
                isActive: video.status == .detectingScenes
            )
            Image(systemName: "chevron.right")
                .font(.system(size: 6))
                .foregroundStyle(.secondary.opacity(0.4))
            pipelineChip(
                label: "ASR",
                isDone: !(video.transcript ?? "").isEmpty,
                isActive: video.status == .transcribing
            )
            Image(systemName: "chevron.right")
                .font(.system(size: 6))
                .foregroundStyle(.secondary.opacity(0.4))
            pipelineChip(
                label: "AI",
                isDone: video.status == .completed,
                isActive: video.status == .analyzing
            )
        }
    }

    private func pipelineChip(label: String, isDone: Bool, isActive: Bool) -> some View {
        HStack(spacing: 2) {
            if isActive {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 8, height: 8)
            } else {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 8))
                    .foregroundStyle(isDone ? Color.green : Color.secondary.opacity(0.3))
            }
            Text(label)
                .font(.system(size: 9, weight: isDone || isActive ? .bold : .regular))
                .foregroundStyle(isDone || isActive ? Color.primary : Color.secondary.opacity(0.6))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(isDone ? Color.green.opacity(0.06) : isActive ? Color.orange.opacity(0.06) : Color.clear)
        .clipShape(Capsule())
    }

    // MARK: - 分镜标签
    private var segmentTags: some View {
        var typeCounts: [SemanticType: Int] = [:]
        for seg in video.segments {
            for t in seg.semanticTypes { typeCounts[t, default: 0] += 1 }
        }
        let sorted = typeCounts.sorted { $0.value > $1.value }

        return HStack(spacing: 4) {
            ForEach(sorted.prefix(5), id: \.key) { type, count in
                HStack(spacing: 1) {
                    Text(type.rawValue)
                        .font(.system(size: 9))
                    if count > 1 {
                        Text("\(count)")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(SemanticTypeTag.color(for: type).opacity(0.1))
                .foregroundStyle(SemanticTypeTag.color(for: type))
                .clipShape(Capsule())
            }

            if sorted.count > 5 {
                Text("+\(sorted.count - 5)")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - 可编辑台词行
struct EditableSentenceRow: View {
    let time: String
    let text: String
    let sentenceIndex: Int
    let video: Video

    @State private var editText: String = ""
    @FocusState private var isFocused: Bool
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(time)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary.opacity(0.4))
                .frame(width: 26, alignment: .trailing)
                .padding(.trailing, 4)

            if isFocused {
                TextField("", text: $editText, axis: .vertical)
                    .font(.system(size: 11))
                    .textFieldStyle(.plain)
                    .lineSpacing(2)
                    .padding(3)
                    .background(Color.accentColor.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .focused($isFocused)
                    .onSubmit { isFocused = false }
            } else {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture(count: 2) {
                        editText = text
                        isFocused = true
                    }
            }
        }
        .padding(.vertical, 3)
        .onChange(of: isFocused) { _, focused in
            if !focused { commitEdit() }
        }
    }

    private func commitEdit() {
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != text else { return }

        // 更新 ASR 句子数据
        var sentences = video.asrSentences
        if sentenceIndex >= 0 && sentenceIndex < sentences.count {
            sentences[sentenceIndex].text = trimmed
            video.asrSentences = sentences
        }

        // 同步更新 transcript
        let allText = sentences.map(\.text).joined(separator: " ")
        video.transcript = allText

        modelContext.safeSave()
    }
}

// MARK: - 状态徽章
struct VideoStatusBadge: View {
    let status: VideoStatus

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: statusIcon)
            Text(statusText)
        }
        .font(.system(size: 10, weight: .bold))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(statusColor.opacity(0.12))
        .foregroundStyle(statusColor)
        .clipShape(Capsule())
    }

    private var statusIcon: String {
        switch status {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .imported: return "arrow.down.circle.fill"
        default: return "gearshape.2.fill"
        }
    }

    private var statusText: String {
        switch status {
        case .imported: return "已导入"
        case .detectingScenes: return "检测镜头"
        case .transcribing: return "语音识别"
        case .analyzing: return "分析中"
        case .completed: return "处理完成"
        case .failed: return "失败"
        }
    }

    private var statusColor: Color {
        switch status {
        case .imported: return .gray
        case .detectingScenes, .transcribing, .analyzing: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }
}
