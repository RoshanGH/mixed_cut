import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// 全局 BGM 库：上传 / 试听 / 删除。所有项目共享；导出成片时从这里选一条铺底。
struct BGMLibraryView: View {
    @State private var store = BGMLibraryStore()
    @State private var isImporterPresented = false
    /// 正在试听的 BGM 路径（nil = 没在播）
    @State private var playingPath: String?
    @State private var player: AVAudioPlayer?
    /// 待确认删除的 BGM
    @State private var trackPendingDelete: BGMTrack?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.generous) {
                    header
                    if store.tracks.isEmpty {
                        emptyState
                    } else {
                        trackList
                    }
                }
                .padding(DesignTokens.Padding.page)
                .frame(maxWidth: 860)
            }
            .frame(maxWidth: .infinity)
        }
        .task { await store.reload() }
        .onDisappear { stopPreview() }
        .fileImporter(isPresented: $isImporterPresented,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { result in
            handleImport(result)
        }
        .confirmationDialog("删除这条 BGM？",
                            isPresented: Binding(get: { trackPendingDelete != nil },
                                                 set: { if !$0 { trackPendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("删除「\(trackPendingDelete?.name ?? "")」", role: .destructive) {
                if let track = trackPendingDelete { deleteTrack(track) }
            }
            Button("取消", role: .cancel) { trackPendingDelete = nil }
        } message: {
            Text("删除后无法恢复。已导出的视频不受影响。")
        }
        .navigationTitle("BGM 库")
    }

    // MARK: - 头部

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("BGM 库")
                    .font(DesignTokens.Typography.headline)
                Text("全部项目共享。在「导出」页选一条 BGM，即可去除成片原 BGM、只留口播并铺上所选音乐。")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                isImporterPresented = true
            } label: {
                Label("上传 BGM", systemImage: "plus")
                    .font(DesignTokens.Typography.labelEmphasis)
            }
            .buttonStyle(.borderedProminent)
            .help("支持 MP3 等常见音频格式，可多选")
        }
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.normal) {
            Image(systemName: "music.note.list")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("还没有 BGM")
                .font(DesignTokens.Typography.bodyLargeEmphasis)
            Text("点击右上角「上传 BGM」添加音乐文件（MP3 等）")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    // MARK: - 列表

    private var trackList: some View {
        VStack(spacing: 0) {
            ForEach(store.tracks) { track in
                trackRow(track)
                Divider().padding(.leading, 44)
            }
        }
        .background(.quaternary.opacity(DesignTokens.Palette.Alpha.subtle * 2))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.medium, style: DesignTokens.Corner.style))
    }

    private func trackRow(_ track: BGMTrack) -> some View {
        let isPlaying = playingPath == track.path
        return HStack(spacing: DesignTokens.Spacing.normal) {
            Button {
                togglePreview(track)
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(isPlaying ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(isPlaying ? "暂停试听" : "试听")

            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(DesignTokens.Typography.label)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text(track.durationText)
                    .font(DesignTokens.Typography.microRounded)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                trackPendingDelete = track
            } label: {
                Image(systemName: "trash")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("删除")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // MARK: - 行为

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            ToastCenter.shared.show("选择文件失败：\(error.localizedDescription)",
                                    icon: "exclamationmark.triangle.fill", style: .error)
        case .success(let urls):
            guard !urls.isEmpty else { return }
            Task { @MainActor in
                let failures = await store.importFiles(urls: urls)
                let succeeded = urls.count - failures.count
                if failures.isEmpty {
                    ToastCenter.shared.show("已添加 \(succeeded) 条 BGM",
                                            icon: "checkmark.seal.fill", style: .success)
                } else {
                    // 失败明细不吞：逐条列出文件名和原因
                    let detail = failures.map { "\($0.name)：\($0.reason)" }.joined(separator: "\n")
                    ToastCenter.shared.show("成功 \(succeeded) 条，失败 \(failures.count) 条\n\(detail)",
                                            icon: "exclamationmark.triangle.fill", style: .warning)
                }
            }
        }
    }

    private func deleteTrack(_ track: BGMTrack) {
        if playingPath == track.path { stopPreview() }
        trackPendingDelete = nil
        Task { @MainActor in
            if let reason = await store.delete(track) {
                ToastCenter.shared.show(reason, icon: "exclamationmark.triangle.fill", style: .error)
            } else {
                ToastCenter.shared.show("已删除「\(track.name)」", icon: "trash", style: .info)
            }
        }
    }

    private func togglePreview(_ track: BGMTrack) {
        if playingPath == track.path {
            stopPreview()
            return
        }
        stopPreview()
        do {
            let p = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: track.path))
            p.play()
            player = p
            playingPath = track.path
        } catch {
            ToastCenter.shared.show("无法播放「\(track.name)」：\(error.localizedDescription)",
                                    icon: "exclamationmark.triangle.fill", style: .error)
        }
    }

    private func stopPreview() {
        player?.stop()
        player = nil
        playingPath = nil
    }
}
