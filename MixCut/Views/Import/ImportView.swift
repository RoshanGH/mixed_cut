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
    @State private var isLoading = true

    var body: some View {
        // ⚠️ .task(id: project.id) 必须在 body 最外层，不能放进子分支（见 CLAUDE.md）
        Group {
            if isLoading {
                SkeletonView(layout: .importMedia)
            } else {
                mainContent
            }
        }
        .task(id: project.id) {
            let t0 = Date()
            isLoading = true
            // 切项目铁律：清空上一个项目的错误提示，避免红色 banner 跨项目残留
            importVM.errorMessage = nil
            let thumbPaths = project.videos.compactMap(\.thumbnailPath)
            ThumbnailCache.shared.prewarm(paths: thumbPaths)
            MixLog.info("[Perf] Import: \(Int(Date().timeIntervalSince(t0) * 1000))ms / videos=\(project.videos.count)")
            isLoading = false
        }
    }

    private var mainContent: some View {
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
                .scaleEffect(isDragTargeted ? 1.15 : 1.0)
                .animation(.spring(response: 0.35, dampingFraction: 0.65), value: isDragTargeted)
            Text(isDragTargeted ? "松开手即可导入" : "拖拽视频文件到此处")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isDragTargeted ? Color.accentColor : Color.primary)
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
                        .fill(isDragTargeted ? Color.accentColor.opacity(0.08) : .clear)
                )
        )
        .animation(.easeOut(duration: 0.2), value: isDragTargeted)
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
        let videos = project.videos   // 一次性取出，避免多次访问 SwiftData 关系
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("已导入视频")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(videos.count) 个视频")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // 每张卡片固定宽度约 400px (190*2 + 分隔线 + padding)，可并排
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380, maximum: 440))], alignment: .leading, spacing: 16) {
                ForEach(videos) { video in
                    ImportedVideoCard(video: video, onDelete: {
                        importVM.deleteVideo(video, from: project)
                    }, onRetryAI: {
                        ToastCenter.shared.show("重新分析中…", icon: "arrow.clockwise", style: .info)
                        Task {
                            await importVM.retryAIAnalysis(for: video, in: project)
                        }
                    }, onRetryASR: {
                        ToastCenter.shared.show("重新识别语音…", icon: "waveform", style: .info)
                        Task {
                            await importVM.retryASR(for: video, in: project)
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
            InlineBanner(style: .warning, message: error) {
                withAnimation(.easeOut(duration: 0.2)) {
                    importVM.errorMessage = nil
                }
            }
        }
    }
}

// MARK: - 视频卡片（左右等宽：左视频+信息 | 右台词可滚动）
struct ImportedVideoCard: View {
    let video: Video
    var onDelete: (() -> Void)?
    var onRetryAI: (() -> Void)?
    var onRetryASR: (() -> Void)?

    private let panelWidth: CGFloat = 190

    @State private var showDeleteConfirm = false
    @State private var isRetrying = false
    @State private var leftHeight: CGFloat = 300
    /// 缓存格式化后的句子列表，避免 body 重绘时反复重建 TranscriptionResult
    @State private var cachedSentences: [(index: Int, text: String, time: String)] = []
    @State private var cachedIsASRAbnormal: Bool = false

    private var videoAspectRatio: CGFloat {
        guard video.width > 0, video.height > 0 else { return 9.0 / 16.0 }
        return CGFloat(video.width) / CGFloat(video.height)
    }

    private var isProcessing: Bool {
        switch video.status {
        case .queued, .detectingScenes, .transcribing, .analyzing: return true
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

    /// 检测 ASR 输出粒度是否异常（基于 cachedSentences）
    private func computeIsASRAbnormal(_ sentences: [(index: Int, text: String, time: String)]) -> Bool {
        guard video.status == .completed else { return false }
        guard !sentences.isEmpty else { return false }
        if sentences.count == 1 && video.duration > 8.0 { return true }
        return sentences.contains { $0.text.count > 50 }
    }

    /// 刷新缓存（在 onAppear / video 关键字段变化时调用）
    private func refreshSentenceCache() {
        cachedSentences = formattedSentences
        cachedIsASRAbnormal = computeIsASRAbnormal(cachedSentences)
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
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(video.name, forType: .string)
                ToastCenter.shared.show("文件名已复制", icon: "doc.on.doc.fill")
            } label: {
                Label("复制文件名", systemImage: "doc.on.doc")
            }

            Button {
                let url = URL(fileURLWithPath: video.localPath)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
            }

            Divider()

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("删除视频", systemImage: "trash")
            }
        }
        .onChange(of: video.status) { _, newStatus in
            if newStatus != .analyzing { isRetrying = false }
            refreshSentenceCache()
        }
        .onChange(of: video.transcript) { _, _ in
            refreshSentenceCache()
        }
        .task {
            refreshSentenceCache()
        }
        .alert("确认删除", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                onDelete?()
                ToastCenter.shared.show("已删除「\(video.name)」", icon: "trash.fill", style: .warning)
            }
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

            // 文件名（可鼠标选中复制；自适应高度，完整显示）
            SelectableLabel(text: video.name, fontSize: 11, weight: .medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(video.name)

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

                // 白名单：只在「孤立 imported（未排队也未在跑）」或「明确 failed」时显示重试按钮
                // 防御性约束 — 即使未来 isProcessing 实现被改坏，queued/processing 状态也绝不会出按钮
                let canShowRetry = (video.status == .imported || video.status == .failed)
                                   && video.segments.isEmpty
                                   && !isRetrying
                                   && !isProcessing
                if canShowRetry {
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

                // ASR 异常时显示「重新识别」入口
                if cachedIsASRAbnormal, let onRetryASR {
                    Button {
                        onRetryASR()
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 8, weight: .bold))
                            Text("重做")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("ASR 分句异常，点击重新识别")
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // 异常提示条
            if cachedIsASRAbnormal {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                    Text("分句较粗，可点击右上「重做」或下方「拆分」")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.orange.opacity(0.06))
            }

            if cachedSentences.isEmpty {
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
                    // LazyVStack 自带懒加载，屏幕外的台词行不会同步实例化 NSTextField，
                    // 性能足够；不再需要折叠到 8 句的额外保护
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(cachedSentences, id: \.index) { item in
                            EditableSentenceRow(
                                time: item.time.isEmpty ? "\(item.index)" : item.time,
                                text: item.text,
                                sentenceIndex: item.index - 1,
                                video: video,
                                allowSplit: cachedIsASRAbnormal
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
           let image = ThumbnailCache.shared.image(for: thumbPath) {
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
        case .queued: return "等待中…"
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
                isDone: video.status != .imported && video.status != .queued && video.status != .detectingScenes,
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
    var allowSplit: Bool = false   // ASR 异常时由父视图传 true，显示「拆分」按钮

    @Environment(\.modelContext) private var modelContext
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(time)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary.opacity(0.4))
                .frame(width: 26, alignment: .trailing)
                .padding(.trailing, 4)

            // 点击即可编辑，文字随时可选中复制（AppKit NSTextField 原生能力）
            EditableSentenceField(text: text, fontSize: 11) { newValue in
                commitEdit(newValue)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if allowSplit && text.count >= 8 && (isHovered || text.count > 30) {
                Button {
                    splitSentence()
                } label: {
                    Image(systemName: "scissors")
                        .font(.system(size: 9))
                        .foregroundStyle(.blue.opacity(0.7))
                        .padding(2)
                }
                .buttonStyle(.plain)
                .help("从中点拆分为两句")
            }
        }
        .padding(.vertical, 3)
        .onHover { isHovered = $0 }
    }

    private func commitEdit(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// 把当前句子从字符中点（优先标点附近）拆成两句
    private func splitSentence() {
        var sentences = video.asrSentences
        guard sentenceIndex >= 0, sentenceIndex < sentences.count else { return }

        let current = sentences[sentenceIndex]
        guard current.text.count >= 6 else { return }

        // 找拆分点：优先在中点附近找标点，没有就用中点
        let midIdx = current.text.count / 2
        let chars = Array(current.text)
        let punct: Set<Character> = ["，", "。", "！", "？", "、", "；", "：", ",", ".", "!", "?", ";", ":"]

        var splitAt = midIdx
        // 在 [midIdx - 6, midIdx + 6] 范围内找最近标点
        for offset in 0..<min(6, midIdx) {
            if midIdx + offset < chars.count, punct.contains(chars[midIdx + offset]) {
                splitAt = midIdx + offset + 1; break
            }
            if midIdx - offset > 0, punct.contains(chars[midIdx - offset]) {
                splitAt = midIdx - offset + 1; break
            }
        }
        splitAt = max(1, min(chars.count - 1, splitAt))

        let firstText = String(chars[0..<splitAt]).trimmingCharacters(in: .whitespacesAndNewlines)
        let secondText = String(chars[splitAt..<chars.count]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !firstText.isEmpty, !secondText.isEmpty else { return }

        // 时间按字数比例分配
        let totalDur = current.end - current.start
        let firstRatio = Double(firstText.count) / Double(firstText.count + secondText.count)
        let midTime = current.start + totalDur * firstRatio

        let first = ASRSentence(text: firstText, start: current.start, end: midTime)
        let second = ASRSentence(text: secondText, start: midTime, end: current.end)

        sentences.remove(at: sentenceIndex)
        sentences.insert(second, at: sentenceIndex)
        sentences.insert(first, at: sentenceIndex)
        video.asrSentences = sentences

        let allText = sentences.map(\.text).joined(separator: " ")
        video.transcript = allText
        modelContext.safeSave()
    }
}

// MARK: - 可编辑 + 可选中复制的台词字段（AppKit NSTextField，不依赖 SwiftUI @FocusState）
struct EditableSentenceField: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let onCommit: (String) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.stringValue = text
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: fontSize)
        field.textColor = NSColor.labelColor.withAlphaComponent(0.85)
        field.lineBreakMode = .byWordWrapping
        field.usesSingleLineMode = false
        field.maximumNumberOfLines = 0
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.onCommit = onCommit
        // 外部文本变化且当前不在编辑时才同步，避免打断用户输入
        if !context.coordinator.isEditing, nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? 200
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        let measured = nsView.cell?.cellSize(forBounds: bounds).height ?? (fontSize + 6)
        return CGSize(width: width, height: ceil(max(measured, fontSize + 6)))
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCommit: onCommit) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onCommit: (String) -> Void
        var isEditing = false

        init(onCommit: @escaping (String) -> Void) {
            self.onCommit = onCommit
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            isEditing = true
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            isEditing = false
            guard let field = obj.object as? NSTextField else { return }
            onCommit(field.stringValue)
        }
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
        case .queued: return "hourglass"
        default: return "gearshape.2.fill"
        }
    }

    private var statusText: String {
        switch status {
        case .imported: return "已导入"
        case .queued: return "等待中"
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
        case .queued: return .blue
        case .detectingScenes, .transcribing, .analyzing: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }
}

// MARK: - 可鼠标选中复制的标签（NSTextField 包装，自适应高度完整显示）
struct SelectableLabel: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let weight: NSFont.Weight

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.isSelectable = true
        field.isEditable = false
        field.isBordered = false
        field.drawsBackground = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0          // 不限行数，完整显示
        field.font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        field.textColor = .labelColor
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.setContentHuggingPriority(.required, for: .vertical)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        nsView.font = NSFont.systemFont(ofSize: fontSize, weight: weight)
    }

    /// 按 SwiftUI 给定的宽度精确计算多行文本所需高度
    /// 用 cellSize(forBounds:) 纯计算，不调 invalidateIntrinsicContentSize（会触发无限布局循环）
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? 180
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        let measured = nsView.cell?.cellSize(forBounds: bounds).height ?? (fontSize + 4)
        return CGSize(width: width, height: ceil(max(measured, fontSize + 4)))
    }
}
