import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 批量导出分镜对话框：选输出目录 → 列出文件（原版 + 各分镜变体）→ 进度 → 完成报告。
/// 每个选中分镜导出「1 原版 + 它全部已生成变体」；变体含克隆配音+BGM+烧录新字幕。
struct BatchExportSheet: View {
    let segments: [Segment]
    let numberProvider: (Segment) -> Int

    @Environment(\.dismiss) private var dismiss

    @State private var outputDirectory: URL?
    @State private var isExporting = false
    @State private var progress: VariantExportProgress?
    @State private var didFinish = false
    @State private var exportTask: Task<Void, Never>?
    @AppStorage("lastBatchExportDir") private var lastDirPath: String = ""

    private let exportService = VariantBatchExportService()

    private var jobs: [VariantExportJob] {
        VariantExportInput.from(segments: segments, numberProvider: numberProvider)
    }

    private var variantFileCount: Int {
        jobs.reduce(0) { acc, job in
            if case .variant = job { return acc + 1 }
            return acc
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 标题
            HStack {
                Image(systemName: "square.and.arrow.up.on.square")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accentColor)
                Text(didFinish ? "导出完成"
                     : isExporting ? "导出中"
                     : "批量导出 \(jobs.count) 个文件（含 \(variantFileCount) 个配音变体）")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }

            Divider()

            if didFinish {
                resultView
            } else if isExporting, let progress {
                progressView(progress)
            } else {
                configView
            }

            Divider()

            // 底部按钮
            HStack {
                if didFinish {
                    Button("在 Finder 中显示") {
                        if let dir = outputDirectory {
                            NSWorkspace.shared.activateFileViewerSelecting([dir])
                        }
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button("完成") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else if isExporting {
                    Spacer()
                    Button("取消") {
                        exportTask?.cancel()
                        dismiss()
                    }
                } else {
                    Spacer()
                    Button("取消") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("开始导出") { startExport() }
                        .buttonStyle(.borderedProminent)
                        .disabled(outputDirectory == nil || jobs.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .frame(minHeight: 380)
        .onAppear {
            if outputDirectory == nil, !lastDirPath.isEmpty,
               FileManager.default.fileExists(atPath: lastDirPath) {
                outputDirectory = URL(fileURLWithPath: lastDirPath)
            }
        }
    }

    // MARK: - 配置视图（选目录 + 文件列表）

    private var configView: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 选目录
            VStack(alignment: .leading, spacing: 4) {
                Text("输出目录")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack {
                    Text(outputDirectory?.path ?? "未选择")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(outputDirectory == nil ? .tertiary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("选择…") { pickOutputDirectory() }
                        .controlSize(.small)
                }
                .padding(8)
                .background(.quaternary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // 文件列表预览
            VStack(alignment: .leading, spacing: 4) {
                Text("文件列表（\(jobs.count) 个）")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(jobs.enumerated()), id: \.offset) { _, job in
                            HStack(spacing: 6) {
                                Image(systemName: isVariant(job) ? "waveform" : "film")
                                    .font(.system(size: 9))
                                    .foregroundStyle(isVariant(job) ? Color.accentColor : Color.secondary)
                                Text(job.fileName)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if isVariant(job) {
                                    Text("配音+字幕")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                        }
                    }
                }
                .frame(maxHeight: 180)
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // 编码说明
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                Text("原版流复制极快；变体走 H.264 硬件编码（克隆配音+BGM混音+烧录新字幕）")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func isVariant(_ job: VariantExportJob) -> Bool {
        if case .variant = job { return true }
        return false
    }

    // MARK: - 进度视图

    private func progressView(_ p: VariantExportProgress) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(p.completed) / \(p.total) 已完成")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(String(format: "%.0f%%", p.fraction * 100))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
            }

            ProgressView(value: p.fraction)

            if let name = p.currentName {
                Text("当前：\(name)")
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if !p.failed.isEmpty {
                Text("⚠️ 失败 \(p.failed.count) 个")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - 结果视图

    private var resultView: some View {
        let p = progress ?? VariantExportProgress(total: jobs.count, completed: jobs.count,
                                                  currentName: nil, failed: [])
        let succeeded = p.total - p.failed.count

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: p.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(p.failed.isEmpty ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.failed.isEmpty ? "全部完成" : "部分完成")
                        .font(.system(size: 13, weight: .semibold))
                    Text("成功 \(succeeded) 个，失败 \(p.failed.count) 个")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let dir = outputDirectory {
                Text("输出目录：\(dir.path)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if !p.failed.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(p.failed.enumerated()), id: \.offset) { _, pair in
                            HStack {
                                Image(systemName: "xmark.circle")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.red)
                                Text(pair.0)
                                    .font(.system(size: 10, design: .monospaced))
                                Spacer()
                                Text(pair.1)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .frame(maxHeight: 100)
                .padding(6)
                .background(.red.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - Actions

    private func pickOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择导出目录"
        if !lastDirPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: lastDirPath)
        }
        if panel.runModal() == .OK {
            outputDirectory = panel.url
            lastDirPath = panel.url?.path ?? ""
        }
    }

    private func startExport() {
        guard let dir = outputDirectory else { return }
        isExporting = true
        let jobsCopy = jobs
        progress = VariantExportProgress(total: jobsCopy.count, completed: 0,
                                         currentName: jobsCopy.first?.fileName, failed: [])
        exportTask = Task {
            let result = await exportService.exportAll(
                jobs: jobsCopy,
                outputDirectory: dir,
                onProgress: { @MainActor p in self.progress = p }
            )
            await MainActor.run {
                self.progress = VariantExportProgress(
                    total: jobsCopy.count, completed: result.succeeded + result.failed.count,
                    currentName: nil, failed: result.failed)
                self.isExporting = false
                self.didFinish = true
                if result.failed.isEmpty {
                    ToastCenter.shared.show("已导出 \(result.succeeded) 个文件", icon: "checkmark.seal.fill", style: .success)
                } else {
                    ToastCenter.shared.show("导出 \(result.succeeded) 成功 / \(result.failed.count) 失败", icon: "exclamationmark.triangle.fill", style: .warning)
                }
            }
        }
    }
}
