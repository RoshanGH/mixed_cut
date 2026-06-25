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
    @State private var errorMessage: String?

    /// 导出前确认弹窗
    @State private var showExportConfirm = false
    /// 正在进行的导出任务（用于「停止」取消）
    @State private var exportTask: Task<Void, Never>?
    /// 用户选中的方案 ID 集合（默认全选）
    @State private var selectedSchemeIDs: Set<UUID> = []
    /// 已展开的策略 ID 集合（默认全部展开）
    @State private var expandedStrategyIDs: Set<UUID> = []

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
                VStack(alignment: .leading, spacing: 24) {
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
                }
                .padding(24)
                .frame(maxWidth: 560)
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            schemeVM.loadSchemes(for: project)
            selectAll()
        }
        .onChange(of: project.id) {
            // 切项目铁律：reset 上一个项目的导出状态，避免进度条 / 完成提示残留
            isExporting = false
            exportProgress = nil
            exportedFolder = nil
            errorMessage = nil
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
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text("选择要导出的方案")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("已选 \(selectedSchemeIDs.count) / \(schemeVM.schemes.count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.08))
                    .clipShape(Capsule())
            }

            // 全选 / 反选 / 清空
            HStack(spacing: 12) {
                Button("全选") { selectAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)

                Button("反选") {
                    let allIDs = Set(schemeVM.schemes.map(\.id))
                    selectedSchemeIDs = allIDs.symmetricDifference(selectedSchemeIDs)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)

                Button("清空") { selectedSchemeIDs.removeAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .disabled(selectedSchemeIDs.isEmpty)
            }

            // 策略 + 方案树
            VStack(spacing: 0) {
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
            .background(.quaternary.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func strategyRow(strategy: MixStrategy) -> some View {
        let total = strategy.schemes.count
        let selectedCount = strategy.schemes.filter { selectedSchemeIDs.contains($0.id) }.count
        let isExpanded = expandedStrategyIDs.contains(strategy.id)
        let checkboxIcon: String = {
            if isStrategyFullySelected(strategy) { return "checkmark.square.fill" }
            if isStrategyPartiallySelected(strategy) { return "minus.square.fill" }
            return "square"
        }()

        return HStack(spacing: 8) {
            // checkbox（点击切换整个策略）
            Button {
                toggleStrategy(strategy)
            } label: {
                Image(systemName: checkboxIcon)
                    .font(.system(size: 13))
                    .foregroundStyle(isStrategyFullySelected(strategy) || isStrategyPartiallySelected(strategy)
                                     ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)

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
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)

                    if strategy.isCustomGroup {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10))
                            .foregroundStyle(.purple)
                    }

                    Text(strategy.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)

                    Spacer()

                    Text("\(selectedCount)/\(total)")
                        .font(.system(size: 10, design: .rounded))
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
        return HStack(spacing: 8) {
            Button {
                toggleScheme(scheme)
            } label: {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)

            Text("#\(scheme.variationIndex)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.tertiary)
                .frame(width: 28, alignment: .leading)

            Text(scheme.name)
                .font(.system(size: 11))
                .lineLimit(1)

            if scheme.isManuallyEdited {
                Text("·已修改")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Text(String(format: "%.1fs", scheme.totalDuration))
                .font(.system(size: 10, design: .rounded))
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text("导出概览")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            let totalSchemes = schemeVM.schemes.count
            let totalStrategies = schemeVM.strategies.count

            if totalSchemes == 0 {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text("暂无可导出的方案，请先生成混剪方案")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
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
                .padding(16)
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 10))
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text("导出设置")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
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
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(exportConfig.qualityHint)
                        .font(.system(size: 10))
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
                    .font(.system(size: 13))
                Text(count > 0 ? "导出配音组合（共 \(totalClips) 条）" : "请先选择方案")
                    .font(.system(size: 14, weight: .semibold))
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
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text("请先在「混剪方案」页面生成方案")
                    .font(.system(size: 11))
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
                    .font(.system(size: 11))
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
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(.red)
                .help("立即停止导出（已完成的视频保留，正在导出的这条会被丢弃）")
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 完成

    private func exportCompleteView(folder: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.green)

            Text("全部导出完成")
                .font(.system(size: 14, weight: .semibold))

            if let progress = exportProgress {
                Text("共导出 \(progress.completed) 个视频")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                    Text("在 Finder 中打开")
                        .font(.system(size: 12))
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(.green.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.green.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - 错误

    private func exportErrorView(error: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("导出失败")
                    .font(.system(size: 12, weight: .medium))
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(.red.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.red.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - 辅助

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

            Task { @MainActor in
                // 在 MainActor 上提取所有导出任务数据（SwiftData 模型必须在 MainActor）
                let total = allSchemes.count
                let concurrency = optimalConcurrency

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
                let validTotal = exportTasks.count
                let skippedCount = total - validTotal

                exportProgress = BatchExportProgress(
                    total: validTotal, completed: 0,
                    description: "准备并发导出（\(concurrency) 路并行）..."
                )

                // 线程安全的计数器
                let counter = ExportCounter()
                let config = exportConfig

                let failedCount: Int = await withTaskGroup(of: Bool.self) { group in
                    var taskIndex = 0
                    var failures = 0

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
                                return true
                            } catch {
                                MixLog.error("导出失败「\(task.name)」: \(error.localizedDescription)")
                                return false
                            }
                        }
                    }

                    // 每完成一个就补充一个新任务
                    for await success in group {
                        if !success { failures += 1 }
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
                                    return true
                                } catch {
                                    MixLog.error("导出失败「\(task.name)」: \(error.localizedDescription)")
                                    return false
                                }
                            }
                        }
                    }

                    return failures
                }

                let totalFailed = failedCount + skippedCount

                exportProgress = BatchExportProgress(
                    total: validTotal, completed: validTotal,
                    description: "导出完成"
                )

                if totalFailed > 0 && totalFailed == total {
                    errorMessage = "所有视频导出失败，请检查视频文件是否存在"
                    ToastCenter.shared.show("导出失败", icon: "exclamationmark.triangle.fill", style: .error)
                } else if totalFailed > 0 {
                    errorMessage = "\(totalFailed) 个视频导出失败或跳过"
                    let succeeded = validTotal - totalFailed
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
            exportTask = Task { @MainActor in
                isExporting = true
                defer { isExporting = false; exportTask = nil }
                let config = exportConfig
                let maxConcurrency = max(1, ConcurrencyPolicy.maxExportConcurrency())

                // 1) 预先补齐各方案选定音频（顺序，多为 no-op；确保分离/变体音频就绪）
                for (scheme, _) in plans {
                    if Task.isCancelled { break }
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
                                                     description: "导出中（\(maxConcurrency) 路并发）…")

                await withTaskGroup(of: Bool.self) { group in
                    func addJob(_ i: Int) {
                        let job = jobs[i]
                        group.addTask {
                            let service = DubExportService()
                            do {
                                try await service.export(input: job.input, outputPath: job.outputPath, config: config)
                                return true
                            } catch {
                                // 取消会终止 ffmpeg 并抛错：清理半成品，不计为失败
                                if Task.isCancelled {
                                    try? FileManager.default.removeItem(atPath: job.outputPath)
                                } else {
                                    MixLog.error("配音组合导出失败「\(job.label)」: \(error.localizedDescription)")
                                }
                                return false
                            }
                        }
                    }

                    while nextIndex < totalJobs && nextIndex < maxConcurrency {
                        addJob(nextIndex); nextIndex += 1
                    }
                    for await ok in group {
                        completed += 1
                        if ok { succeeded += 1 }
                        if Task.isCancelled {
                            stopped = true
                            group.cancelAll()
                        } else if nextIndex < totalJobs {
                            addJob(nextIndex); nextIndex += 1
                        }
                        exportProgress = BatchExportProgress(
                            total: totalJobs, completed: completed,
                            description: stopped ? "停止中…" : "导出中（\(maxConcurrency) 路并发）… \(completed)/\(totalJobs)")
                    }
                }

                let failed = max(0, completed - succeeded)
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
                exportedFolder = url.path
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
