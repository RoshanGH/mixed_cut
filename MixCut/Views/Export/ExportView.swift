import SwiftUI

struct ExportView: View {
    let project: Project
    @Bindable var schemeVM: SchemeViewModel

    @Environment(\.modelContext) private var modelContext
    @State private var dubVM = DubbingViewModel()

    @State private var exportConfig = ExportConfig()
    @State private var isExporting = false
    @State private var exportProgress: BatchExportProgress?
    @State private var exportedFolder: String?
    /// 本次实际**成功**的条数。完成页必须报这个，不能报 `progress.completed`（那个含失败计数）。
    @State private var exportedSucceededCount = 0
    @State private var errorMessage: String?

    /// 导出前确认弹窗
    @State private var showExportConfirm = false
    /// 正在进行的导出任务（用于「停止」取消）
    @State private var exportTask: Task<Void, Never>?
    /// 用户选中的方案 ID 集合（默认全选）
    @State private var selectedSchemeIDs: Set<UUID> = []
    /// 已展开的策略 ID 集合（默认全部展开）
    @State private var expandedStrategyIDs: Set<UUID> = []
    /// 本次导出的失败清单（哪一条、为什么），供用户定位与反馈
    @State private var exportFailures: [ExportFailure] = []

    private let exportService = ExportService()

    /// 当前选中的方案数组（按现有方案顺序）
    private var selectedSchemes: [MixScheme] {
        schemeVM.schemes.filter { selectedSchemeIDs.contains($0.id) }
    }

    /// 全选所有方案
    private func selectAll() {
        selectedSchemeIDs = Set(schemeVM.schemes.map(\.id))
        expandedStrategyIDs = Set(schemeVM.exportableStrategies.map(\.id))
    }

    /// 切换某个方案的选中
    private func toggleScheme(_ scheme: MixScheme) {
        if selectedSchemeIDs.contains(scheme.id) {
            selectedSchemeIDs.remove(scheme.id)
        } else {
            selectedSchemeIDs.insert(scheme.id)
        }
    }

    /// 切换整个策略下所有方案
    private func toggleStrategy(_ strategy: MixStrategy) {
        let strategySchemeIDs = Set(strategy.orderedSchemes.map(\.id))
        let allSelected = strategySchemeIDs.isSubset(of: selectedSchemeIDs) && !strategySchemeIDs.isEmpty
        if allSelected {
            selectedSchemeIDs.subtract(strategySchemeIDs)
        } else {
            selectedSchemeIDs.formUnion(strategySchemeIDs)
        }
    }

    /// 是否当前策略全部选中
    private func isStrategyFullySelected(_ strategy: MixStrategy) -> Bool {
        let ids = Set(strategy.orderedSchemes.map(\.id))
        return !ids.isEmpty && ids.isSubset(of: selectedSchemeIDs)
    }

    /// 是否当前策略部分选中
    private func isStrategyPartiallySelected(_ strategy: MixStrategy) -> Bool {
        let ids = Set(strategy.orderedSchemes.map(\.id))
        let intersection = ids.intersection(selectedSchemeIDs)
        return !intersection.isEmpty && intersection.count < ids.count
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.generous) {
                    // 概览
                    exportOverview

                    // 方案筛选（嵌入式 checkbox 列表）
                    if !schemeVM.schemes.isEmpty {
                        selectionSection
                    }

                    // 导出设置
                    exportSettings

                    Divider()

                    // 导出按钮
                    exportButton

                    if isExporting, let progress = exportProgress {
                        exportProgressView(progress)
                    }

                    if let folder = exportedFolder {
                        exportCompleteView(folder: folder)
                    }

                    if let error = errorMessage {
                        exportErrorView(error: error)
                    }

                    if !exportFailures.isEmpty {
                        exportFailureList
                    }
                }
                .padding(DesignTokens.Padding.page)
                // 560pt 在 1920 宽窗口下只占内容区的三分之一，两侧各留 570pt 空白，
                // 而导出页恰恰信息量最大（方案多选树 + 设置 + 进度 + 失败清单），
                // 被迫垂直堆成极长的滚动条。放宽到 860pt，仍保持可读行宽。
                .frame(maxWidth: 860)
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            schemeVM.loadSchemes(for: project)
            selectAll()
        }
        .onChange(of: project.id) {
            // ⚠️ 必须真的把任务取消掉，不能只清 UI 状态。
            // 否则 ffmpeg 会继续在后台跑，跑完还会往**新项目**的界面写进度/Toast/完成路径，
            // 而且此时若在新项目再点导出，两个任务并存但 exportTask 只记得住后一个。
            exportTask?.cancel()
            exportTask = nil

            // 切项目铁律：reset 上一个项目的导出状态，避免进度条 / 完成提示残留
            isExporting = false
            exportProgress = nil
            exportedFolder = nil
            exportedSucceededCount = 0
            errorMessage = nil
            exportFailures = []
            schemeVM.loadSchemes(for: project)
            selectAll()
        }
        .navigationTitle("导出")
    }

    // MARK: - 方案筛选

    private var selectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.tertiary)
                Text("选择要导出的方案")
                    .font(DesignTokens.Typography.labelEmphasis)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("已选 \(selectedSchemeIDs.count) / \(schemeVM.schemes.count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(DesignTokens.Palette.Alpha.subtle))
                    .clipShape(Capsule())
            }

            // 全选 / 反选 / 清空
            HStack(spacing: DesignTokens.Spacing.normal) {
                Button("全选") { selectAll() }
                    .buttonStyle(.plain)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(Color.accentColor)

                Button("反选") {
                    let allIDs = Set(schemeVM.schemes.map(\.id))
                    selectedSchemeIDs = allIDs.symmetricDifference(selectedSchemeIDs)
                }
                .buttonStyle(.plain)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(Color.accentColor)

                Button("清空") { selectedSchemeIDs.removeAll() }
                    .buttonStyle(.plain)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .disabled(selectedSchemeIDs.isEmpty)
            }

            // 策略 + 方案树
            // 用 LazyVStack：默认全选会展开所有策略，方案多时一次性实例化整棵树会明显卡顿。
            LazyVStack(spacing: 0) {
                ForEach(schemeVM.exportableStrategies) { strategy in
                    strategyRow(strategy: strategy)
                    if expandedStrategyIDs.contains(strategy.id) {
                        ForEach(strategy.orderedSchemes) { scheme in
                            schemeRow(scheme: scheme)
                        }
                    }
                    Divider().padding(.leading, 30)
                }
            }
            .background(.quaternary.opacity(DesignTokens.Palette.Alpha.subtle * 2))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func strategyRow(strategy: MixStrategy) -> some View {
        // ⚠️ 性能：这些判断以前各自调用 isStrategyFullySelected / isStrategyPartiallySelected，
        // 每次都要 `Set(strategy.orderedSchemes.map(\.id))`（含一次排序）。单行会重复算 4 次，
        // 每点一个勾选框整棵树重算 → 方案多时明显卡顿。这里每行只算一次，复用结果。
        let schemeIDs = Set(strategy.orderedSchemes.map(\.id))
        let selectedInStrategy = schemeIDs.intersection(selectedSchemeIDs)
        let isFull = !schemeIDs.isEmpty && selectedInStrategy.count == schemeIDs.count
        let isPartial = !selectedInStrategy.isEmpty && selectedInStrategy.count < schemeIDs.count

        let total = strategy.schemes.count
        let selectedCount = selectedInStrategy.count
        let isExpanded = expandedStrategyIDs.contains(strategy.id)
        let checkboxIcon: String = isFull ? "checkmark.square.fill"
                                 : isPartial ? "minus.square.fill"
                                 : "square"

        return HStack(spacing: DesignTokens.Spacing.compact) {
            // checkbox（点击切换整个策略）
            Button {
                toggleStrategy(strategy)
            } label: {
                Image(systemName: checkboxIcon)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(isFull || isPartial ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择该策略")

            // 展开/折叠 + 标题
            Button {
                if isExpanded {
                    expandedStrategyIDs.remove(strategy.id)
                } else {
                    expandedStrategyIDs.insert(strategy.id)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(DesignTokens.Typography.microRegular)
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)

                    if strategy.isCustomGroup {
                        Image(systemName: "sparkles")
                            .font(DesignTokens.Typography.microRegular)
                            .foregroundStyle(.purple)
                    }

                    Text(strategy.name)
                        .font(DesignTokens.Typography.labelStrong)
                        .lineLimit(1)

                    Spacer()

                    Text("\(selectedCount)/\(total)")
                        .font(DesignTokens.Typography.microRounded)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func schemeRow(scheme: MixScheme) -> some View {
        let isSelected = selectedSchemeIDs.contains(scheme.id)
        return HStack(spacing: DesignTokens.Spacing.compact) {
            Button {
                toggleScheme(scheme)
            } label: {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "取消选择该方案" : "选择该方案")

            Text("#\(scheme.variationIndex)")
                .font(DesignTokens.Typography.microMetric)
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .leading)
                .lineLimit(1)
                .monospacedDigit()   // 序号到 #100 时 28pt 会溢出

            Text(scheme.name)
                .font(DesignTokens.Typography.caption)
                .lineLimit(1)

            if scheme.isManuallyEdited {
                Text("·已修改")
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Text(String(format: "%.1fs", scheme.totalDuration))
                .font(DesignTokens.Typography.microRounded)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 36)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            toggleScheme(scheme)
        }
    }

    // MARK: - 概览

    private var exportOverview: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.compact) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.tertiary)
                Text("导出概览")
                    .font(DesignTokens.Typography.labelEmphasis)
                    .foregroundStyle(.secondary)
            }

            let totalSchemes = schemeVM.schemes.count
            let totalStrategies = schemeVM.strategies.count

            if totalSchemes == 0 {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.orange)
                    Text("暂无可导出的方案，请先生成混剪方案")
                        .font(DesignTokens.Typography.label)
                        .foregroundStyle(.secondary)
                }
                .padding(DesignTokens.Spacing.normal)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                let totalDuration = schemeVM.schemes.reduce(0.0) { $0 + $1.totalDuration }
                let estimatedMB = estimatedFileSizeMB(durationSec: totalDuration)

                HStack(spacing: 0) {
                    statBlock(value: "\(totalStrategies)", label: "策略")
                    Divider().frame(height: 32)
                    statBlock(value: "\(totalSchemes)", label: "视频")
                    Divider().frame(height: 32)
                    statBlock(value: String(format: "%.0fs", totalDuration), label: "总时长")
                    Divider().frame(height: 32)
                    statBlock(value: estimatedMB >= 1024
                        ? String(format: "%.1f GB", Double(estimatedMB) / 1024)
                        : "\(estimatedMB) MB",
                              label: "预估大小")
                }
                .padding(DesignTokens.Spacing.comfortable)
                .background(.quaternary.opacity(DesignTokens.Palette.Alpha.medium))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    /// 根据当前编码配置和总时长估算导出文件总大小（MB）
    private func estimatedFileSizeMB(durationSec: Double) -> Int {
        let kbps = exportConfig.quality.videoBitrateKbps(for: exportConfig.codec)
        // bitrate (kbps) × duration (s) / 8 = KB；÷ 1024 = MB
        let mb = Double(kbps) * durationSec / 8.0 / 1024.0
        return max(1, Int(mb))
    }

    // MARK: - 导出设置

    private var exportSettings: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.normal) {
            HStack(spacing: 6) {
                Image(systemName: "gearshape")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.tertiary)
                Text("导出设置")
                    .font(DesignTokens.Typography.labelEmphasis)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: DesignTokens.Spacing.compact) {
                Picker("分辨率", selection: $exportConfig.resolution) {
                    ForEach(ExportConfig.ExportResolution.allCases) { res in
                        Text(res.rawValue).tag(res)
                    }
                }

                Picker("编码器", selection: $exportConfig.codec) {
                    ForEach(ExportConfig.ExportCodec.allCases) { codec in
                        Text(codec.rawValue).tag(codec)
                    }
                }

                Picker("质量", selection: $exportConfig.quality) {
                    ForEach(ExportConfig.ExportQuality.allCases) { q in
                        Text(q.rawValue).tag(q)
                    }
                }

                // 质量提示：根据当前 codec + quality 显示对应码率和预估文件大小
                HStack(spacing: DesignTokens.Spacing.tight) {
                    Image(systemName: "info.circle")
                        .font(DesignTokens.Typography.microRegular)
                        .foregroundStyle(.tertiary)
                    Text(exportConfig.qualityHint)
                        .font(DesignTokens.Typography.microRegular)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.top, 2)
            }
            .controlSize(.regular)
        }
    }

    // MARK: - 导出按钮

    @ViewBuilder
    private var exportButton: some View {
        let count = selectedSchemeIDs.count
        let isDisabled = selectedSchemeIDs.isEmpty || isExporting || schemeVM.schemes.isEmpty
        let totalClips = totalComboCount()

        // 配音组合导出：每个选中方案按「每镜 原声 + 各改写版」的全部排列组合，逐条导出
        Button {
            showExportConfirm = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "waveform.badge.mic")
                    .font(DesignTokens.Typography.body)
                Text(count > 0 ? "导出配音组合（共 \(totalClips) 条）" : "请先选择方案")
                    .font(DesignTokens.Typography.bodyLargeEmphasis)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isDisabled || totalClips == 0)
        .help(schemeVM.schemes.isEmpty
              ? "暂无方案可导出，请先在「混剪方案」页面生成"
              : isExporting ? "正在导出中"
              : selectedSchemeIDs.isEmpty ? "请先勾选要导出的方案"
              : "画面不变，按每个分镜的「原声 + 各改写版」全部排列组合，串行逐条导出")
        .alert("将生成 \(totalClips) 条视频", isPresented: $showExportConfirm) {
            Button("取消", role: .cancel) {}
            Button("导出") { startDubbedExport() }
        } message: {
            Text("选中 \(count) 个方案，画面不变，按每个分镜的「原声 + 各改写版」全部排列组合，串行逐条生成（一条一条导，避免占满机器）。")
        }

        if schemeVM.schemes.isEmpty && !isExporting {
            HStack(spacing: DesignTokens.Spacing.tight) {
                Image(systemName: "info.circle")
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.tertiary)
                Text("请先在「混剪方案」页面生成方案")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 进度

    private func exportProgressView(_ progress: BatchExportProgress) -> some View {
        VStack(spacing: 10) {
            ProgressView(value: progress.overallProgress)
                .tint(.blue)

            HStack {
                Text(progress.description)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(progress.completed)/\(progress.total)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            if isExporting {
                Button(role: .destructive) {
                    stopExport()
                } label: {
                    Label("停止导出", systemImage: "stop.fill")
                        .font(DesignTokens.Typography.labelEmphasis)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(.red)
                .help("立即停止导出（已完成的视频保留，正在导出的这条会被丢弃）")
            }
        }
        .padding(DesignTokens.Spacing.comfortable)
        .background(.quaternary.opacity(DesignTokens.Palette.Alpha.subtle * 2))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 完成

    private func exportCompleteView(folder: String) -> some View {
        VStack(spacing: DesignTokens.Spacing.normal) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.green)

            // 不说"全部"——有失败时这个面板同样会显示，说"全部"是谎报
            Text("导出完成")
                .font(DesignTokens.Typography.bodyLargeEmphasis)

            // 报**成功条数**，不报 progress.completed（后者把失败也算进去了）
            Text("共导出 \(exportedSucceededCount) 个视频")
                .font(DesignTokens.Typography.label)
                .foregroundStyle(.secondary)

            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder)
            } label: {
                HStack(spacing: DesignTokens.Spacing.tight) {
                    Image(systemName: "folder")
                        .font(DesignTokens.Typography.caption)
                    Text("在 Finder 中打开")
                        .font(DesignTokens.Typography.label)
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(DesignTokens.Padding.page)
        .background(.green.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.green.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - 错误

    /// 失败清单：一行一条「文件名 + 人话原因」，并支持一键复制详情。
    /// 以前只有一句"N 个视频导出失败或跳过"，用户既不知道是哪几条，也不知道为什么。
    private var exportFailureList: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.compact) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesignTokens.Palette.Status.warning)
                Text("以下 \(exportFailures.count) 条未能导出")
                    .font(DesignTokens.Typography.cardTitle)
                Spacer()
                Button {
                    let text = exportFailures.map { "\($0.name)：\($0.reason)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    ToastCenter.shared.show("已复制失败详情", icon: "doc.on.doc", style: .info)
                } label: {
                    Label("复制详情", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }

            ForEach(exportFailures) { failure in
                VStack(alignment: .leading, spacing: 2) {
                    Text(failure.name)
                        .font(DesignTokens.Typography.label)
                        .lineLimit(1)
                    Text(failure.reason)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
        .padding(DesignTokens.Spacing.comfortable)
        .background(DesignTokens.Palette.Status.warning.opacity(DesignTokens.Palette.Alpha.subtle))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.medium, style: DesignTokens.Corner.style))
    }

    private func exportErrorView(error: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "xmark.circle.fill")
                .font(DesignTokens.Typography.headline)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("导出失败")
                    .font(DesignTokens.Typography.labelStrong)
                Text(error)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(DesignTokens.Spacing.comfortable)
        .background(.red.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.red.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - 辅助

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

    // MARK: - 并发数计算

    /// 视频导出并发数 — 走 ConcurrencyPolicy（基于 Apple Silicon Media Engine 数）
    private var optimalConcurrency: Int {
        ConcurrencyPolicy.maxExportConcurrency()
    }

    // MARK: - 批量导出（并发）

    private func startBatchExport() {
        let allSchemes = selectedSchemes
        guard !allSchemes.isEmpty else { return }

        exportedFolder = nil
        errorMessage = nil

        // 选择输出文件夹
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择导出文件夹"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // 选目录当下就校验可写性：否则每条视频都要完整跑一遍 ffmpeg 才失败，
            // 全部跑完才在结果页列出一堆同样的错误，白白浪费几十分钟。
            if let problem = ExportDestination.validate(directory: url) {
                errorMessage = problem
                return
            }
            errorMessage = nil

            // ⚠️ 必须存进 exportTask。`stopExport()` 走的是 `exportTask?.cancel()`，
            // 这条路径以前用的是裸 Task，exportTask 恒为 nil ——
            // 界面上照样渲染「停止导出」按钮，但点下去什么都不会发生，ffmpeg 一路跑到底。
            exportTask = Task { @MainActor in
                // 在 MainActor 上提取所有导出任务数据（SwiftData 模型必须在 MainActor）
                let total = allSchemes.count
                let concurrency = 1   // 导出一律串行（用户要求，不再并发）

                var exportTasks: [(input: ExportInput, outputPath: String, name: String)] = []
                for scheme in allSchemes {
                    let strategyName = scheme.strategy?.name ?? "未分组"
                    let sanitized = sanitizeFilename("\(strategyName)_\(scheme.variationIndex)_\(scheme.name)")
                    let outputPath = url.appendingPathComponent("\(sanitized).mp4").path

                    if let input = ExportInput.from(scheme: scheme) {
                        exportTasks.append((input: input, outputPath: outputPath, name: scheme.name))
                    }
                }

                guard !exportTasks.isEmpty else {
                    errorMessage = "没有有效的方案可导出"
                    return
                }
                isExporting = true
                exportFailures = []
                let validTotal = exportTasks.count
                let skippedCount = total - validTotal

                exportProgress = BatchExportProgress(
                    total: validTotal, completed: 0,
                    description: "准备并发导出（\(concurrency) 路并行）..."
                )

                // 线程安全的计数器
                let counter = ExportCounter()
                let config = exportConfig

                // 返回失败详情而非 Bool：只报数量的话，用户不知道是哪几条、为什么失败，也无法只重试失败项。
                let failureList: [ExportFailure] = await withTaskGroup(of: ExportFailure?.self) { group in
                    var taskIndex = 0
                    var failures: [ExportFailure] = []

                    // 初始填充 concurrency 个任务
                    for _ in 0..<min(concurrency, exportTasks.count) {
                        let task = exportTasks[taskIndex]
                        let service = ExportService()
                        taskIndex += 1

                        group.addTask {
                            do {
                                try await service.export(
                                    input: task.input,
                                    outputPath: task.outputPath,
                                    config: config,
                                    onProgress: { ffProgress in
                                        Task { @MainActor in
                                            let done = counter.value
                                            self.exportProgress = BatchExportProgress(
                                                total: validTotal, completed: done,
                                                currentProgress: ffProgress.progress,
                                                description: "正在导出: \(task.name)... \(Int(ffProgress.progress * 100))%"
                                            )
                                        }
                                    }
                                )
                                return nil
                            } catch {
                                // 用户点「停止导出」不是失败，不该出现在失败清单里
                                if Task.isCancelled { return nil }
                                let reason = FriendlyError.reason(for: error)
                                MixLog.error("导出失败「\(task.name)」: \(error.localizedDescription)")
                                return ExportFailure(name: task.name, reason: reason)
                            }
                        }
                    }

                    // 每完成一个就补充一个新任务
                    for await failure in group {
                        if let failure { failures.append(failure) }
                        let done = counter.increment()

                        await MainActor.run {
                            self.exportProgress = BatchExportProgress(
                                total: validTotal, completed: done,
                                description: "已完成 \(done)/\(validTotal)..."
                            )
                        }

                        if taskIndex < exportTasks.count {
                            let task = exportTasks[taskIndex]
                            let service = ExportService()
                            taskIndex += 1

                            group.addTask {
                                do {
                                    try await service.export(
                                        input: task.input,
                                        outputPath: task.outputPath,
                                        config: config,
                                        onProgress: { ffProgress in
                                            Task { @MainActor in
                                                let done = counter.value
                                                self.exportProgress = BatchExportProgress(
                                                    total: validTotal, completed: done,
                                                    currentProgress: ffProgress.progress,
                                                    description: "正在导出: \(task.name)... \(Int(ffProgress.progress * 100))%"
                                                )
                                            }
                                        }
                                    )
                                    return nil
                                } catch {
                                    // 同上：取消不计为失败
                                    if Task.isCancelled { return nil }
                                    let reason = FriendlyError.reason(for: error)
                                    MixLog.error("导出失败「\(task.name)」: \(error.localizedDescription)")
                                    return ExportFailure(name: task.name, reason: reason)
                                }
                            }
                        }
                    }

                    return failures
                }

                let failedCount = failureList.count
                let totalFailed = failedCount + skippedCount
                exportFailures = failureList

                exportProgress = BatchExportProgress(
                    total: validTotal, completed: validTotal,
                    description: "导出完成"
                )

                if totalFailed > 0 && totalFailed == total {
                    errorMessage = "所有视频导出失败，请检查视频文件是否存在"
                    ToastCenter.shared.show("导出失败", icon: "exclamationmark.triangle.fill", style: .error)
                } else if totalFailed > 0 {
                    // 「失败」与「跳过」是两件事，分开说；具体是哪几条、什么原因见下方失败清单。
                    var parts: [String] = []
                    if failedCount > 0 { parts.append("\(failedCount) 个导出失败") }
                    if skippedCount > 0 { parts.append("\(skippedCount) 个因素材缺失被跳过") }
                    errorMessage = parts.joined(separator: "，")
                    let succeeded = validTotal - failedCount
                    ToastCenter.shared.show("成功 \(succeeded) / 失败 \(totalFailed)", icon: "exclamationmark.triangle.fill", style: .warning)
                } else {
                    ToastCenter.shared.show("已导出 \(validTotal) 个视频", icon: "checkmark.seal.fill", style: .success)
                }

                exportedFolder = url.path
                isExporting = false
            }
        }
    }

    /// 选中方案将生成的总视频条数（= 各方案配音组合数之和，单方案上限 maxCombos）。
    private func totalComboCount() -> Int {
        selectedSchemes.reduce(0) { acc, scheme in
            acc + min(SchemeComboPlanner.maxCombos, SchemeComboPlanner.feasibleCount(for: scheme))
        }
    }

    /// 配音组合导出：每个选中方案按笛卡尔积（每镜 原声 + 各改写版，锁定=1）导出。
    /// 画面不变，仅声音不同；文件名后缀标明组合（如 [原·A·原·B·A]）。配音段混入分离 BGM。
    /// 按机器能力自适应并发（ConcurrencyPolicy，已为机器留余量），可随时「停止」。
    private func startDubbedExport() {
        let allSchemes = selectedSchemes
        guard !allSchemes.isEmpty else { return }
        exportedFolder = nil
        errorMessage = nil

        // 先在主线程把每个方案的组合算好（需读 SwiftData 模型）
        let plans: [(scheme: MixScheme, combos: [SchemeComboPlanner.Combo])] =
            allSchemes.map { ($0, SchemeComboPlanner.plan(for: $0).combos) }
        let totalClips = plans.reduce(0) { $0 + $1.combos.count }
        guard totalClips > 0 else {
            ToastCenter.shared.show("没有可导出的组合", icon: "exclamationmark.triangle.fill", style: .warning)
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择导出文件夹"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // 选目录当下就校验可写性：否则每条视频都要完整跑一遍 ffmpeg 才失败，
            // 全部跑完才在结果页列出一堆同样的错误，白白浪费几十分钟。
            if let problem = ExportDestination.validate(directory: url) {
                errorMessage = problem
                return
            }
            errorMessage = nil
            exportTask = Task { @MainActor in
                isExporting = true
                defer { isExporting = false; exportTask = nil }
                let config = exportConfig
                let maxConcurrency = 1   // 导出一律串行（用户要求，不再并发）

                // 1) 预先补齐各方案选定音频（顺序，多为 no-op；确保分离/变体音频就绪）
                //
                // ⚠️ 这一步可能跑好几分钟（人声分离 demucs），但进度区的渲染条件是
                // `isExporting && exportProgress != nil`，而 exportProgress 原先要到第 3 步才赋值 ——
                // 于是整个预处理期间界面上什么都没有，连「停止导出」按钮都不存在，看起来就像卡死。
                // 这里先放一个占位进度，把停止按钮和状态文案立刻显示出来。
                exportProgress = BatchExportProgress(total: max(1, plans.count), completed: 0,
                                                     description: "正在准备音频（人声分离 / 配音合成）…")
                for (index, (scheme, _)) in plans.enumerated() {
                    if Task.isCancelled { break }
                    exportProgress = BatchExportProgress(
                        total: max(1, plans.count), completed: index,
                        description: "正在准备音频 \(index + 1)/\(plans.count)：\(scheme.name)")
                    await dubVM.ensureSelectedAudio(for: scheme, context: modelContext)
                }

                // 2) 扁平化所有 (方案×组合) 任务（DubExportInput 须在 MainActor 构造）
                var jobs: [DubExportJob] = []
                for (scheme, combos) in plans {
                    let strategyName = scheme.strategy?.name ?? "未分组"
                    for combo in combos {
                        guard let input = DubExportInput.from(scheme: scheme, combo: combo.choices) else { continue }
                        let base = sanitizeFilename("\(strategyName)_方案\(scheme.variationIndex)_\(combo.nameSuffix)")
                        jobs.append(DubExportJob(
                            input: input,
                            outputPath: url.appendingPathComponent("\(base).mp4").path,
                            label: "\(scheme.name) \(combo.nameSuffix)"))
                    }
                }
                let totalJobs = jobs.count

                // 3) 有界并发渲染：工作队列填满 maxConcurrency 个槽，完成一个补一个
                var completed = 0
                var succeeded = 0
                var nextIndex = 0
                var stopped = false

                exportProgress = BatchExportProgress(total: totalJobs, completed: 0,
                                                     description: "串行导出中…")

                // 返回 nil 表示成功；失败则带回**具体原因**，供完成后的失败清单展示。
                // 原先这里只返回 Bool，错误信息直接丢进日志，用户只能看到"成功 3 / 失败 5"，
                // 完全不知道是哪 5 条、为什么失败（而 FFmpegError 本来就有人话文案）。
                await withTaskGroup(of: ExportJobResult.self) { group in
                    func addJob(_ i: Int) {
                        let job = jobs[i]
                        group.addTask {
                            let service = DubExportService()
                            // 目标路径原本就有文件时不能删——那是用户自己的东西
                            let existedBefore = FileManager.default.fileExists(atPath: job.outputPath)
                            do {
                                // 接上分阶段进度。原先没传 onProgress，`currentProgress` 恒为 0，
                                // 进度条只在整条视频跑完时才跳一格 —— 单条 60 秒成片可能要几分钟，
                                // 期间界面完全静止，用户会以为卡死了。
                                try await service.export(
                                    input: job.input, outputPath: job.outputPath, config: config,
                                    onProgress: { p in
                                        Task { @MainActor in
                                            guard isExporting else { return }
                                            exportProgress = BatchExportProgress(
                                                total: totalJobs,
                                                completed: completed,
                                                currentProgress: p.progress,
                                                description: "\(job.label)：\(p.description)"
                                            )
                                        }
                                    }
                                )
                                return .succeeded
                            } catch {
                                // 失败/取消都可能留下"能播但只有一半"的 mp4，必须清掉，
                                // 否则用户拿到一个看起来正常、发出去才发现播一半就断的文件。
                                if !existedBefore {
                                    try? FileManager.default.removeItem(atPath: job.outputPath)
                                }
                                // 取消既不算成功也不算失败，单独一态
                                if Task.isCancelled { return .cancelled }
                                MixLog.error("配音组合导出失败「\(job.label)」: \(error.localizedDescription)")
                                return .failed(ExportFailure(name: job.label, reason: error.localizedDescription))
                            }
                        }
                    }

                    while nextIndex < totalJobs && nextIndex < maxConcurrency {
                        addJob(nextIndex); nextIndex += 1
                    }
                    for await result in group {
                        completed += 1
                        switch result {
                        case .succeeded:            succeeded += 1
                        case .failed(let failure):  exportFailures.append(failure)
                        case .cancelled:            break
                        }
                        if Task.isCancelled {
                            stopped = true
                            group.cancelAll()
                        } else if nextIndex < totalJobs {
                            addJob(nextIndex); nextIndex += 1
                        }
                        exportProgress = BatchExportProgress(
                            total: totalJobs, completed: completed,
                            description: stopped ? "停止中…" : "串行导出中… \(completed)/\(totalJobs)")
                    }
                }

                // 直接取失败清单长度，不要用 completed - succeeded 反推：
                // 「取消」也会计入 completed，减法会把用户主动取消的任务算成失败。
                let failed = exportFailures.count
                if stopped {
                    exportProgress = BatchExportProgress(total: totalJobs, completed: completed, description: "已停止")
                    ToastCenter.shared.show("已停止，完成 \(succeeded) 条", icon: "stop.circle.fill", style: .warning)
                } else {
                    exportProgress = BatchExportProgress(total: totalJobs, completed: totalJobs, description: "导出完成")
                    if succeeded == 0 {
                        errorMessage = "所有组合导出失败"
                        ToastCenter.shared.show("导出失败", icon: "exclamationmark.triangle.fill", style: .error)
                    } else if failed > 0 {
                        ToastCenter.shared.show("成功 \(succeeded) / 失败 \(failed)", icon: "exclamationmark.triangle.fill", style: .warning)
                    } else {
                        ToastCenter.shared.show("已导出 \(succeeded) 条视频", icon: "checkmark.seal.fill", style: .success)
                    }
                }
                // ⚠️ 只有**确实产出了文件**才展示"全部导出完成"绿框。
                // 原先无条件赋值，导致 8 条全失败时页面上同时出现红色"所有组合导出失败"
                // 和绿色"全部导出完成 · 共导出 8 个视频"，自相矛盾还谎报数量。
                exportedSucceededCount = succeeded
                if succeeded > 0 {
                    exportedFolder = url.path
                }
            }
        }
    }

    /// 停止当前导出：取消 Task → 连带终止正在运行的 ffmpeg 进程。
    private func stopExport() {
        exportTask?.cancel()
    }

    /// 清理文件名中的非法字符
    private func sanitizeFilename(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: illegal).joined(separator: "_")
    }
}

/// 单条配音组合导出任务（值类型，可跨并发传递）
private struct DubExportJob: Sendable {
    let input: DubExportInput
    let outputPath: String
    let label: String
}

/// 批量导出进度
struct BatchExportProgress {
    let total: Int
    let completed: Int
    var currentProgress: Double = 0
    let description: String

    var overallProgress: Double {
        guard total > 0 else { return 0 }
        return (Double(completed) + currentProgress) / Double(total)
    }
}

/// 线程安全的计数器
final class ExportCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        _value += 1
        let v = _value
        lock.unlock()
        return v
    }
}


/// 一条导出失败记录：给用户看「哪一条、为什么」。
struct ExportFailure: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let reason: String
}

/// 单条导出任务的结局。
/// 必须把「取消」和「失败」分开：取消既不该计入成功数（会谎报导出条数），
/// 也不该进失败清单（用户自己点的停止，不是错误）。
enum ExportJobResult: Sendable {
    case succeeded
    case failed(ExportFailure)
    case cancelled
}
