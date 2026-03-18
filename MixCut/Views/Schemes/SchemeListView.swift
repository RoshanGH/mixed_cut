import SwiftUI

struct SchemeListView: View {
    let project: Project
    @Bindable var viewModel: SchemeViewModel
    @Bindable var segmentLibraryVM: SegmentLibraryViewModel
    @State private var showGenerateSheet = false
    @State private var targetVideoCount = 50
    @State private var customPrompt = ""

    var body: some View {
        HStack(spacing: 0) {
            // 左侧：策略 + 变体列表
            VStack(spacing: 0) {
                toolbar
                Divider()

                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }

                if viewModel.strategies.isEmpty && !viewModel.isGenerating {
                    emptyState
                } else if viewModel.strategies.isEmpty && viewModel.isGenerating {
                    generatingState
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
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("选择一个变体查看详情")
                        .font(.system(size: 12))
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
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("混剪方案")
                .font(.system(size: 13, weight: .semibold))

            if !viewModel.strategies.isEmpty {
                let totalSchemes = viewModel.schemes.count
                Text("\(viewModel.strategies.count) 策略 · \(totalSchemes) 视频")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.08))
                    .clipShape(Capsule())
            }

            Spacer()

            if viewModel.isGenerating {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.generationProgress)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Button {
                showGenerateSheet = true
            } label: {
                Label("生成", systemImage: "wand.and.stars")
                    .font(.system(size: 12))
            }
            .controlSize(.small)
            .disabled(viewModel.isGenerating || project.segmentCount == 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 策略列表（两级）

    private var strategyList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.strategies) { strategy in
                    StrategySection(
                        strategy: strategy,
                        viewModel: viewModel,
                        isExpanded: viewModel.selectedStrategy?.id == strategy.id
                    )
                }
            }
        }
    }

    // MARK: - 错误提示

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .textSelection(.enabled)
            Spacer()
            Button {
                viewModel.errorMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.08))
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)

            VStack(spacing: 6) {
                Text("暂无混剪方案")
                    .font(.system(size: 14, weight: .medium))
                Text("点击「生成」让 AI 批量创建混剪方案")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if project.segmentCount == 0 {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                    Text("需要先导入视频并完成分析")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.orange.opacity(0.08))
                .clipShape(Capsule())
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 10))
                    Text("\(project.videoCount) 个视频, \(project.segmentCount) 个分镜可用")
                        .font(.system(size: 11))
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
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)

            VStack(spacing: 6) {
                Text(viewModel.generationProgress)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("AI 正在生成差异化策略和排列组合...")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 生成设置弹窗

    private var generateSheet: some View {
        let allSegments = project.videos.flatMap(\.segments)
        let totalDuration = allSegments.reduce(0.0) { $0 + $1.duration }

        return VStack(spacing: 24) {
            VStack(spacing: 4) {
                Text("批量生成混剪方案")
                    .font(.system(size: 16, weight: .semibold))
                Text("AI 将生成多个策略，每个策略自动排列组合出大量视频")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            // 素材概览
            VStack(alignment: .leading, spacing: 12) {
                Text("素材概览")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 0) {
                    statBlock(value: "\(project.videoCount)", label: "视频")
                    Divider().frame(height: 32)
                    statBlock(value: "\(allSegments.count)", label: "分镜")
                    Divider().frame(height: 32)
                    statBlock(value: String(format: "%.0fs", totalDuration), label: "总时长")
                }
            }
            .padding(16)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // 目标视频数
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("目标视频数量")
                        .font(.system(size: 13))
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("预估：\(numStrategies) 个策略 × ~\(perStrategy) 个变体/策略")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text("约 \(estimatedCalls) 次 AI 调用（\(numStrategies) 个策略并行生成）")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                }
            }
            .frame(width: 380)

            // 自定义需求（可选）
            VStack(alignment: .leading, spacing: 6) {
                Text("自定义需求（可选）")
                    .font(.system(size: 13))
                TextField("如：偏重促销风格、时长控制在30秒内...", text: $customPrompt)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            .frame(width: 380)

            // 按钮
            HStack(spacing: 12) {
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
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 11))
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
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
            Text(label)
                .font(.system(size: 10))
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

    var body: some View {
        VStack(spacing: 0) {
            // 策略头部（可点击展开/折叠）
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    if isExpanded {
                        viewModel.selectedStrategy = nil
                    } else {
                        viewModel.selectedStrategy = strategy
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(strategy.name)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Spacer()
                            Text("\(strategy.schemeCount) 个视频")
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 6) {
                            HStack(spacing: 3) {
                                Image(systemName: "paintpalette")
                                    .font(.system(size: 8))
                                Text(strategy.style)
                                    .font(.system(size: 10))
                            }
                            .foregroundStyle(.secondary)

                            HStack(spacing: 3) {
                                Image(systemName: "person.2")
                                    .font(.system(size: 8))
                                Text(strategy.targetAudience)
                                    .font(.system(size: 10))
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(isExpanded ? Color.accentColor.opacity(0.06) : .clear)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("删除策略", role: .destructive) {
                    viewModel.deleteStrategy(strategy)
                }
            }

            // 展开后显示变体列表
            if isExpanded {
                ForEach(strategy.orderedSchemes) { scheme in
                    SchemeVariationRow(
                        scheme: scheme,
                        isSelected: viewModel.selectedScheme?.id == scheme.id
                    )
                    .onTapGesture {
                        viewModel.selectedScheme = scheme
                    }
                    .contextMenu {
                        Button("删除变体", role: .destructive) {
                            viewModel.deleteScheme(scheme)
                        }
                    }
                }
            }

            Divider()
                .padding(.leading, 14)
        }
    }
}

// MARK: - 变体行

struct SchemeVariationRow: View {
    let scheme: MixScheme
    var isSelected: Bool = false
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            // 序号
            Text("#\(scheme.variationIndex)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.tertiary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(scheme.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text("\(scheme.segmentCount) 分镜")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.quaternary)
                    Text(String(format: "%.0fs", scheme.totalDuration))
                        .font(.system(size: 10, design: .rounded))
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
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
