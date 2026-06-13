import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 批量导出分镜对话框：选择输出目录 → 列出文件 → 进度条 → 完成报告
struct BatchExportSheet: View {
    let segments: [Segment]
    let numberProvider: (Segment) -> Int

    @Environment(\.dismiss) private var dismiss

    @State private var outputDirectory: URL?
    @State private var isExporting = false
    @State private var progress: SegmentBatchExportProgress?
    @State private var didFinish = false
    @State private var exportTask: Task<Void, Never>?
    @AppStorage("lastBatchExportDir") private var lastDirPath: String = ""

    private let exportService = BatchSegmentExportService()

    private var items: [BatchExportItem] {
        segments.compactMap { seg in
            guard let video = seg.video else { return nil }
            let stem = (video.name as NSString).deletingPathExtension
            return BatchExportItem(
                id: seg.id,
                sourcePath: video.localPath,
                sourceVideoName: stem,
                startTime: seg.startTime,
                endTime: seg.endTime,
                sequenceNumber: numberProvider(seg),
                fps: video.fps
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 标题
            HStack {
                Image(systemName: "square.and.arrow.up.on.square")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accentColor)
                Text(didFinish ? "导出完成" : isExporting ? "导出中" : "批量导出 \(items.count) 个分镜")
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
                        .disabled(outputDirectory == nil || items.isEmpty)
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
                HStack {
                    Text("文件列表（\(items.count) 个）")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    let totalDur = items.reduce(0.0) { $0 + $1.duration }
                    Text(String(format: "总时长 %.1f 秒", totalDur))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { item in
                            HStack(spacing: 6) {
                                Image(systemName: "film")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                Text(item.fileName)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(String(format: "%.1fs", item.duration))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
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
                Text("H.264 硬件加速：每段从关键帧开始，无开头黑屏，速度快（每段约 0.3-1 秒）")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 进度视图

    private func progressView(_ p: SegmentBatchExportProgress) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(p.completedCount) / \(p.totalCount) 已完成")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(String(format: "%.0f%%", p.totalProgress * 100))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
            }

            ProgressView(value: p.totalProgress)

            if let current = p.currentItem {
                VStack(alignment: .leading, spacing: 2) {
                    Text("当前：\(current.fileName)")
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(String(format: "切片中 %.1f 秒", current.duration))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            if !p.failedItems.isEmpty {
                Text("⚠️ 失败 \(p.failedItems.count) 个")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - 结果视图

    private var resultView: some View {
        let p = progress ?? SegmentBatchExportProgress(totalCount: items.count, completedCount: items.count, currentItem: nil, currentItemProgress: 0, failedItems: [])
        let succeeded = p.totalCount - p.failedItems.count

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: p.failedItems.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(p.failedItems.isEmpty ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.failedItems.isEmpty ? "全部完成" : "部分完成")
                        .font(.system(size: 13, weight: .semibold))
                    Text("成功 \(succeeded) 个，失败 \(p.failedItems.count) 个")
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

            if !p.failedItems.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(p.failedItems.enumerated()), id: \.offset) { _, pair in
                            HStack {
                                Image(systemName: "xmark.circle")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.red)
                                Text(pair.0.fileName)
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
        progress = SegmentBatchExportProgress(totalCount: items.count, completedCount: 0, currentItem: items.first, currentItemProgress: 0, failedItems: [])

        let itemsCopy = items
        exportTask = Task {
            let result = await exportService.exportAll(
                items: itemsCopy,
                outputDirectory: dir,
                onProgress: { @MainActor p in
                    self.progress = p
                }
            )
            await MainActor.run {
                let final = SegmentBatchExportProgress(
                    totalCount: itemsCopy.count,
                    completedCount: result.succeeded + result.failed.count,
                    currentItem: nil,
                    currentItemProgress: 0,
                    failedItems: result.failed
                )
                self.progress = final
                self.isExporting = false
                self.didFinish = true

                if result.failed.isEmpty {
                    ToastCenter.shared.show("已导出 \(result.succeeded) 个分镜", icon: "checkmark.seal.fill", style: .success)
                } else {
                    ToastCenter.shared.show("导出 \(result.succeeded) 成功 / \(result.failed.count) 失败", icon: "exclamationmark.triangle.fill", style: .warning)
                }
            }
        }
    }
}
