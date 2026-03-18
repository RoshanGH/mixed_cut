import SwiftUI

struct ExportView: View {
    let project: Project
    @Bindable var schemeVM: SchemeViewModel

    @State private var exportConfig = ExportConfig()
    @State private var isExporting = false
    @State private var exportProgress: BatchExportProgress?
    @State private var exportedFolder: String?
    @State private var errorMessage: String?

    private let exportService = ExportService()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // 概览
                    exportOverview

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
        }
        .onChange(of: project.id) {
            schemeVM.loadSchemes(for: project)
        }
        .navigationTitle("导出")
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
                HStack(spacing: 0) {
                    statBlock(value: "\(totalStrategies)", label: "策略")
                    Divider().frame(height: 32)
                    statBlock(value: "\(totalSchemes)", label: "视频")
                    Divider().frame(height: 32)
                    let totalDuration = schemeVM.schemes.reduce(0.0) { $0 + $1.totalDuration }
                    statBlock(value: String(format: "%.0fs", totalDuration), label: "总时长")
                }
                .padding(16)
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
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
            }
            .controlSize(.regular)
        }
    }

    // MARK: - 导出按钮

    @ViewBuilder
    private var exportButton: some View {
        Button {
            startBatchExport()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up.fill")
                    .font(.system(size: 13))
                Text("全部导出")
                    .font(.system(size: 14, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(schemeVM.schemes.isEmpty || isExporting)

        if schemeVM.schemes.isEmpty && !isExporting {
            Text("请先在「混剪方案」页面生成方案")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
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

    /// 根据 CPU 核心数动态计算最优并发数
    /// FFmpeg 编码每个任务约占 2 核，留 2 核给系统
    private var optimalConcurrency: Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        // 至少 1 路，每 2 核 1 路，留 2 核给系统，上限 8 路
        return max(1, min(8, (cores - 2) / 2))
    }

    // MARK: - 批量导出（并发）

    private func startBatchExport() {
        let allSchemes = schemeVM.schemes
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
                } else if totalFailed > 0 {
                    errorMessage = "\(totalFailed) 个视频导出失败或跳过"
                }

                exportedFolder = url.path
                isExporting = false
            }
        }
    }

    /// 清理文件名中的非法字符
    private func sanitizeFilename(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: illegal).joined(separator: "_")
    }
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
