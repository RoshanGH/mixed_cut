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

    /// ⚠️ 只算一次。以前这是个计算属性，而 body 里引用它 5 处：
    /// 每次重绘（包括导出过程中每一次进度回调）都要遍历一遍 SwiftData 关系、
    /// 对每个变体做一次 `FileManager.fileExists`，全在主线程上。
    @State private var jobs: [VariantExportJob] = []
    /// 缺源视频、无法导出的分镜编号
    @State private var skippedNumbers: [Int] = []

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
                    .font(DesignTokens.Typography.title)
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
        .padding(DesignTokens.Padding.page)
        .frame(width: 520)
        .frame(minHeight: 380)
        .onAppear {
            if outputDirectory == nil, !lastDirPath.isEmpty,
               FileManager.default.fileExists(atPath: lastDirPath) {
                outputDirectory = URL(fileURLWithPath: lastDirPath)
            }
            // 任务清单只在打开弹窗时算一次（选中的分镜在弹窗打开期间不会变）
            jobs = VariantExportInput.from(segments: segments, numberProvider: numberProvider)
            skippedNumbers = VariantExportInput.skippedSegmentNumbers(segments: segments,
                                                                     numberProvider: numberProvider)
        }
    }

    // MARK: - 配置视图（选目录 + 文件列表）

    private var configView: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 选目录
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.tight) {
                Text("输出目录")
                    .font(DesignTokens.Typography.captionEmphasis)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(outputDirectory?.path ?? "未选择")
                        .font(DesignTokens.Typography.labelMono)
                        .foregroundStyle(outputDirectory == nil ? .tertiary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("选择…") { pickOutputDirectory() }
                        .controlSize(.small)
                }
                .padding(8)
                .background(.quaternary.opacity(DesignTokens.Palette.Alpha.medium))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            // 被跳过的分镜必须说清楚，否则"选了 20 个却只导出 18 个"用户完全无从察觉
            if !skippedNumbers.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignTokens.Palette.Status.warning)
                    Text("分镜 \(skippedNumbers.map(String.init).joined(separator: "、")) 找不到源视频（可能已被删除），将被跳过，不会出现在导出结果里。")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(DesignTokens.Typography.caption)
                .padding(DesignTokens.Spacing.compact)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignTokens.Palette.Status.warning.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: DesignTokens.Corner.small, style: .continuous))
            }

            // 文件列表预览
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.tight) {
                Text("文件列表（\(jobs.count) 个）")
                    .font(DesignTokens.Typography.captionEmphasis)
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(jobs.enumerated()), id: \.offset) { _, job in
                            HStack(spacing: 6) {
                                Image(systemName: isVariant(job) ? "waveform" : "film")
                                    .font(DesignTokens.Typography.microRegular)
                                    .foregroundStyle(isVariant(job) ? Color.accentColor : Color.secondary)
                                Text(job.fileName)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if isVariant(job) {
                                    Text("配音+字幕")
                                        .font(DesignTokens.Typography.microRegular)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                        }
                    }
                }
                .frame(maxHeight: 180)
                .background(.quaternary.opacity(DesignTokens.Palette.Alpha.medium))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            // 编码说明
            HStack(spacing: DesignTokens.Spacing.tight) {
                Image(systemName: "bolt.fill")
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.orange)
                Text("原版流复制极快；变体走 H.264 硬件编码（克隆配音+BGM混音+烧录新字幕）")
                    .font(DesignTokens.Typography.microRegular)
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
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.normal) {
            HStack {
                Text("\(p.completed) / \(p.total) 已完成")
                    .font(DesignTokens.Typography.labelStrong)
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
                    .font(DesignTokens.Typography.caption)
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
                        .font(DesignTokens.Typography.bodyEmphasis)
                    Text("成功 \(succeeded) 个，失败 \(p.failed.count) 个")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let dir = outputDirectory {
                Text("输出目录：\(dir.path)")
                    .font(DesignTokens.Typography.microMono)
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
                                    .font(DesignTokens.Typography.microRegular)
                                    .foregroundStyle(.red)
                                Text(pair.0)
                                    .font(DesignTokens.Typography.microMono)
                                Spacer()
                                Text(pair.1)
                                    .font(DesignTokens.Typography.microRegular)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .frame(maxHeight: 100)
                .padding(6)
                .background(.red.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
