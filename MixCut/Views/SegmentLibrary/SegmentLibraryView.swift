import SwiftUI
import AVKit

struct SegmentLibraryView: View {
    let project: Project
    @Bindable var viewModel: SegmentLibraryViewModel
    @Bindable var schemeVM: SchemeViewModel

    @State private var showBatchExportSheet = false
    @State private var showBatchDeleteConfirm = false
    @State private var showArrangeSheet = false
    @State private var isLoading = true

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
            let t0 = Date()
            isLoading = true
            // 退出多选模式 + 清空选中（避免不同项目的 ID 串到一起）
            viewModel.setSelectionMode(false)
            let thumbPaths = project.videos.compactMap(\.thumbnailPath)
            ThumbnailCache.shared.prewarm(paths: thumbPaths)
            viewModel.loadSegments(for: project)
            MixLog.info("[Perf] SegmentLibrary: \(Int(Date().timeIntervalSince(t0) * 1000))ms / segs=\(viewModel.segments.count)")
            isLoading = false
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            filterToolbar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            if viewModel.isSelectionMode {
                Divider()
                batchActionBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.06))
            }

            Divider()

            if viewModel.filteredSegments.isEmpty {
                emptyState
            } else {
                segmentContent
            }
        }
        .navigationTitle("分镜素材库")
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
                        withAnimation(.easeOut(duration: 0.15)) {
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
        HStack(spacing: 12) {
            Image(systemName: "checkmark.square.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
            let selectedDur = viewModel.selectedSegments.reduce(0.0) { $0 + $1.duration }
            Text("已选 \(viewModel.selectedSegmentIDs.count) 个 · \(String(format: "%.1fs", selectedDur))")
                .font(.system(size: 12, weight: .semibold))

            Divider().frame(height: 12)

            Button("全选") { viewModel.selectAllVisible() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)

            Button("反选") { viewModel.invertSelectionVisible() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)

            Button("清空选择") { viewModel.clearSelection() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .disabled(viewModel.selectedSegmentIDs.isEmpty)

            Spacer()

            Button {
                showBatchDeleteConfirm = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                    Text("批量删除")
                        .font(.system(size: 12, weight: .semibold))
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
                HStack(spacing: 4) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 11, weight: .semibold))
                    Text("组合为方案")
                        .font(.system(size: 12, weight: .semibold))
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
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                    Text("批量导出 \(viewModel.selectedSegmentIDs.count) 个")
                        .font(.system(size: 12, weight: .semibold))
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
                    showArrangeSheet = false
                    ToastCenter.shared.show("正在生成方案...", icon: "sparkles", style: .info)
                    let scheme = await schemeVM.createCustomScheme(from: ordered, in: project)
                    if scheme != nil {
                        ToastCenter.shared.show("自定义方案已生成", icon: "checkmark.circle.fill", style: .success)
                        viewModel.setSelectionMode(false)
                        // 通过通知跳转到方案板块
                        NotificationCenter.default.post(name: .mixCutNavigate, object: NavigationItem.schemes)
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
            Text("将删除 \(viewModel.selectedSegmentIDs.count) 个分镜，此操作不可恢复。")
        }
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

                // 多选开关
                Button {
                    viewModel.setSelectionMode(!viewModel.isSelectionMode)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: viewModel.isSelectionMode
                            ? "checkmark.square.fill" : "square.dashed")
                            .font(.system(size: 11, weight: .semibold))
                        Text(viewModel.isSelectionMode ? "退出多选" : "多选")
                            .font(.system(size: 12, weight: .medium))
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
                   let image = ThumbnailCache.shared.image(for: thumbPath) {
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
            // 性能关键：父视图在 ForEach 内一次性算 isChecked / sequenceNumber，
            // 传给 SegmentCard 作为 props。SegmentCard 实现 Equatable + .equatable() 后，
            // 选中变化只会重绘那一个卡片，其他卡片跳过 body 评估。
            let selectionMode = viewModel.isSelectionMode
            let selectedIDs = viewModel.selectedSegmentIDs    // 读一次本地变量
            let numberMap = viewModel.numberByVideo
            if viewModel.isGridView {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 360, maximum: 460))
                ], spacing: 12) {
                    ForEach(group.segments) { segment in
                        SegmentCard(
                            segment: segment,
                            isChecked: selectedIDs.contains(segment.id),
                            isSelectionMode: selectionMode,
                            sequenceNumber: (segment.video?.id).flatMap { numberMap[$0]?[segment.id] } ?? 0,
                            viewModel: viewModel
                        )
                        .equatable()
                    }
                }
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(group.segments) { segment in
                        SegmentRow(
                            segment: segment,
                            isChecked: selectedIDs.contains(segment.id),
                            isSelectionMode: selectionMode,
                            sequenceNumber: (segment.video?.id).flatMap { numberMap[$0]?[segment.id] } ?? 0,
                            viewModel: viewModel
                        )
                        .equatable()
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

/// SegmentCard 关键性能优化：
/// - 实现 Equatable，让 SwiftUI 在 reconcile 时跳过未变化的卡片 body 评估
/// - isChecked / isSelectionMode / sequenceNumber 通过 props 接收，**不直接访问 viewModel**
///   避免「访问 selectedSegmentIDs → 整个 Set 注册依赖 → 任意选中变化触发所有卡片重绘」的陷阱
/// - viewModel 仍然持有，用于 action（toggleSelection / deleteSegment / requestPlay）
struct SegmentCard: View, Equatable {
    let segment: Segment
    let isChecked: Bool
    let isSelectionMode: Bool
    let sequenceNumber: Int
    @Bindable var viewModel: SegmentLibraryViewModel

    @Environment(\.modelContext) private var modelContext

    @State private var isHovering = false
    @State private var leftHeight: CGFloat = 180
    @State private var showDeleteConfirm = false

    // Equatable：SwiftUI 看到这俩相等就跳过 body 评估
    // viewModel 引用不参与比较（Bindable 让其变化通过 @State observation 触发，跟 Equatable 跳过逻辑互不冲突）
    static func == (lhs: SegmentCard, rhs: SegmentCard) -> Bool {
        lhs.segment.id == rhs.segment.id
            && lhs.isChecked == rhs.isChecked
            && lhs.isSelectionMode == rhs.isSelectionMode
            && lhs.sequenceNumber == rhs.sequenceNumber
            && lhs.segment.isVoiceLocked == rhs.segment.isVoiceLocked
            && lhs.segment.hasHardSubtitle == rhs.segment.hasHardSubtitle
            && lhs.segment.maskStyleRaw == rhs.segment.maskStyleRaw
            && lhs.segment.maskX == rhs.segment.maskX
            && lhs.segment.maskY == rhs.segment.maskY
            && lhs.segment.maskWidth == rhs.segment.maskWidth
            && lhs.segment.maskHeight == rhs.segment.maskHeight
    }

    private var isSelected: Bool {
        viewModel.selectedSegment?.id == segment.id
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
            RoundedRectangle(cornerRadius: 10)
                .fill(isChecked
                      ? Color.accentColor.opacity(0.10)
                      : isSelected
                        ? Color.accentColor.opacity(0.06)
                        : isHovering
                          ? Color(.controlBackgroundColor).opacity(0.8)
                          : Color(.controlBackgroundColor).opacity(0.5))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isChecked ? Color.accentColor :
                        isSelected ? Color.accentColor.opacity(0.5) : .white.opacity(0.04),
                        lineWidth: isChecked ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .onTapGesture {
            if isSelectionMode {
                viewModel.toggleSelection(segment)
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
            Text("确定要删除这个分镜吗？此操作不可恢复。")
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
                    HStack(spacing: 4) {
                        if isSelectionMode {
                            Image(systemName: isChecked
                                ? "checkmark.square.fill" : "square")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(isChecked ? Color.accentColor : .white)
                                .shadow(color: .black.opacity(0.5), radius: 1)
                        }
                        if sequenceNumber > 0 {
                            Text("#\(sequenceNumber)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.6))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(6)
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
                hasHardSubtitle: Binding(
                    get: { segment.hasHardSubtitle },
                    set: { segment.hasHardSubtitle = $0; try? modelContext.save() }
                ),
                maskStyle: Binding(
                    get: { segment.maskStyle },
                    set: { segment.maskStyle = $0; try? modelContext.save() }
                ),
                onApplyMaskToAll: { applyMaskToAllSegments(of: segment) }
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

    // MARK: - 遮挡应用

    /// 把当前分镜的遮挡设置应用到同一视频的所有分镜
    private func applyMaskToAllSegments(of source: Segment) {
        guard let video = source.video else { return }
        let rect = source.maskRect
        let style = source.maskStyle
        let hasSub = source.hasHardSubtitle
        for seg in video.segments {
            seg.hasHardSubtitle = hasSub
            seg.maskRect = rect
            seg.maskStyle = style
        }
        try? modelContext.save()
    }
}

// MARK: - 缩略图缓存（避免 View body 中反复磁盘 IO）

// ThumbnailCache 已移到 Views/Shared/ThumbnailCache.swift，全局共享

// MARK: - 分镜原地播放器（hover 播放，全局唯一播放，原始比例）

struct SegmentInlinePlayer: View {
    let segment: Segment
    @Bindable var viewModel: SegmentLibraryViewModel

    @State private var player: AVPlayer?
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
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.55))
                            .clipShape(Capsule())
                            .padding(5)
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
                        }
                    }
            } else {
                // hover 或播放态：完整 player UI
                playerUI
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
        .clipped()
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
                if isPlaying || isFrozen {
                    stopPlayback()
                    viewModel.stopCurrentPlayback()
                }
            }
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
        Group {
            if let thumbPath = segment.thumbnailPath,
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
        .clipped()
    }

    private func play(from startTime: Double, to endTime: Double) {
        stopPlayback()

        guard let videoPath = segment.video?.localPath,
              FileManager.default.fileExists(atPath: videoPath) else { return }

        let item = AVPlayerItem(url: URL(fileURLWithPath: videoPath))

        // 半帧偏移：零容差 seek 会落到「pts ≤ 目标时间」的那一帧。若分镜起点 startTime
        // 比目标帧真实 pts 早哪怕几微秒（编码后帧 pts 常为非整值），就会掉到前一帧，
        // 开头多出上个镜头的尾帧。把目标时间挪到帧正中央 (startTime + 0.5/fps) 即可稳定命中目标帧。
        let fps = segment.video?.fps ?? 0
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

        let startCMTime = CMTime(seconds: startTime + halfFrame, preferredTimescale: 600)
        avPlayer.seek(to: startCMTime, toleranceBefore: .zero, toleranceAfter: .zero)

        // 进度更新（periodic，仅刷新进度条，不做结束判断）
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
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
    let sequenceNumber: Int
    @Bindable var viewModel: SegmentLibraryViewModel
    @State private var isHovering = false

    static func == (lhs: SegmentRow, rhs: SegmentRow) -> Bool {
        lhs.segment.id == rhs.segment.id
            && lhs.isChecked == rhs.isChecked
            && lhs.isSelectionMode == rhs.isSelectionMode
            && lhs.sequenceNumber == rhs.sequenceNumber
    }

    private var isSelected: Bool {
        viewModel.selectedSegment?.id == segment.id
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // 多选 checkbox（只在多选模式下显示）
            if isSelectionMode {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isChecked ? Color.accentColor : .secondary)
                    .frame(width: 20)
            }

            SegmentInlinePlayer(segment: segment, viewModel: viewModel)
                .frame(width: 160)
                .overlay(alignment: .topLeading) {
                    if sequenceNumber > 0 {
                        Text("#\(sequenceNumber)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
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

                // 边界微调 hover/选中才显示
                if isHovering || isSelected {
                    BoundaryAdjustRow(segment: segment, viewModel: viewModel)
                        .transition(.opacity)
                }
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(isChecked
                      ? Color.accentColor.opacity(0.10)
                      : isSelected
                        ? Color.accentColor.opacity(0.06)
                        : isHovering
                          ? Color(.controlBackgroundColor).opacity(0.8)
                          : Color(.controlBackgroundColor).opacity(0.5))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isChecked ? Color.accentColor : isSelected ? Color.accentColor.opacity(0.5) : .white.opacity(0.04),
                        lineWidth: isChecked ? 2 : 1)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .onTapGesture {
            if isSelectionMode {
                viewModel.toggleSelection(segment)
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
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    private var isEmpty: Bool { count == 0 }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
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
                adjustButton(systemName: "minus") {
                    viewModel.adjustStartFrame(for: segment, by: -1)
                }
                TextField("", text: $startText)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(focusedField == .start ? .primary : .secondary)
                    .focused($focusedField, equals: .start)
                    .onSubmit { commitStart() }
                    .frame(width: 44, height: 16)
                    .background(focusedField == .start ? Color.accentColor.opacity(0.08) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                adjustButton(systemName: "plus") {
                    viewModel.adjustStartFrame(for: segment, by: 1)
                }
            }

            // OUT 时间组
            HStack(spacing: 1) {
                adjustButton(systemName: "minus") {
                    viewModel.adjustEndFrame(for: segment, by: -1)
                }
                TextField("", text: $endText)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(focusedField == .end ? .primary : .secondary)
                    .focused($focusedField, equals: .end)
                    .onSubmit { commitEnd() }
                    .frame(width: 44, height: 16)
                    .background(focusedField == .end ? Color.accentColor.opacity(0.08) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                adjustButton(systemName: "plus") {
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
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, height: 18)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .menuStyle(.borderlessButton)
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

    private func adjustButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 7, weight: .heavy))
                .foregroundStyle(.tertiary)
                .frame(width: 14, height: 14)
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
