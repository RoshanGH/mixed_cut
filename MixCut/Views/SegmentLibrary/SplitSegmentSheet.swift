import SwiftUI
import AVFoundation
import AppKit

/// 分镜拆分弹窗：画面预览（9:16）+ 拖轴到某帧 + 确定切成两段。见 PRD/TRD 06。
struct SplitSegmentSheet: View {
    let segment: Segment
    @Bindable var importVM: ImportViewModel
    let onSplit: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var cutFrame: Int = 0
    @State private var isSplitting = false

    private var fps: Double {
        let f = segment.video?.fps ?? 30
        return f > 0 ? f : 30
    }
    private var startFrame: Int { segment.startFrame }
    private var endFrame: Int { segment.endFrame }
    private var minFrames: Int { max(1, Int((0.3 * fps).rounded())) }   // 每段 ≥ 0.3s
    private var lo: Int { startFrame + minFrames }
    private var hi: Int { max(startFrame + minFrames, endFrame - minFrames) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(spacing: 12) {
                if let player {
                    FramePreview(player: player)
                        .aspectRatio(9.0 / 16.0, contentMode: .fit)
                        .frame(maxHeight: 320)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Text("拆分点：\(String(format: "%.1f", Double(cutFrame - startFrame) / fps))s · 第 \(cutFrame - startFrame) 帧")
                    .font(.system(size: 13, design: .monospaced))
                Slider(
                    value: Binding(
                        get: { Double(cutFrame) },
                        set: { cutFrame = Int($0.rounded()); seek() }
                    ),
                    in: Double(lo)...Double(hi)
                )
                .tint(.red)
                HStack {
                    Text("0:00 · 第0帧").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                    Text("\(String(format: "%.1f", segment.duration))s · 第 \(endFrame - startFrame) 帧")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Text("拆分后是两个新分镜，原配音 / 画面重绘等将清空、不可恢复")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
            Divider()
            footer
        }
        .frame(width: 440)
        .onAppear(perform: setup)
        .onDisappear { player?.pause() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "scissors").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("拆分分镜").font(.headline)
                Text("原分镜 · 时长 \(String(format: "%.1f", segment.duration))s")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("取消") { dismiss() }
                .disabled(isSplitting)
            Button(isSplitting ? "拆分中…" : "确定拆分") { doSplit() }
                .buttonStyle(.borderedProminent)
                .disabled(isSplitting)
        }
        .padding(12)
    }

    private func setup() {
        guard let path = segment.video?.localPath else { return }
        let p = AVPlayer(url: URL(fileURLWithPath: path))
        p.isMuted = true
        player = p
        cutFrame = (startFrame + endFrame) / 2
        seek()
    }

    private func seek() {
        // 相对源视频的绝对帧 → 时间；零容差精确到帧
        player?.seek(to: CMTime(seconds: Double(cutFrame) / fps, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func doSplit() {
        isSplitting = true
        let target = cutFrame
        Task { @MainActor in
            await importVM.splitSegment(segment, atFrame: target) { onSplit() }
            isSplitting = false
            dismiss()
        }
    }
}

/// 静帧预览：包 AVPlayerLayer，只显示 seek 到的画面（不播放）
private struct FramePreview: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        v.layer = layer
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        if let layer = nsView.layer as? AVPlayerLayer {
            layer.player = player
        }
    }
}
