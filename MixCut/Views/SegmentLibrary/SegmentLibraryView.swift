import SwiftUI
import AVKit
import AppKit
import UniformTypeIdentifiers

struct SegmentLibraryView: View {
    let project: Project
    @Bindable var viewModel: SegmentLibraryViewModel
    @Bindable var schemeVM: SchemeViewModel

    @State private var showBatchExportSheet = false
    @State private var showBatchDeleteConfirm = false
    @State private var showArrangeSheet = false
    @State private var isLoading = true
    @State private var dubVM = DubbingViewModel()
    /// 搜索防抖任务句柄：新按键到来时取消上一个，避免每敲一个字就全量重算。
    @State private var searchDebounceTask: Task<Void, Never>?
    /// 字幕烧录字号（全局设置，与卡片预览、导出共用同一 UserDefaults 键）
    @State private var importVM = ImportViewModel()
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        // ⚠️ .task(id: project.id) 必须在 body 最外层，不能放进子分支（见 CLAUDE.md）
        Group {
            if isLoading {
                SkeletonView(layout: .segmentLibrary)
            } else {
                mainContent
            }
        }
        .task(id: project.id) {
            importVM.setModelContext(modelContext)
            let t0 = Date()
            isLoading = true
            // 退出多选模式 + 清空选中（避免不同项目的 ID 串到一起）
            viewModel.setSelectionMode(false)
            let thumbPaths = project.videos.compactMap(\.thumbnailPath)
            ThumbnailCache.shared.prewarm(paths: thumbPaths)
            viewModel.loadSegments(for: project)
            // ⚠️ 真正铺满屏幕的是**分镜**缩略图（可达数百张），上面那行只预热了每个视频 1 张封面。
            // 不预热的话，LazyVGrid 每滚出一行都要在主线程同步读盘+解码 → 滚动掉帧。
            // 放在 loadSegments 之后，因为要用它算出来的分镜列表。
            ThumbnailCache.shared.prewarm(paths: viewModel.segments.compactMap(\.thumbnailPath))
            MixLog.info("[Perf] SegmentLibrary: \(Int(Date().timeIntervalSince(t0) * 1000))ms / segs=\(viewModel.segments.count)")
            isLoading = false
        }
    }

    /// 上传自建分镜：选 mp4/mov → 交给 ImportViewModel 处理（时长校验/ASR/打标），进度回调刷新分镜库
    private func presentSelfSegmentUpload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
        panel.prompt = "上传"
        panel.message = "选择要作为自建分镜上传的视频（单条 ≤ \(Int(ImportViewModel.selfSegmentMaxDuration)) 秒）"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task { @MainActor in
            await importVM.importSelfSegments(urls: urls, into: project) {
                viewModel.loadSegments(for: project)
            }
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            filterToolbar
                .padding(.horizontal, DesignTokens.Padding.page)
                .padding(.vertical, 12)
                // 用原生工具栏材质而非纯色：内容滚动到下方时透出模糊，
                // 形成 macOS 应有的"工具条浮在内容之上"的层次感（原来全靠平铺的半透明灰）。
                .background(.bar)

            if viewModel.isSelectionMode {
                Divider()
                batchActionBar
                    .padding(.horizontal, DesignTokens.Padding.page)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.06))
            }

            Divider()

            HStack(spacing: 0) {
                Group {
                    if viewModel.filteredSegments.isEmpty {
                        emptyState
                    } else {
                        segmentContent
                    }
                }
                .frame(maxWidth: .infinity)

                if let seg = viewModel.selectedSegment {
                    Divider()
                    SegmentVariantInspector(segment: seg, dubVM: dubVM)
                }
            }
        }
        .navigationTitle("分镜素材库")
        // ⚠️ 配音错误的 alert 必须挂在**页面顶层**。
        // 原先它挂在 DubSettingsBar 里，而那个组件只在「普通视频」分组标题行渲染，
        // 外层还是 LazyVStack —— 于是两种情况下报错完全看不到：
        //   ① 项目只有「自建分镜」（该分支不渲染 DubSettingsBar）
        //   ② 分组标题被滚出可视区，Lazy 容器把宿主回收掉
        // 结果就是配音失败后界面只是转一圈然后恢复原样，用户完全不知道发生了什么。
        .alert("配音", isPresented: Binding(
            get: { dubVM.errorMessage != nil },
            set: { if !$0 { dubVM.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { dubVM.errorMessage = nil }
        } message: {
            Text(dubVM.errorMessage ?? "")
        }
        .sheet(item: $viewModel.shotEditRequestSegment) { seg in
            ShotEditSheet(segment: seg)
        }
        .sheet(item: $viewModel.splitRequestSegment) { seg in
            SplitSegmentSheet(segment: seg, importVM: importVM) {
                viewModel.loadSegments(for: project)
            }
        }
        .sheet(isPresented: $showBatchExportSheet) {
            BatchExportSheet(
                segments: viewModel.selectedSegments,
                numberProvider: { viewModel.number(for: $0) }
            )
        }
        .background(
            // 隐藏快捷键：ESC 退出多选；⌘A 全选；⌘D 反选；⌘0 清空
            Group {
                if viewModel.isSelectionMode {
                    Button("") {
                        withAnimation(DesignTokens.Motion.hover) {
                            viewModel.setSelectionMode(false)
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)

                    Button("") { viewModel.selectAllVisible() }
                        .keyboardShortcut("a", modifiers: .command)
                        .opacity(0)

                    Button("") { viewModel.invertSelectionVisible() }
                        .keyboardShortcut("d", modifiers: .command)
                        .opacity(0)

                    Button("") { viewModel.clearSelection() }
                        .keyboardShortcut("0", modifiers: .command)
                        .opacity(0)
                }
            }
        )
    }

    // MARK: - 多选操作栏（启用多选时显示）

    private var batchActionBar: some View {
        HStack(spacing: DesignTokens.Spacing.normal) {
            Image(systemName: "checkmark.square.fill")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(Color.accentColor)
            // ⚠️ 这一行元素多、且都是中文：不加 lineLimit/fixedSize 的话，
            // 窄窗口下 SwiftUI 会把中文逐字换行，压成竖排单字（导入页标签就踩过这个坑）。
            Text("已选 \(viewModel.selectedSegmentIDs.count) 个 · \(String(format: "%.1fs", viewModel.selectedDuration))")
                .font(DesignTokens.Typography.labelEmphasis)
                .lineLimit(1)
                .fixedSize()

            Divider().frame(height: 12)

            // ⚠️ `.buttonStyle(.plain)` 不会自动做 disabled 减淡，而显式 `.foregroundStyle`
            // 又会**覆盖**系统的禁用态着色 —— 结果禁用和可用像素级一致，用户点了没反应会以为卡死。
            // 这里改用 `.borderless`（原生支持禁用态），颜色交给 tint。
            Button("全选") { viewModel.selectAllVisible() }
                .buttonStyle(.borderless)
                .font(DesignTokens.Typography.caption)
                .lineLimit(1)
                .fixedSize()

            Button("反选") { viewModel.invertSelectionVisible() }
                .buttonStyle(.borderless)
                .font(DesignTokens.Typography.caption)
                .lineLimit(1)
                .fixedSize()

            Button("清空选择") { viewModel.clearSelection() }
                .buttonStyle(.borderless)
                .font(DesignTokens.Typography.caption)
                .lineLimit(1)
                .fixedSize()
                .disabled(viewModel.selectedSegmentIDs.isEmpty)

            // 发现性提示：⇧+点击是隐藏能力，不提示用户根本不会知道
            Text("⇧ 点击可连选")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
                .help("按住 Shift 点击另一个分镜，可一次选中两者之间的全部分镜")

            Spacer()

            Button {
                showBatchDeleteConfirm = true
            } label: {
                HStack(spacing: DesignTokens.Spacing.tight) {
                    Image(systemName: "trash")
                        .font(DesignTokens.Typography.captionEmphasis)
                    Text("批量删除")
                        .font(DesignTokens.Typography.labelEmphasis)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
            .disabled(viewModel.selectedSegmentIDs.isEmpty)

            Button {
                showArrangeSheet = true
            } label: {
                HStack(spacing: DesignTokens.Spacing.tight) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(DesignTokens.Typography.captionEmphasis)
                    Text("组合为方案")
                        .font(DesignTokens.Typography.labelEmphasis)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.purple)
            .disabled(viewModel.selectedSegmentIDs.count < 2)
            .help(viewModel.selectedSegmentIDs.count < 2 ? "至少选择 2 个分镜" : "把选中分镜组合为自定义方案")

            Button {
                showBatchExportSheet = true
            } label: {
                HStack(spacing: DesignTokens.Spacing.tight) {
                    Image(systemName: "square.and.arrow.up")
                        .font(DesignTokens.Typography.captionEmphasis)
                    Text("批量导出 \(viewModel.selectedSegmentIDs.count) 个")
                        .font(DesignTokens.Typography.labelEmphasis)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(viewModel.selectedSegmentIDs.isEmpty)
        }
        .sheet(isPresented: $showArrangeSheet) {
            ArrangeOrderSheet(
                // 用"勾选先后顺序"而非"按时间排序"——尊重用户挑选先后
                initialSegments: viewModel.orderedSelectedSegments,
                onCancel: { showArrangeSheet = false },
                onConfirm: { ordered in
                    // ⚠️ 不要在 await 之前关窗：sheet 自带的 isGenerating 转圈才有机会显示，
                    // 否则整个 AI 调用期间界面毫无指示，用户以为"点了没反应"。
                    let scheme = await schemeVM.createCustomScheme(from: ordered, in: project)
                    showArrangeSheet = false
                    if scheme != nil {
                        ToastCenter.shared.show("自定义方案已生成", icon: "checkmark.circle.fill", style: .success)
                        viewModel.setSelectionMode(false)
                        // 通过通知跳转到方案板块
                        NotificationCenter.default.post(name: .mixCutNavigate, object: NavigationItem.schemes)
                    } else {
                        // 失败必须出声：此前没有 else 分支，用户只会看到 toast 淡出后什么都没发生。
                        ToastCenter.shared.show(schemeVM.errorMessage ?? "方案生成失败，请重试",
                                                icon: "exclamationmark.triangle.fill", style: .warning, duration: 4)
                    }
                }
            )
        }
        .alert("确认批量删除", isPresented: $showBatchDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                // Toast（含「撤销」按钮）由 deleteSelectedSegments 内部弹出
                viewModel.deleteSelectedSegments()
            }
        } message: {
            Text("将删除 \(viewModel.selectedSegmentIDs.count) 个分镜。删除后 5 秒内可点「撤销」找回。")
        }
    }

    // MARK: - 筛选工具栏

    private var filterToolbar: some View {
        VStack(spacing: 10) {
            // 搜索 + 视图切换 + 排序
            HStack(spacing: DesignTokens.Spacing.normal) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(DesignTokens.Typography.label)
                        .foregroundStyle(.tertiary)
                    TextField("搜索台词或关键词...", text: $viewModel.filter.searchText)
                        .textFieldStyle(.plain)
                        .font(DesignTokens.Typography.body)
                        // 防抖：每次按键都跑 applyFilter 会对全部分镜重新筛选 + 排序 + 重建分组，
                        // 分镜多时打字会明显掉帧。停止输入 250ms 后再算一次。
                        .onChange(of: viewModel.filter.searchText) { _, _ in
                            searchDebounceTask?.cancel()
                            searchDebounceTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 250_000_000)
                                guard !Task.isCancelled else { return }
                                viewModel.applyFilter()
                            }
                        }
                    if !viewModel.filter.searchText.isEmpty {
                        Button {
                            viewModel.filter.searchText = ""
                            viewModel.applyFilter()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(DesignTokens.Typography.label)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清空搜索")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(DesignTokens.Palette.Alpha.strong))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                // 图标分段控件隐藏文字标签：标签和控件挤在 80pt 固定宽里，
                // 会把「视图」压成竖排单字。图标语义自明，用 tooltip 补充说明即可。
                Picker("视图", selection: $viewModel.isGridView) {
                    Image(systemName: "square.grid.2x2").tag(true)
                    Image(systemName: "list.bullet").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 72)
                .help("切换网格 / 列表视图")

                Picker("排序", selection: $viewModel.sortByQuality) {
                    Text("时间").tag(false)
                    Text("质量").tag(true)
                }
                .onChange(of: viewModel.sortByQuality) { _, _ in
                    viewModel.applyFilter()
                }
                // 宽度要同时容纳「排序」标签 + 选项，原来的 100pt 会把标签挤换行
                .frame(width: 150)


                // 多选开关
                Button {
                    viewModel.setSelectionMode(!viewModel.isSelectionMode)
                } label: {
                    HStack(spacing: DesignTokens.Spacing.tight) {
                        Image(systemName: viewModel.isSelectionMode
                            ? "checkmark.square.fill" : "square.dashed")
                            .font(DesignTokens.Typography.captionEmphasis)
                        Text(viewModel.isSelectionMode ? "退出多选" : "多选")
                            .font(DesignTokens.Typography.labelStrong)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(viewModel.isSelectionMode
                        ? Color.accentColor.opacity(0.15)
                        : Color.secondary.opacity(0.08))
                    .foregroundStyle(viewModel.isSelectionMode ? Color.accentColor : .primary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                // 上传自建分镜（PRD 05）：分镜库工具栏右侧常驻
                Button {
                    presentSelfSegmentUpload()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.up")
                            .font(DesignTokens.Typography.captionEmphasis)
                        Text("上传自建分镜")
                            .font(DesignTokens.Typography.bodyEmphasis)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("上传自己剪好的分镜（mp4/mov，单条 ≤ \(Int(ImportViewModel.selfSegmentMaxDuration)) 秒）")
            }

            // 语义类型筛选芯片
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(SemanticType.allCases) { type in
                        FilterChip(
                            label: type.rawValue,
                            color: SemanticTypeTag.color(for: type),
                            count: viewModel.countByType[type] ?? 0,
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
            HStack(spacing: DesignTokens.Spacing.compact) {
                Text("\(viewModel.filteredSegments.count)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                +
                Text(" / \(viewModel.segments.count) 个分镜")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(.secondary)

                Spacer()

                if !viewModel.filter.semanticTypes.isEmpty || !viewModel.filter.searchText.isEmpty {
                    Button {
                        withAnimation(DesignTokens.Motion.transition) {
                            viewModel.resetFilter()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "xmark")
                                .font(DesignTokens.Typography.microBold)
                            Text("重置")
                                .font(DesignTokens.Typography.caption)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(DesignTokens.Palette.Alpha.strong))
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
            LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.generous) {
                ForEach(viewModel.groupedSegments) { group in
                    videoSection(group)
                }
            }
            .padding(DesignTokens.Spacing.comfortable)
        }
    }

    /// 视频编号：与素材导入页徽章、Agent（MCP）的 video_no 同一套规则——
    /// 项目内按导入时间升序 1 起，动态计算，删除后自动前补
    private var videoNoByID: [UUID: Int] {
        Dictionary(uniqueKeysWithValues:
            project.projectVideos
                .sorted { $0.addedAt < $1.addedAt }
                .compactMap(\.video)
                .enumerated()
                .map { ($0.element.id, $0.offset + 1) })
    }

    private func videoSection(_ group: VideoSegmentGroup) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.normal) {
            // 标题栏：自建分镜聚合组 vs 普通视频分组
            HStack(spacing: 10) {
                if group.isSelfBuilt {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 20, height: 36)
                        .overlay {
                            Image(systemName: "square.and.arrow.up")
                                .font(DesignTokens.Typography.label)
                                .foregroundStyle(Color.accentColor)
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自建分镜")
                            .font(DesignTokens.Typography.labelStrong)
                            .lineLimit(1)
                        Text("\(group.segments.count) 个分镜 · 我上传的")
                            .font(DesignTokens.Typography.microRegular)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                } else if let video = group.video {
                    if let thumbPath = video.thumbnailPath,
                       let image = ThumbnailCache.shared.image(for: thumbPath) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 20, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(DesignTokens.Palette.border, lineWidth: 1)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.quaternary)
                            .frame(width: 20, height: 36)
                            .overlay {
                                Image(systemName: "film")
                                    .font(DesignTokens.Typography.microRegular)
                                    .foregroundStyle(.tertiary)
                            }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if let no = videoNoByID[video.id] {
                                Text("\(no) 号")
                                    .font(DesignTokens.Typography.caption.bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 1.5)
                                    .background(.black.opacity(0.62), in: Capsule())
                            }
                            Text(video.name)
                                .font(DesignTokens.Typography.labelStrong)
                                .lineLimit(1)
                        }
                        Text("\(group.segments.count) 个分镜 · \(String(format: "%.0f", video.duration))s")
                            .font(DesignTokens.Typography.microRegular)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    // 视频专属「配音」栏（自建分镜组由多个载体视频组成，不显示视频级批量栏，逐卡各自配音）
                    // 放进分组标题行：这些控件作用于「这个视频」，单独占一行浮在右侧看不出归属。
                    DubSettingsBar(video: video, dubVM: dubVM)
                }
            }
            .padding(.horizontal, 4)

            // 分镜卡片/行
            // 性能关键：父视图在 ForEach 内一次性算 isChecked / sequenceNumber，
            // 传给 SegmentCard 作为 props。SegmentCard 实现 Equatable + .equatable() 后，
            // 选中变化只会重绘那一个卡片，其他卡片跳过 body 评估。
            let selectionMode = viewModel.isSelectionMode
            let selectedIDs = viewModel.selectedSegmentIDs    // 读一次本地变量
            let selectedSegID = viewModel.selectedSegment?.id // 读一次：检视栏选中分镜
            let numMap = viewModel.numberByVideo[group.id] ?? [:]   // group.id = 视频id 或 自建分镜组固定id
            if viewModel.isGridView {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 360, maximum: 460))
                ], spacing: DesignTokens.Spacing.normal) {
                    ForEach(group.segments) { segment in
                        SegmentCard(
                            segment: segment,
                            isChecked: selectedIDs.contains(segment.id),
                            isSelectionMode: selectionMode,
                            isSelected: segment.id == selectedSegID,
                            sequenceNumber: numMap[segment.id] ?? 0,
                            viewModel: viewModel
                        )
                        .equatable()
                    }
                }
            } else {
                LazyVStack(spacing: DesignTokens.Spacing.compact) {
                    ForEach(group.segments) { segment in
                        SegmentRow(
                            segment: segment,
                            isChecked: selectedIDs.contains(segment.id),
                            isSelectionMode: selectionMode,
                            isSelected: segment.id == selectedSegID,
                            sequenceNumber: numMap[segment.id] ?? 0,
                            viewModel: viewModel
                        )
                        .equatable()
                    }
                }
            }
        }
    }

    // MARK: - 空状态

    /// 是否"本来就没有分镜"（而非被筛选条件挡掉了）。
    /// 两种情况的文案与出口完全不同，混用会出现「已有 200 个分镜却提示请先导入视频」的误导。
    private var hasNoSegmentsAtAll: Bool { viewModel.segments.isEmpty }

    @ViewBuilder
    private var emptyState: some View {
        if hasNoSegmentsAtAll {
            emptyStateNoData
        } else {
            emptyStateNoMatch
        }
    }

    /// 真的一个分镜都没有 —— 给明确的下一步出口，别让用户困在死胡同里。
    private var emptyStateNoData: some View {
        VStack(spacing: DesignTokens.Spacing.comfortable) {
            Image(systemName: "film.stack")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.tertiary)
            VStack(spacing: DesignTokens.Spacing.tight) {
                Text("还没有分镜")
                    .font(DesignTokens.Typography.sectionTitle)
                    .foregroundStyle(.secondary)
                Text("导入视频后，AI 会自动切分并标注分镜；也可以直接上传已剪好的分镜。")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            HStack(spacing: DesignTokens.Spacing.compact) {
                Button {
                    NotificationCenter.default.post(name: .mixCutNavigate, object: NavigationItem.importMedia)
                } label: {
                    Label("去导入视频", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    presentSelfSegmentUpload()
                } label: {
                    Label("上传自建分镜", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 有数据但被筛选挡掉了 —— 给「清除筛选」而不是"请先导入视频"。
    private var emptyStateNoMatch: some View {
        VStack(spacing: DesignTokens.Spacing.comfortable) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.tertiary)
            VStack(spacing: DesignTokens.Spacing.tight) {
                Text("没有符合条件的分镜")
                    .font(DesignTokens.Typography.sectionTitle)
                    .foregroundStyle(.secondary)
                Text("共 \(viewModel.segments.count) 个分镜，当前筛选条件下没有匹配项。")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(.tertiary)
            }
            Button {
                viewModel.clearFilters()
            } label: {
                Label("清除筛选条件", systemImage: "xmark.circle")
            }
            .buttonStyle(.borderedProminent)
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

/// SegmentCard 关键性能优化：
/// - 实现 Equatable，让 SwiftUI 在 reconcile 时跳过未变化的卡片 body 评估
/// - isChecked / isSelectionMode / sequenceNumber 通过 props 接收，**不直接访问 viewModel**
///   避免「访问 selectedSegmentIDs → 整个 Set 注册依赖 → 任意选中变化触发所有卡片重绘」的陷阱
/// - viewModel 仍然持有，用于 action（toggleSelection / deleteSegment / requestPlay）
struct SegmentCard: View, Equatable {
    let segment: Segment
    let isChecked: Bool
    let isSelectionMode: Bool
    let isSelected: Bool
    let sequenceNumber: Int
    @Bindable var viewModel: SegmentLibraryViewModel

    @Environment(\.modelContext) private var modelContext

    @State private var isHovering = false
    @State private var leftHeight: CGFloat = 180
    @State private var showDeleteConfirm = false

    // 行内编辑台词
    @State private var isEditingText = false
    @State private var draftText = ""
    @FocusState private var textEditorFocused: Bool

    // Equatable：SwiftUI 看到这俩相等就跳过 body 评估
    // viewModel 引用不参与比较（Bindable 让其变化通过 @State observation 触发，跟 Equatable 跳过逻辑互不冲突）
    static func == (lhs: SegmentCard, rhs: SegmentCard) -> Bool {
        lhs.segment.id == rhs.segment.id
            && lhs.isChecked == rhs.isChecked
            && lhs.isSelectionMode == rhs.isSelectionMode
            && lhs.isSelected == rhs.isSelected
            && lhs.sequenceNumber == rhs.sequenceNumber
            && lhs.segment.text == rhs.segment.text
            && lhs.segment.isVoiceLocked == rhs.segment.isVoiceLocked
            && lhs.segment.hasHardSubtitle == rhs.segment.hasHardSubtitle
            && lhs.segment.maskStyleRaw == rhs.segment.maskStyleRaw
            && lhs.segment.maskX == rhs.segment.maskX
            && lhs.segment.maskY == rhs.segment.maskY
            && lhs.segment.maskWidth == rhs.segment.maskWidth
            && lhs.segment.maskHeight == rhs.segment.maskHeight
            && lhs.segment.video?.status == rhs.segment.video?.status   // 自建分镜处理态变化需重绘占位卡
            && lhs.segment.thumbnailPath == rhs.segment.thumbnailPath   // 调开始边界后缩略图换路径需重绘
            // ⚠️ 字号必须参与比较：卡片里的字号滑条和「所见即所得」字幕预览都只依赖这一个字段，
            // 漏掉它的话 EquatableView 会判定"没变"而跳过重绘 —— 滑条动了，画面上的字幕纹丝不动。
            && lhs.segment.subtitleFontRatio == rhs.segment.subtitleFontRatio
    }

    var body: some View {
        fullCard
    }

    /// 完整卡片
    private var fullCard: some View {
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
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isChecked
                      ? Color.accentColor.opacity(0.10)
                      : isSelected
                        ? Color.accentColor.opacity(0.06)
                        : isHovering
                          ? Color(.controlBackgroundColor).opacity(0.8)
                          : Color(.controlBackgroundColor).opacity(0.5))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isChecked ? Color.accentColor :
                        isSelected ? Color.accentColor.opacity(0.5) : DesignTokens.Palette.border,
                        lineWidth: isChecked ? 2 : 1)
        )
        .overlay {
            // 自建分镜处理态占位：识别中 → 打标中（就绪/失败则不显示）
            if segment.video?.isUserUploaded == true,
               let st = segment.video?.status, st != .completed, st != .failed {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.black.opacity(0.38))
                    .overlay {
                        VStack(spacing: DesignTokens.Spacing.compact) {
                            ProgressView().controlSize(.small).tint(.white)
                            Text(st == .analyzing ? "打标中…" : "识别中…")
                                .font(DesignTokens.Typography.caption).foregroundStyle(.white)
                        }
                    }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(DesignTokens.Motion.hover) {
                isHovering = hovering
            }
        }
        // ⇧+点击 = 范围多选（Finder 同款）；普通点击 = 单个切换
        .onTapGesture {
            if isSelectionMode {
                if NSEvent.modifierFlags.contains(.shift) {
                    viewModel.extendSelection(to: segment)
                } else {
                    viewModel.toggleSelection(segment)
                }
            } else {
                // 非多选：点击选中分镜 → 打开右侧配音变体检视栏
                viewModel.selectedSegment = segment
            }
        }
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(segment.text, forType: .string)
                ToastCenter.shared.show("台词已复制", icon: "doc.on.doc.fill")
            } label: {
                Label("复制台词", systemImage: "doc.on.doc")
            }
            .disabled(segment.text.isEmpty)

            Button {
                draftText = segment.text
                isEditingText = true
                textEditorFocused = true
            } label: {
                Label("编辑台词", systemImage: "square.and.pencil")
            }

            Button {
                viewModel.shotEditRequestSegment = segment
            } label: {
                Label("分镜头替换", systemImage: "wand.and.stars")
            }

            Button {
                if segment.schemeSegments.isEmpty {
                    viewModel.splitRequestSegment = segment
                } else {
                    ToastCenter.shared.show("该分镜已被 \(segment.schemeSegments.count) 个方案组合使用，请先在方案里移除对它的使用，再来拆分",
                                            icon: "exclamationmark.triangle.fill", style: .warning, duration: 3.5)
                }
            } label: {
                Label("拆分分镜", systemImage: "scissors")
            }

            if segment.replacedPictureVideoPath != nil {
                Button(role: .destructive) {
                    segment.replacedPictureVideoPath = nil
                    segment.replacedPictureThumbnailPath = nil
                    segment.replacedPictureFrameCount = 0
                    segment.pictureShowsReplaced = false
                    try? modelContext.save()   // 旧文件留给孤儿 GC 回收
                } label: {
                    Label("删除替换画面", systemImage: "photo.badge.arrow.down")
                }
            }

            if let videoPath = segment.video?.localPath, !videoPath.isEmpty {
                Button {
                    let url = URL(fileURLWithPath: videoPath)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("在 Finder 中显示原视频", systemImage: "folder")
                }
            }

            if isSelectionMode {
                Button {
                    viewModel.toggleSelection(segment)
                } label: {
                    Label(isChecked ? "取消选中" : "选中",
                          systemImage: isChecked ? "checkmark.square" : "square")
                }
            }

            Divider()

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("删除分镜", systemImage: "trash")
            }
        }
        .alert("确认删除", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                // Toast（含「撤销」按钮）由 deleteSegment 内部弹出
                viewModel.deleteSegment(segment)
            }
        } message: {
            Text("将删除这个分镜。删除后 5 秒内可点「撤销」找回。")
        }
    }

    // MARK: - 左侧面板
    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 播放器 + 左上角 #编号 + 多选 checkbox 叠加
            // SegmentInlinePlayer 不再内部约束 aspect ratio，由调用方给死 9:16 (CLAUDE.md)
            SegmentInlinePlayer(segment: segment, viewModel: viewModel)
                .frame(width: 200, height: 200.0 * 16.0 / 9.0)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: DesignTokens.Spacing.tight) {
                        if isSelectionMode {
                            Image(systemName: isChecked
                                ? "checkmark.square.fill" : "square")
                                .font(DesignTokens.Typography.title)
                                .foregroundStyle(isChecked ? Color.accentColor : .white)
                                .shadow(color: .black.opacity(0.5), radius: 1)
                        }
                        if sequenceNumber > 0 {
                            Text("#\(sequenceNumber)")
                                .font(DesignTokens.Typography.microMetric)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.6))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(6)
                }
                .overlay(alignment: .bottomTrailing) {
                    // 就地替换画面：切换按钮（仅当存在替换画面时显示）原画面 ↔ 替换画面
                    if segment.replacedPictureVideoPath != nil {
                        Button {
                            segment.pictureShowsReplaced.toggle()
                            try? modelContext.save()
                        } label: {
                            HStack(spacing: 3) {
                                // ⚠️ 原来用 arrow.triangle.2.circlepath（HIG 里是"刷新/重试"语义），
                                // 与全 App 的重试按钮撞车。这里是"原画面 ↔ 替换画面"的二选一切换，
                                // 用交换语义的图标才不会误导。
                                Image(systemName: "rectangle.2.swap")
                                Text(segment.pictureShowsReplaced ? "替换画面" : "原画面")
                            }
                            .font(DesignTokens.Typography.microEmphasis)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Capsule().fill(segment.pictureShowsReplaced
                                ? Color.green.opacity(0.75) : Color.black.opacity(0.6)))
                        }
                        .buttonStyle(.plain)
                        .padding(6)
                        .help("在原画面与 AI 替换画面之间切换")
                    }
                }
                .overlay {
                    if segment.hasHardSubtitle {
                        SubtitleMaskOverlay(
                            rect: Binding(
                                get: { segment.maskRect },
                                set: { segment.maskRect = $0 }      // 仅写内存，拖拽期间不保存
                            ),
                            onCommit: { try? modelContext.save() }   // 松手才保存一次
                        )
                    }
                }
                // 字幕字号所见即所得：示例字幕按全局比例叠在真实画面上，居中于遮挡区、
                // 跟随遮挡框移动，可与原字幕比大小与位置
                .overlay {
                    if !segment.isVoiceLocked {
                        SubtitleSizePreviewOverlay(
                            fontRatio: segment.subtitleFontRatio,
                            frameWidth: 200,
                            frameHeight: 200.0 * 16.0 / 9.0,
                            maskRect: segment.maskRect)
                    }
                }

            // 标签行：语义类型 + 位置
            FlowLayout(spacing: 3) {
                ForEach(segment.semanticTypes, id: \.self) { type in
                    SemanticTypeTag(type: type)
                }
                PositionTypeTag(type: segment.positionType)
                QualityBadge(score: segment.qualityScore)
            }

            // 配音控件：保留原声 + 硬字幕遮挡开关
            SegmentDubControls(
                isVoiceLocked: Binding(
                    get: { segment.isVoiceLocked },
                    set: { segment.isVoiceLocked = $0; try? modelContext.save() }
                ),
                treatment: Binding(
                    get: { SubtitleTreatment.from(hasHardSubtitle: segment.hasHardSubtitle, maskStyle: segment.maskStyle) },
                    set: { newVal in
                        segment.hasHardSubtitle = newVal.needsMask
                        if let style = newVal.maskStyle { segment.maskStyle = style }
                        try? modelContext.save()
                    }
                ),
                onApplyMaskToAll: { applyMaskToAllSegments(of: segment) },
                fontRatio: Binding(
                    get: { segment.subtitleFontRatio },
                    set: {
                        let v = SubtitleFontSize.clamp($0)
                        segment.subtitleFontRatio = v
                        // 记住这次的设定，作为之后新建分镜的默认值（老素材/新素材不再割裂）
                        SubtitleFontSize.rememberPreferred(v)
                        modelContext.safeSave()
                    }
                ),
                onApplyFontSizeToAll: { applyFontSizeToAllSegments(of: segment) }
            )

            // 边界微调 —— hover 或选中时才显示（性能优化：含多 TextField+@FocusState，
            // 默认全部展示会让 50 个分镜卡片同步实例化 100+ 个交互控件）
            if isHovering || isSelected {
                BoundaryAdjustRow(segment: segment, viewModel: viewModel)
                    .transition(.opacity)
            } else {
                // 占位：保持卡片高度稳定
                Rectangle()
                    .fill(.clear)
                    .frame(height: 24)
            }
        }
        .padding(8)
    }

    // MARK: - 右侧台词面板
    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.tight) {
                Image(systemName: "text.quote")
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.secondary)
                Text("台词")
                    .font(DesignTokens.Typography.microEmphasis)
                    .foregroundStyle(.secondary)
                Text("\(segment.text.count)字")
                    .font(DesignTokens.Typography.microMono)
                    .foregroundStyle(.tertiary)
                Spacer()
                if isEditingText {
                    Button { isEditingText = false } label: {
                        Image(systemName: "xmark.circle.fill").font(DesignTokens.Typography.label)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("取消编辑").help("取消")
                    Button { saveText() } label: {
                        Image(systemName: "checkmark.circle.fill").font(DesignTokens.Typography.label)
                    }
                    .buttonStyle(.plain).foregroundStyle(.green).accessibilityLabel("保存台词").help("保存（⌘↩）")
                } else if isHovering || isSelected {
                    Button {
                        draftText = segment.text
                        isEditingText = true
                        textEditorFocused = true
                    } label: {
                        Image(systemName: "square.and.pencil").font(DesignTokens.Typography.caption)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("编辑台词").help("编辑台词")
                    Button {
                        Task { await viewModel.reextractTranscript(segment, context: modelContext) }
                    } label: {
                        if viewModel.busyASRSegmentIDs.contains(segment.id) {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise").font(DesignTokens.Typography.caption)
                        }
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("重新识别台词")
                    .disabled(viewModel.busyASRSegmentIDs.contains(segment.id))
                    .help("用阿里云 ASR 重新识别这一分镜的台词（替换原台词，whisper 不变）")
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if isEditingText {
                TextEditor(text: $draftText)
                    .font(DesignTokens.Typography.caption)
                    .lineSpacing(3)
                    .focused($textEditorFocused)
                    .scrollContentBackground(.hidden)
                    .background(Color(.textBackgroundColor).opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                    )
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                    // ⌘↩ 保存
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.command) { saveText(); return .handled }
                        return .ignored
                    }
            } else if segment.text.isEmpty {
                VStack(spacing: DesignTokens.Spacing.tight) {
                    Image(systemName: "waveform.slash")
                        .font(DesignTokens.Typography.bodyLarge)
                        .foregroundStyle(.tertiary)
                    Text("暂无台词")
                        .font(DesignTokens.Typography.microRegular)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(segment.text)
                        .font(DesignTokens.Typography.caption)
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

    // MARK: - 台词编辑

    /// 保存行内编辑的台词（全局共享，写回 Segment.text）
    private func saveText() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != segment.text {
            segment.text = trimmed
            try? modelContext.save()
            ToastCenter.shared.show("台词已更新", icon: "checkmark.circle.fill")
        }
        isEditingText = false
        textEditorFocused = false
    }

    // MARK: - 遮挡应用

    /// 把当前分镜的字幕字号应用到**同一视频**的所有分镜（不跨视频）。
    /// 与「遮挡区应用到所有分镜」同一套模式：覆盖前存快照、完成后给可撤销的 Toast。
    private func applyFontSizeToAllSegments(of source: Segment) {
        guard let video = source.video else { return }
        let ratio = SubtitleFontSize.clamp(source.subtitleFontRatio)
        let targets = video.segments.filter { $0.id != source.id }
        guard !targets.isEmpty else {
            ToastCenter.shared.show("这个视频只有一个分镜，无需应用", icon: "info.circle.fill", style: .info)
            return
        }
        let snapshot: [(seg: Segment, ratio: Double)] = targets.map { ($0, $0.subtitleFontRatio) }
        for seg in targets { seg.subtitleFontRatio = ratio }
        modelContext.safeSave()

        ToastCenter.shared.show(
            "已把字幕字号应用到本视频 \(targets.count) 个分镜",
            icon: "textformat.size", style: .success, duration: 5,
            actionTitle: "撤销"
        ) {
            // 宽限期内分镜可能已被删除，写已删对象会崩溃 → 逐项守卫
            var restored = 0
            for item in snapshot where item.seg.modelContext != nil {
                item.seg.subtitleFontRatio = item.ratio
                restored += 1
            }
            modelContext.safeSave()
            ToastCenter.shared.show(restored == snapshot.count
                                    ? "已还原字幕字号"
                                    : "已还原 \(restored) 个分镜的字幕字号（其余已被删除）",
                                    icon: "arrow.uturn.backward", style: .info)
        }
    }

    /// 把当前分镜的遮挡设置应用到同一视频的所有分镜。
    ///
    /// 这是个**批量覆盖**操作：会盖掉其他分镜可能已经逐个微调好的遮挡框。
    /// 以前点完界面毫无变化（当前卡片本来就是这个值），用户根本不知道有没有生效，
    /// 也没有后悔药。现在：① 覆盖前先存快照；② 完成后 Toast 说明影响范围；③ 提供撤销。
    private func applyMaskToAllSegments(of source: Segment) {
        guard let video = source.video else { return }
        let rect = source.maskRect
        let style = source.maskStyle
        let hasSub = source.hasHardSubtitle

        let targets = video.segments.filter { $0.id != source.id }
        guard !targets.isEmpty else {
            ToastCenter.shared.show("这个视频只有一个分镜，无需应用", icon: "info.circle.fill", style: .info)
            return
        }

        // 快照旧值，供撤销还原
        let snapshot: [(seg: Segment, hasSub: Bool, rect: SubtitleMaskRect, style: MaskStyle)] =
            targets.map { ($0, $0.hasHardSubtitle, $0.maskRect, $0.maskStyle) }

        for seg in targets {
            seg.hasHardSubtitle = hasSub
            seg.maskRect = rect
            seg.maskStyle = style
        }
        try? modelContext.save()

        ToastCenter.shared.show(
            "已把遮挡设置应用到 \(targets.count) 个分镜",
            icon: "square.on.square", style: .success, duration: 5,
            actionTitle: "撤销"
        ) {
            // ⚠️ 撤销闭包最长在 5 秒后才执行，这期间用户完全可能删掉其中某个分镜
            // （删除走 PendingDeletionCenter，宽限期到点后台自动真删）。
            // 对已被 delete 的 SwiftData 对象写属性会直接崩溃（见 CLAUDE.md 删对象崩溃记录），
            // 所以逐项检查对象是否仍在上下文里，失效的跳过。
            var restored = 0
            for item in snapshot where item.seg.modelContext != nil {
                item.seg.hasHardSubtitle = item.hasSub
                item.seg.maskRect = item.rect
                item.seg.maskStyle = item.style
                restored += 1
            }
            try? modelContext.save()
            ToastCenter.shared.show(restored == snapshot.count
                                    ? "已还原遮挡设置"
                                    : "已还原 \(restored) 个分镜的遮挡设置（其余已被删除）",
                                    icon: "arrow.uturn.backward", style: .info)
        }
    }
}

// MARK: - 字幕字号所见即所得预览

/// 叠在分镜真实画面上的示例字幕，字号 = 画面显示宽 × 全局比例（与导出换算一致，见
/// SubtitleFontSize）；居中落在遮挡区（maskRect）正中并跟随遮挡框移动，与导出落位一致
/// （见 CaptionLayout.overlayOrigin）。拖字号滑条/拖遮挡框时实时变化。仅预览，不参与交互。
private struct SubtitleSizePreviewOverlay: View {
    /// 用**该分镜自己的**字号（不是全局设置），拖动弹层滑条时这里实时跟随
    let fontRatio: Double
    /// 画面在屏上的显示尺寸（此处播放器固定 200 × 200*16/9）
    let frameWidth: CGFloat
    let frameHeight: CGFloat
    let maskRect: SubtitleMaskRect

    var body: some View {
        let fontPt = frameWidth * SubtitleFontSize.clamp(fontRatio)
        let rect = maskRect.clamped()
        let cx = CGFloat(rect.x + rect.width / 2) * frameWidth
        let cy = CGFloat(rect.y + rect.height / 2) * frameHeight
        Text("这里是字幕")
            .font(.custom("PingFangSC-Semibold", size: fontPt))
            .foregroundStyle(.white)
            .padding(.horizontal, fontPt * 0.35)
            .padding(.vertical, fontPt * 0.18)
            .background(Color.black.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: fontPt * 0.25))
            .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
            .position(x: cx, y: cy)   // 落在遮挡区正中
            .allowsHitTesting(false)
    }
}

// MARK: - 缩略图缓存（避免 View body 中反复磁盘 IO）

// ThumbnailCache 已移到 Views/Shared/ThumbnailCache.swift，全局共享

// MARK: - 分镜原地播放器（hover 播放，全局唯一播放，原始比例）

struct SegmentInlinePlayer: View {
    let segment: Segment
    @Bindable var viewModel: SegmentLibraryViewModel
    /// 可选：选中配音变体的音频路径。非 nil 时播放静音视频原声、同步播此变体音轨（方案预览用）。
    var dubAudioPath: String? = nil

    @State private var player: AVPlayer?
    @State private var dubPlayer: AVAudioPlayer?
    @State private var bgmPlayer: AVAudioPlayer?   // 变体预览时叠加的分离背景音乐
    @State private var isPlaying = false
    @State private var isFrozen = false        // 播放到结尾后定格在最后一帧（非 nil player，但已暂停）
    @State private var timeObserver: Any?
    @State private var endNotifObserver: NSObjectProtocol?  // 到达 forwardPlaybackEndTime / 视频自然播完 → 定格
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

    /// 显示用宽高比：固定为手机端 9:16 竖屏（信息流广告投放比例，见 CLAUDE.md）
    /// 视频原始比例不是 9:16 也会被 fit 到 9:16 容器内（contentMode: .fit 留黑边）
    private var displayAspectRatio: CGFloat {
        return 9.0 / 16.0
    }

    private var segmentDuration: Double {
        segment.endTime - segment.startTime
    }

    var body: some View {
        // 性能关键：默认只渲染缩略图 + 时长（最轻量），hover/播放才组装完整 ZStack
        Group {
            if !isHovering && !isPlaying && !isFrozen {
                // 静态轻量态：只有缩略图 + 时长角标
                thumbnailView
                    .overlay(alignment: .bottomTrailing) {
                        Text(String(format: "%.1fs", segmentDuration))
                            .font(DesignTokens.Typography.microMonoStrong)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.55))
                            .clipShape(Capsule())
                            .padding(5)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                // hover 或播放态：完整 player UI
                playerUI
            }
        }
        // hover 统一挂在外层 Group(稳定容器)：静态↔playerUI 子视图切换时不会丢/错乱 hover 事件，
        // 这是"播放中移到另一分镜会卡住"的根因修复。
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
                if isPlaying || isFrozen { stopPlayback() }
                // 仅当全局仍是"我"在播才清空——避免离开本分镜时误杀刚移入的下一个分镜。
                if viewModel.playingSegmentID == segment.id { viewModel.stopCurrentPlayback() }
            }
        }
        // ⚠️ 播放请求监听必须挂在 body 顶层（而非 playerUI 内）：空闲态只渲染缩略图时
        // 也要能响应微调（adjustStartTime/adjustEndTime）触发的 requestPlay，否则点加减不播放。
        // play() 会把 isPlaying 置 true，body 随即切到 playerUI。
        .onChange(of: viewModel.playingSegmentID) { _, newID in
            if newID != segment.id && (isPlaying || isFrozen) {
                stopPlayback()
            }
        }
        .onChange(of: viewModel.previewRequest) { _, newRequest in
            guard let request = newRequest,
                  request.segmentID == segment.id else { return }
            play(from: request.from, to: request.to)
            viewModel.previewRequest = nil
        }
    }

    @ViewBuilder
    private var playerUI: some View {
        ZStack {
            if (isPlaying || isFrozen), let player {
                PlayerRepresentable(player: player)
                    .aspectRatio(videoAspectRatio, contentMode: .fit)   // F11/F12: 横屏视频在 9:16 容器内留黑边，不裁切
            } else {
                thumbnailView
            }

            if isHovering && !isPlaying && !isFrozen {
                Color.black.opacity(0.15)
                Image(systemName: "play.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.3), radius: 4)
            }

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)   // 横屏视频 fit 进 9:16 的留边填黑，避免透出卡片底色的「透明边」
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        // 注意：hover 已统一挂在 body 外层 Group，playerUI 内不再重复挂 onHover（会与子视图切换打架）。
        .onDisappear {
            hoverTimer?.invalidate()
            stopPlayback()
        }
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        guard segmentDuration > 0 else { return 0 }
        // 进度基准：替换版从 0 起（整段独立片），原版从源 startTime 起。
        let elapsed = currentTime - segment.effectivePicture.startTime
        return totalWidth * max(0, min(1, elapsed / segmentDuration))
    }

    @ViewBuilder
    private var thumbnailView: some View {
        Group {
            if let thumbPath = segment.effectivePicture.thumbnailPath,
               let image = ThumbnailCache.shared.image(for: thumbPath) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)   // F11/F12: 横屏视频在 9:16 容器内留黑边，不裁切
            } else {
                Rectangle()
                    .fill(Color(.windowBackgroundColor).opacity(0.3))
                    .overlay {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 20))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)   // 横屏视频 fit 进 9:16 的留边填黑（否则透出卡片半透明底=「透明边」）
        .clipped()
    }

    private func play(from requestedStart: Double, to requestedEnd: Double) {
        stopPlayback()

        // 当前生效画面：替换版是整段独立片(0..duration)，忽略传入的源时间轴区间；原版用传入区间。
        let ep = segment.effectivePicture
        let startTime = ep.isReplaced ? ep.startTime : requestedStart
        let endTime = ep.isReplaced ? ep.endTime : requestedEnd
        let videoPath = ep.videoPath
        guard !videoPath.isEmpty, FileManager.default.fileExists(atPath: videoPath) else { return }

        let item = AVPlayerItem(url: URL(fileURLWithPath: videoPath))

        // 半帧偏移：零容差 seek 会落到「pts ≤ 目标时间」的那一帧。若分镜起点 startTime
        // 比目标帧真实 pts 早哪怕几微秒（编码后帧 pts 常为非整值），就会掉到前一帧，
        // 开头多出上个镜头的尾帧。把目标时间挪到帧正中央 (startTime + 0.5/fps) 即可稳定命中目标帧。
        let fps = ep.fps
        let halfFrame = fps > 0 ? 0.5 / fps : 0.01

        // 关键：让播放器在「本段最后一帧」处物理停住，绝不越过 endTime 冲进下一个镜头。
        // 这样就不需要「越界后 pause+seek 回退」——那个回退正是肉眼看到的「往后闪一下又回来」。
        // endTime 是下一段起点(exclusive)，本段最后一帧落在 endTime 前半帧。
        item.forwardPlaybackEndTime = CMTime(seconds: max(0, endTime - halfFrame), preferredTimescale: 600)

        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.actionAtItemEnd = .pause   // 到结尾停住，不回到开头、不循环
        self.player = avPlayer
        isPlaying = true
        isFrozen = false

        // 方案预览：有选中变体音频时静音视频原声（含原人声），改放「克隆人声 + 分离BGM」
        if let dubPath = dubAudioPath, FileManager.default.fileExists(atPath: dubPath) {
            avPlayer.isMuted = true
            do {
                let ap = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: dubPath))
                ap.prepareToPlay()
                dubPlayer = ap
            } catch {
                dubPlayer = nil
            }
            // 背景音乐：用 demucs 分离出的 bgm.wav（已去人声、保持原响度），按原时间轴定位到本段起点，
            // 与画面同步播放，使变体配音不再「干声无背景」。无分离文件则跳过（仅放克隆人声）。
            if let hash = segment.video?.contentHash {
                let bgmURL = FileHelper.stemsDirectory(videoHash: hash).appendingPathComponent("bgm.wav")
                if FileManager.default.fileExists(atPath: bgmURL.path) {
                    do {
                        let bp = try AVAudioPlayer(contentsOf: bgmURL)
                        bp.currentTime = max(0, startTime)   // BGM 与画面同走原时间轴
                        bp.prepareToPlay()
                        bgmPlayer = bp
                    } catch {
                        bgmPlayer = nil
                    }
                }
            }
        }

        let startCMTime = CMTime(seconds: startTime + halfFrame, preferredTimescale: 600)
        avPlayer.seek(to: startCMTime, toleranceBefore: .zero, toleranceAfter: .zero)

        // 进度更新（periodic，仅刷新进度条，不做结束判断）
        // 频率从 20Hz 降到 4Hz：currentTime 是 @State，每次变更都会重评估含 GeometryReader 的播放器 UI；
        // 一条几像素宽的进度条 4Hz 肉眼已经连续，20Hz 纯属浪费。
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [self] time in
            currentTime = CMTimeGetSeconds(time)
        }

        // 到达 forwardPlaybackEndTime（本段结尾）或视频自然播完，都会发这个通知 → 统一定格。
        // 不再用 boundary 观察者：boundary 是「越过后」才触发，必然先冲过头。
        endNotifObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in freezeAtLastFrame(endTime: endTime) }
        }

        avPlayer.play()
        dubPlayer?.play()
        bgmPlayer?.play()
    }

    /// 播放到分镜结尾：暂停并定格在分镜最后一帧（endTime 前半帧），不回缩略图。
    /// 便于肉眼确认最后一帧是否已串入下一个镜头（验证 endTime 边界是否切晚了）。
    private func freezeAtLastFrame(endTime: Double) {
        guard !isFrozen else { return }   // 防重入：forwardPlaybackEndTime 到点与自然播完通知可能都触发
        // 移除所有观察者，防止重复/继续触发
        if let observer = timeObserver, let p = player { p.removeTimeObserver(observer) }
        timeObserver = nil
        if let no = endNotifObserver { NotificationCenter.default.removeObserver(no) }
        endNotifObserver = nil
        dubPlayer?.stop()
        dubPlayer = nil
        bgmPlayer?.stop()
        bgmPlayer = nil
        guard let p = player else { return }
        p.pause()
        // endTime 是下一段起点(exclusive)，本段最后一帧落在 endTime 前半帧
        let fps = segment.video?.fps ?? 0
        let halfFrame = fps > 0 ? 0.5 / fps : 0.01
        let lastFrame = CMTime(seconds: max(0, endTime - halfFrame), preferredTimescale: 600)
        p.seek(to: lastFrame, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = endTime
        isPlaying = false
        isFrozen = true
        // 关键：不调 viewModel.stopCurrentPlayback()。那会把 playingSegmentID 置 nil，
        // 反过来触发本视图 onChange(playingSegmentID) → stopPlayback() 把定格画面清掉回封面。
        // 保留 playingSegmentID = 本段，定格留存；hover 到别的分镜时才会被清理。
    }

    private func stopPlayback() {
        if let observer = timeObserver, let p = player {
            p.removeTimeObserver(observer)
        }
        timeObserver = nil
        if let no = endNotifObserver { NotificationCenter.default.removeObserver(no) }
        endNotifObserver = nil
        dubPlayer?.stop()
        dubPlayer = nil
        bgmPlayer?.stop()
        bgmPlayer = nil
        player?.pause()
        player = nil
        isPlaying = false
        isFrozen = false
        currentTime = 0
    }
}

// MARK: - 分镜行（列表模式）

/// 同 SegmentCard：Equatable + props 隔离选中状态
struct SegmentRow: View, Equatable {
    let segment: Segment
    let isChecked: Bool
    let isSelectionMode: Bool
    let isSelected: Bool
    let sequenceNumber: Int
    @Bindable var viewModel: SegmentLibraryViewModel
    @State private var isHovering = false

    static func == (lhs: SegmentRow, rhs: SegmentRow) -> Bool {
        lhs.segment.id == rhs.segment.id
            && lhs.isChecked == rhs.isChecked
            && lhs.isSelectionMode == rhs.isSelectionMode
            && lhs.isSelected == rhs.isSelected
            && lhs.sequenceNumber == rhs.sequenceNumber
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.normal) {
            // 多选 checkbox（只在多选模式下显示）
            if isSelectionMode {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .font(DesignTokens.Typography.title)
                    .foregroundStyle(isChecked ? Color.accentColor : .secondary)
                    .frame(width: 20)
            }

            SegmentInlinePlayer(segment: segment, viewModel: viewModel)
                .frame(width: 160)
                .overlay(alignment: .topLeading) {
                    if sequenceNumber > 0 {
                        Text("#\(sequenceNumber)")
                            .font(DesignTokens.Typography.microMetric)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Capsule())
                            .padding(6)
                    }
                }

            VStack(alignment: .leading, spacing: 6) {
                // 标签行
                HStack(spacing: DesignTokens.Spacing.tight) {
                    ForEach(segment.semanticTypes.prefix(3), id: \.self) { type in
                        SemanticTypeTag(type: type)
                    }
                    PositionTypeTag(type: segment.positionType)
                    Spacer()
                    QualityBadge(score: segment.qualityScore)
                }

                Text(segment.text)
                    .font(DesignTokens.Typography.caption)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)

                // 边界微调 hover/选中才显示
                if isHovering || isSelected {
                    BoundaryAdjustRow(segment: segment, viewModel: viewModel)
                        .transition(.opacity)
                }
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isChecked
                      ? Color.accentColor.opacity(0.10)
                      : isSelected
                        ? Color.accentColor.opacity(0.06)
                        : isHovering
                          ? Color(.controlBackgroundColor).opacity(0.8)
                          : Color(.controlBackgroundColor).opacity(0.5))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isChecked ? Color.accentColor : isSelected ? Color.accentColor.opacity(0.5) : DesignTokens.Palette.border,
                        lineWidth: isChecked ? 2 : 1)
        )
        .onHover { hovering in
            withAnimation(DesignTokens.Motion.hover) {
                isHovering = hovering
            }
        }
        // ⇧+点击 = 范围多选（Finder 同款）；普通点击 = 单个切换
        .onTapGesture {
            if isSelectionMode {
                if NSEvent.modifierFlags.contains(.shift) {
                    viewModel.extendSelection(to: segment)
                } else {
                    viewModel.toggleSelection(segment)
                }
            } else {
                viewModel.selectedSegment = segment
            }
        }
    }
}

// MARK: - 质量分徽章

struct QualityBadge: View {
    let score: Double

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "star.fill")
                .font(DesignTokens.Typography.microRegular)
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
            .font(DesignTokens.Typography.micro)
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
            .font(DesignTokens.Typography.micro)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.secondary.opacity(DesignTokens.Palette.Alpha.subtle))
            .clipShape(Capsule())
    }
}

// MARK: - 筛选芯片

struct FilterChip: View {
    let label: String
    let color: Color
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    private var isEmpty: Bool { count == 0 }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.tight) {
                Text(label)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? color : color.opacity(0.7))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(color.opacity(isSelected ? 0.20 : 0.12))
                    )
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(isSelected ? 0.15 : 0.06))
            .foregroundStyle(isSelected ? color : color.opacity(0.85))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(color.opacity(isSelected ? 0.4 : 0.15), lineWidth: 1)
            )
            .opacity(isEmpty ? 0.35 : 1.0)
            .saturation(isEmpty ? 0.4 : 1.0)
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

    @State private var startText: String = ""
    @State private var endText: String = ""
    @FocusState private var focusedField: TimeField?

    private var fps: Double { segment.video?.fps ?? 30 }
    private func timecode(_ frame: Int) -> String { FrameTime.timecode(frame: frame, fps: fps) }

    var body: some View {
        HStack(spacing: 6) {
            // IN 时间组
            HStack(spacing: 1) {
                adjustButton(systemName: "minus", accessibilityLabel: "入点提前") {
                    viewModel.adjustStartFrame(for: segment, by: -1)
                }
                TextField("", text: $startText)
                    .font(DesignTokens.Typography.microMonoStrong)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(focusedField == .start ? .primary : .secondary)
                    .focused($focusedField, equals: .start)
                    .onSubmit { commitStart() }
                    .frame(width: 44, height: 16)
                    .background(focusedField == .start ? Color.accentColor.opacity(0.08) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                adjustButton(systemName: "plus", accessibilityLabel: "入点延后") {
                    viewModel.adjustStartFrame(for: segment, by: 1)
                }
            }

            // OUT 时间组
            HStack(spacing: 1) {
                adjustButton(systemName: "minus", accessibilityLabel: "出点提前") {
                    viewModel.adjustEndFrame(for: segment, by: -1)
                }
                TextField("", text: $endText)
                    .font(DesignTokens.Typography.microMonoStrong)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(focusedField == .end ? .primary : .secondary)
                    .focused($focusedField, equals: .end)
                    .onSubmit { commitEnd() }
                    .frame(width: 44, height: 16)
                    .background(focusedField == .end ? Color.accentColor.opacity(0.08) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                adjustButton(systemName: "plus", accessibilityLabel: "出点延后") {
                    viewModel.adjustEndFrame(for: segment, by: 1)
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
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, height: 18)
                    .background(.quaternary.opacity(DesignTokens.Palette.Alpha.strong))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("更多操作")
            .fixedSize()
        }
        .onChange(of: focusedField) { oldField, newField in
            // 进入编辑显示帧号（便于精确输入）；离开时提交并恢复时间码显示
            if newField == .start { startText = "\(segment.startFrame)" }
            if newField == .end { endText = "\(segment.endFrame)" }
            if oldField == .start { commitStart() }
            if oldField == .end { commitEnd() }
        }
        .onAppear {
            startText = timecode(segment.startFrame)
            endText = timecode(segment.endFrame)
        }
        .onChange(of: segment.startFrame) { _, newVal in
            if focusedField != .start { startText = timecode(newVal) }
        }
        .onChange(of: segment.endFrame) { _, newVal in
            if focusedField != .end { endText = timecode(newVal) }
        }
    }

    /// 提交开始帧（输入框输入的是帧号整数）
    private func commitStart() {
        guard let f = Int(startText.trimmingCharacters(in: .whitespaces)), f >= 0 else {
            startText = timecode(segment.startFrame)
            return
        }
        if f != segment.startFrame {
            viewModel.setStartFrame(for: segment, to: f)
        }
        startText = timecode(segment.startFrame)
    }

    /// 提交结束帧（输入框输入的是帧号整数）
    private func commitEnd() {
        guard let f = Int(endText.trimmingCharacters(in: .whitespaces)), f > 0 else {
            endText = timecode(segment.endFrame)
            return
        }
        if f != segment.endFrame {
            viewModel.setEndFrame(for: segment, to: f)
        }
        endText = timecode(segment.endFrame)
    }

    private func adjustButton(systemName: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                // ⚠️ 尺寸必须保持 14×14：这一行只在 hover 时出现，而卡片宽度由最宽的子视图决定。
                // 一旦把按钮放大（曾试过 18×18），这行会变宽 → 悬停瞬间把整张卡片撑宽 →
                // 网格重排 → 卡片左右跳动、画面移出播放框。字号 10pt 在 14×14 里留白足够，不必放大容器。
                .font(DesignTokens.Typography.microEmphasis)
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
                .background(.secondary.opacity(DesignTokens.Palette.Alpha.subtle))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: DesignTokens.Corner.style))
                // 让整个 14×14 方块（含透明区域）都可点，而不是只有图标笔画可点。
                // 不用放大 frame —— 放大会撑宽这一行进而撑宽整张卡片，悬停时造成网格跳动。
                .contentShape(Rectangle())
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(.secondary.opacity(0.1), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
