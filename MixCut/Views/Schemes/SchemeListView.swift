import SwiftUI

struct SchemeListView: View {
    let project: Project
    @Bindable var viewModel: SchemeViewModel
    @Bindable var segmentLibraryVM: SegmentLibraryViewModel
    @State private var showGenerateSheet = false
    @State private var targetVideoCount = 50
    @State private var customPrompt = ""
    /// 当前正在编辑的叙事结构（驱动编辑器 sheet）
    @State private var editingNarrativeStrategy: MixStrategy?

    var body: some View {
        HStack(spacing: 0) {
            // 左侧：策略 + 变体列表
            VStack(spacing: 0) {
                toolbar
                Divider()

                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }

                // 部分策略失败时列出「哪几个、为什么」。以前这些失败只进日志，
                // 用户只会发现方案变少了，无从判断是 AI 抽风还是自己的素材有问题。
                if !viewModel.failedStrategies.isEmpty {
                    failedStrategyList
                }

                if viewModel.strategies.isEmpty && viewModel.isGenerating {
                    generatingState
                } else if viewModel.strategies.isEmpty {
                    // 无任何策略：展示空态 + 顶层「自定义结构」入口（否则无法创建第一条结构）
                    ScrollView {
                        VStack(spacing: 0) {
                            emptyState
                                .frame(minHeight: 280)
                            Divider()
                            narrativeStructureGroup
                        }
                    }
                } else {
                    strategyList
                }
            }
            .frame(width: 320)

            Divider()

            // 右侧：方案详情
            if let selected = viewModel.selectedScheme {
                SchemeDetailView(scheme: selected, viewModel: viewModel, segmentLibraryVM: segmentLibraryVM)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: DesignTokens.Spacing.compact) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("选择一个变体查看详情")
                        .font(DesignTokens.Typography.label)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            viewModel.loadSchemes(for: project)
        }
        .onChange(of: project.id) {
            viewModel.loadSchemes(for: project)
        }
        .sheet(isPresented: $showGenerateSheet) {
            generateSheet
        }
        .sheet(item: $editingNarrativeStrategy) { strategy in
            NarrativeStructureEditorView(
                project: project,
                strategy: strategy,
                viewModel: viewModel
            )
        }
        // 其余四个主页面都设了 navigationTitle，唯独这里没有，窗口标题会退回成「MixCut」，
        // 切到本页时标题栏与其他页表现不一致。
        .navigationTitle("混剪方案")
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: DesignTokens.Spacing.compact) {
            Text("混剪方案")
                .font(DesignTokens.Typography.bodyEmphasis)

            if !viewModel.aiStrategies.isEmpty {
                // 视频数统计所有非容器策略（AI 策略 + 叙事结构模板）的 schemes 总数，避免漏算叙事结构变体
                let countedStrategies = viewModel.aiStrategies + viewModel.narrativeTemplates
                let totalSchemes = countedStrategies.flatMap(\.schemes).count
                Text("\(viewModel.aiStrategies.count) 策略 · \(totalSchemes) 视频")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(DesignTokens.Palette.Alpha.subtle))
                    .clipShape(Capsule())
            }

            Spacer()

            if viewModel.isGenerating {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.generationProgress)
                        .font(DesignTokens.Typography.microRegular)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Button {
                showGenerateSheet = true
            } label: {
                Label("生成", systemImage: "wand.and.stars")
                    .font(DesignTokens.Typography.label)
            }
            .controlSize(.small)
            .disabled(viewModel.isGenerating || project.segmentCount == 0)
        }
        .padding(.horizontal, DesignTokens.Padding.page)
        .padding(.vertical, 12)
        // 与分镜库一致：顶部固定栏用原生工具栏材质，滚动时透出模糊，形成层次
        .background(.bar)
    }

    // MARK: - 策略列表（两级）

    private var strategyList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.orderedStrategiesForDisplay) { strategy in
                    StrategySection(
                        strategy: strategy,
                        viewModel: viewModel,
                        isExpanded: viewModel.selectedStrategy?.id == strategy.id
                    )
                }

                narrativeStructureGroup
            }
        }
    }

    // MARK: - 自定义结构分组（三级：模块 → 各结构 → 变体）

    private var narrativeStructureGroup: some View {
        VStack(spacing: 0) {
            // 模块标题
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.indent")
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.purple)
                Text("自定义结构")
                    .font(DesignTokens.Typography.captionEmphasis)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            // 各结构（二级）+ 其变体（三级），复用 StrategySection
            ForEach(viewModel.narrativeTemplates) { strategy in
                StrategySection(
                    strategy: strategy,
                    viewModel: viewModel,
                    isExpanded: viewModel.selectedStrategy?.id == strategy.id,
                    onEdit: { editingNarrativeStrategy = strategy }
                )
            }

            // ＋ 添加结构
            Button {
                let strategy = viewModel.createNarrativeStructure(in: project)
                editingNarrativeStrategy = strategy
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus.circle.fill")
                        .font(DesignTokens.Typography.caption)
                    Text("添加结构")
                        .font(DesignTokens.Typography.captionStrong)
                }
                .foregroundStyle(.purple)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .disabled(project.segmentCount == 0)
        }
    }

    /// 未能生成的策略清单（名称 + 人话原因），可一键重试这些策略。
    private var failedStrategyList: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.compact) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesignTokens.Palette.Status.warning)
                Text("\(viewModel.failedStrategies.count) 个策略未能生成")
                    .font(DesignTokens.Typography.labelEmphasis)
                Spacer()
                Button {
                    viewModel.failedStrategies = []
                } label: {
                    Image(systemName: "xmark")
                        .font(DesignTokens.Typography.micro)
                }
                .buttonStyle(.plain)
                .help("忽略")
                .accessibilityLabel("忽略")
            }
            ForEach(viewModel.failedStrategies) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(DesignTokens.Typography.caption)
                        .lineLimit(1)
                    Text(item.reason)
                        .font(DesignTokens.Typography.micro)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("其余策略已正常生成。可点上方「生成」重试。")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(.tertiary)
        }
        .padding(DesignTokens.Spacing.normal)
        .background(DesignTokens.Palette.Status.warning.opacity(DesignTokens.Palette.Alpha.subtle))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.medium, style: DesignTokens.Corner.style))
        .padding(.horizontal, DesignTokens.Padding.page)
        .padding(.bottom, DesignTokens.Spacing.compact)
    }

    // MARK: - 错误提示

    private func errorBanner(_ error: String) -> some View {
        // 复用通用 InlineBanner（统一四态样式 + 更大的关闭点击区），消除各页自造错误条的样式漂移
        InlineBanner(style: .warning, message: error) {
            viewModel.errorMessage = nil
        }
        .padding(.horizontal, DesignTokens.Padding.page)
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.comfortable) {
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)

            VStack(spacing: 6) {
                Text("暂无混剪方案")
                    .font(.system(size: 14, weight: .medium))
                Text("点击「生成」让 AI 批量创建混剪方案")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(.secondary)
            }

            if project.segmentCount == 0 {
                HStack(spacing: DesignTokens.Spacing.tight) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(DesignTokens.Typography.microRegular)
                    Text("需要先导入视频并完成分析")
                        .font(DesignTokens.Typography.caption)
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.orange.opacity(0.08))
                .clipShape(Capsule())
            } else {
                HStack(spacing: DesignTokens.Spacing.tight) {
                    Image(systemName: "checkmark.circle")
                        .font(DesignTokens.Typography.microRegular)
                    Text("\(project.videoCount) 个视频, \(project.segmentCount) 个分镜可用")
                        .font(DesignTokens.Typography.caption)
                }
                .foregroundStyle(.blue)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.blue.opacity(0.08))
                .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 生成中状态

    private var generatingState: some View {
        VStack(spacing: DesignTokens.Spacing.comfortable) {
            ProgressView()
                .controlSize(.large)

            VStack(spacing: 6) {
                Text(viewModel.generationProgress)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("AI 正在生成差异化策略和排列组合...")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 生成设置弹窗

    private var generateSheet: some View {
        let allSegments = project.videos.flatMap(\.segments)
        let totalDuration = allSegments.reduce(0.0) { $0 + $1.duration }

        return VStack(spacing: DesignTokens.Spacing.generous) {
            VStack(spacing: DesignTokens.Spacing.tight) {
                Text("批量生成混剪方案")
                    .font(DesignTokens.Typography.title)
                Text("AI 将生成多个策略，每个策略自动排列组合出大量视频")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(.secondary)
            }

            // 素材概览
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.normal) {
                Text("素材概览")
                    .font(DesignTokens.Typography.captionEmphasis)
                    .foregroundStyle(.secondary)

                HStack(spacing: 0) {
                    statBlock(value: "\(project.videoCount)", label: "视频")
                    Divider().frame(height: 32)
                    statBlock(value: "\(allSegments.count)", label: "分镜")
                    Divider().frame(height: 32)
                    statBlock(value: String(format: "%.0fs", totalDuration), label: "总时长")
                }
            }
            .padding(DesignTokens.Spacing.comfortable)
            .background(.quaternary.opacity(DesignTokens.Palette.Alpha.medium))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            // 目标视频数
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.normal) {
                HStack {
                    Text("目标视频数量")
                        .font(DesignTokens.Typography.body)
                    Spacer()
                    Text("\(targetVideoCount)")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }

                Slider(value: Binding(
                    get: { Double(targetVideoCount) },
                    set: { targetVideoCount = Int($0) }
                ), in: 10...100, step: 10)

                // 预估说明
                let numStrategies = targetVideoCount <= 30 ? 3 : (targetVideoCount <= 80 ? 4 : 5)
                let perStrategy = Int(ceil(Double(targetVideoCount) / Double(numStrategies)))
                let estimatedCalls = numStrategies * Int(ceil(Double(perStrategy) / 8.0)) + 1
                // 按每次 AI 调用 ~8 秒估计总耗时
                let estimatedSeconds = estimatedCalls * 8
                let timeText: String = estimatedSeconds < 60
                    ? "约 \(estimatedSeconds) 秒"
                    : "约 \(estimatedSeconds / 60) 分钟"
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.tight) {
                    Text("预估：\(numStrategies) 个策略 × ~\(perStrategy) 个变体/策略")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.tertiary)
                    HStack(spacing: DesignTokens.Spacing.compact) {
                        Text("约 \(estimatedCalls) 次 AI 调用")
                        Text("·").foregroundStyle(.quaternary)
                        HStack(spacing: 3) {
                            Image(systemName: "clock")
                                .font(DesignTokens.Typography.microRegular)
                            Text("耗时 \(timeText)")
                        }
                    }
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 380)

            // 配音音色已无需选择：每个视频自动克隆原主播嗓音，所有配音变体统一用克隆原声。
            // 旧的「统一/混用音色」选择已移除（裁掉多音色裂变残留）。

            // 自定义需求（可选）
            VStack(alignment: .leading, spacing: 6) {
                Text("自定义需求（可选）")
                    .font(DesignTokens.Typography.body)
                TextField("如：偏重促销风格、时长控制在30秒内...", text: $customPrompt)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignTokens.Typography.label)
            }
            .frame(width: 380)

            // 按钮
            HStack(spacing: DesignTokens.Spacing.normal) {
                Button("取消") {
                    showGenerateSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    showGenerateSheet = false
                    let prompt = customPrompt.isEmpty ? nil : customPrompt
                    Task {
                        await viewModel.generateSchemes(
                            for: project,
                            targetVideoCount: targetVideoCount,
                            customPrompt: prompt
                        )
                    }
                } label: {
                    HStack(spacing: DesignTokens.Spacing.tight) {
                        Image(systemName: "wand.and.stars")
                            .font(DesignTokens.Typography.caption)
                        Text("开始生成")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(allSegments.isEmpty)
            }
        }
        .padding(28)
    }

    private func statBlock(value: String, label: String) -> some View {
        VStack(spacing: DesignTokens.Spacing.tight) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
            Text(label)
                .font(DesignTokens.Typography.microRegular)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 策略折叠区域

struct StrategySection: View {
    let strategy: MixStrategy
    @Bindable var viewModel: SchemeViewModel
    var isExpanded: Bool
    /// 叙事结构专用：点击"编辑"打开编辑器（非叙事结构传 nil 即不显示编辑入口）
    var onEdit: (() -> Void)? = nil

    @State private var strategyToDelete: MixStrategy?
    @State private var schemeToDelete: MixScheme?

    var body: some View {
        VStack(spacing: 0) {
            // 策略头部（可点击展开/折叠）
            Button {
                withAnimation(DesignTokens.Motion.hover) {
                    if isExpanded {
                        viewModel.selectedStrategy = nil
                    } else {
                        viewModel.selectedStrategy = strategy
                    }
                }
            } label: {
                HStack(spacing: DesignTokens.Spacing.compact) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(DesignTokens.Typography.microEmphasis)
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            if strategy.isCustomGroup {
                                Image(systemName: "sparkles")
                                    .font(DesignTokens.Typography.microRegular)
                                    .foregroundStyle(.purple)
                            } else if strategy.isNarrativeTemplate {
                                Image(systemName: "list.bullet.indent")
                                    .font(DesignTokens.Typography.microRegular)
                                    .foregroundStyle(.purple)
                            }
                            Text(strategy.name)
                                .font(DesignTokens.Typography.labelEmphasis)
                                .lineLimit(1)
                            Spacer()
                            Text("\(strategy.schemeCount) 个变体")
                                .font(DesignTokens.Typography.microRounded)
                                .foregroundStyle(.secondary)
                        }

                        if strategy.isNarrativeTemplate {
                            Text("自定义叙事结构")
                                .font(DesignTokens.Typography.microRegular)
                                .foregroundStyle(.tertiary)
                        } else if !strategy.isCustomGroup {
                            HStack(spacing: 6) {
                                HStack(spacing: 3) {
                                    Image(systemName: "paintpalette")
                                        .font(DesignTokens.Typography.microRegular)
                                    Text(strategy.style)
                                        .font(DesignTokens.Typography.microRegular)
                                }
                                .foregroundStyle(.secondary)

                                HStack(spacing: 3) {
                                    Image(systemName: "person.2")
                                        .font(DesignTokens.Typography.microRegular)
                                    Text(strategy.targetAudience)
                                        .font(DesignTokens.Typography.microRegular)
                                }
                                .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("手动挑选分镜组合的方案")
                                .font(DesignTokens.Typography.microRegular)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(isExpanded ? Color.accentColor.opacity(0.06) : .clear)
            }
            .buttonStyle(.plain)
            .contextMenu {
                if strategy.isNarrativeTemplate, let onEdit {
                    Button {
                        onEdit()
                    } label: {
                        Label("编辑结构", systemImage: "slider.horizontal.3")
                    }
                    Divider()
                }
                Button(strategy.isNarrativeTemplate ? "删除结构" : "删除策略", role: .destructive) {
                    strategyToDelete = strategy
                }
                .disabled(strategy.isCustomGroup)
            }

            // 展开后显示变体列表（LazyVStack 懒加载：屏幕外的变体行不同步实例化）
            if isExpanded {
                if strategy.isCustomGroup && strategy.schemes.isEmpty {
                    // 自定义组合空状态引导
                    customGroupEmptyState
                } else if strategy.isNarrativeTemplate && strategy.schemes.isEmpty {
                    // 叙事结构空状态引导：去编辑器配置段位并生成
                    narrativeEmptyState
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(strategy.orderedSchemes) { scheme in
                            schemeRow(scheme)
                        }
                    }
                }
            }

            Divider()
                .padding(.leading, 14)
        }
        // 删除策略/变体二次确认（与删视频/项目/批量删分镜的确认模式一致，防误删不可恢复）
        .confirmationDialog("删除该策略？", isPresented: Binding(
            get: { strategyToDelete != nil },
            set: { if !$0 { strategyToDelete = nil } }
        ), presenting: strategyToDelete) { s in
            Button("删除「\(s.name)」及其所有变体", role: .destructive) {
                viewModel.deleteStrategy(s)
                strategyToDelete = nil
            }
            Button("取消", role: .cancel) { strategyToDelete = nil }
        } message: { _ in
            Text("将删除该策略下的所有方案变体。删除后 5 秒内可点「撤销」找回。")
        }
        .confirmationDialog("删除该变体？", isPresented: Binding(
            get: { schemeToDelete != nil },
            set: { if !$0 { schemeToDelete = nil } }
        ), presenting: schemeToDelete) { s in
            Button("删除「\(s.name)」", role: .destructive) {
                viewModel.deleteScheme(s)
                schemeToDelete = nil
            }
            Button("取消", role: .cancel) { schemeToDelete = nil }
        } message: { _ in
            Text("该变体将被删除。删除后 5 秒内可点「撤销」找回。")
        }
    }

    /// 单条方案行。
    @ViewBuilder
    private func schemeRow(_ scheme: MixScheme) -> some View {
        SchemeVariationRow(
            scheme: scheme,
            isSelected: viewModel.selectedScheme?.id == scheme.id
        )
        .onTapGesture { viewModel.selectedScheme = scheme }
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(scheme.name, forType: .string)
                ToastCenter.shared.show("方案名已复制", icon: "doc.on.doc.fill")
            } label: {
                Label("复制方案名", systemImage: "doc.on.doc")
            }
            Divider()
            Button("删除变体", role: .destructive) {
                schemeToDelete = scheme
            }
        }
    }

    private var narrativeEmptyState: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.compact) {
            Text("还没有生成变体")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
            Button {
                onEdit?()
            } label: {
                HStack(spacing: DesignTokens.Spacing.tight) {
                    Image(systemName: "slider.horizontal.3")
                        .font(DesignTokens.Typography.caption)
                    Text("配置段位并生成方案")
                        .font(DesignTokens.Typography.captionStrong)
                }
                .foregroundStyle(.purple)
            }
            .buttonStyle(.plain)
            .disabled(onEdit == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .padding(.leading, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.04))
    }

    private var customGroupEmptyState: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.compact) {
            Text("还没有自定义组合")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
            Button {
                NotificationCenter.default.post(
                    name: .mixCutNavigate,
                    object: NavigationItem.segmentLibrary
                )
            } label: {
                HStack(spacing: DesignTokens.Spacing.tight) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(DesignTokens.Typography.caption)
                    Text("去分镜库挑几个分镜试试")
                        .font(DesignTokens.Typography.captionStrong)
                }
                .foregroundStyle(.purple)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .padding(.leading, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.04))
    }
}

// MARK: - 变体行

struct SchemeVariationRow: View {
    let scheme: MixScheme
    var isSelected: Bool = false
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.compact) {
            // 序号
            Text("#\(scheme.variationIndex)")
                .font(DesignTokens.Typography.microMetric)
                .foregroundStyle(.tertiary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DesignTokens.Spacing.tight) {
                    Text(scheme.name)
                        .font(DesignTokens.Typography.captionStrong)
                        .lineLimit(1)
                    if scheme.isManuallyEdited {
                        Text("·已修改")
                            .font(DesignTokens.Typography.microRegular)
                            .foregroundStyle(.tertiary)
                    }
                }

                HStack(spacing: DesignTokens.Spacing.tight) {
                    Text("\(scheme.segmentCount) 分镜")
                        .font(DesignTokens.Typography.microRegular)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.quaternary)
                    Text(String(format: "%.0fs", scheme.totalDuration))
                        .font(DesignTokens.Typography.microRounded)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.leading, 16)
        .padding(.vertical, 7)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.12)
                : (isHovering ? Color.secondary.opacity(0.04) : .clear)
        )
        .overlay(alignment: .leading) {
            // 选中状态左侧加蓝色 indicator bar
            if isSelected {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2.5)
            }
        }
        .onHover { hovering in
            withAnimation(DesignTokens.Motion.hover) {
                isHovering = hovering
            }
        }
    }
}
