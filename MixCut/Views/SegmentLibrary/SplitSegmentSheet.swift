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
    /// 拆分失败原因。非 nil 时留在弹窗里展示，而不是默默关闭。
    @State private var splitError: String?

    /// 分镜是否短到根本没有合法拆分点（前后各要留 0.3s）。
    /// 太短时 `lo == hi`，Slider 拿到零宽区间会算出 NaN 布局，必须在 UI 上直接拦掉。
    private var isTooShortToSplit: Bool { hi <= lo }

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
            VStack(spacing: DesignTokens.Spacing.normal) {
                if let player {
                    FramePreview(player: player)
                        .aspectRatio(9.0 / 16.0, contentMode: .fit)
                        .frame(maxHeight: 320)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                Text("拆分点：\(String(format: "%.1f", Double(cutFrame - startFrame) / fps))s · 第 \(cutFrame - startFrame) 帧")
                    .font(.system(size: 13, design: .monospaced))
                // 分镜太短时区间会退化成一个点，Slider 内部除以区间长度会产生 NaN 布局
                if isTooShortToSplit {
                    Text("这个分镜只有 \(String(format: "%.1f", segment.duration))s，拆开后每段不足 0.3 秒，无法再拆分。")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                } else {
                    Slider(
                        value: Binding(
                            get: { Double(cutFrame) },
                            set: { cutFrame = Int($0.rounded()); seek() }
                        ),
                        in: Double(lo)...Double(hi)
                    )
                    .tint(.red)
                }
                HStack {
                    Text("0:00 · 第0帧").font(DesignTokens.Typography.microRegular).foregroundStyle(.tertiary)
                    Spacer()
                    Text("\(String(format: "%.1f", segment.duration))s · 第 \(endFrame - startFrame) 帧")
                        .font(DesignTokens.Typography.microRegular).foregroundStyle(.tertiary)
                }
                Text("拆分后是两个新分镜，原配音 / 画面重绘等将清空、不可恢复")
                    .font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let splitError {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(splitError)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(DesignTokens.Typography.caption)
                    .padding(DesignTokens.Spacing.compact)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: DesignTokens.Corner.small, style: .continuous))
                }
            }
            .padding(DesignTokens.Spacing.comfortable)
            Divider()
            footer
        }
        .frame(width: 440)
        .onAppear(perform: setup)
        .onDisappear { player?.pause() }
    }

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.compact) {
            Image(systemName: "scissors").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("拆分分镜").font(.headline)
                Text("原分镜 · 时长 \(String(format: "%.1f", segment.duration))s")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(DesignTokens.Spacing.normal)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)   // Esc 关闭（macOS sheet 默认不响应 Esc，必须显式挂）
                .disabled(isSplitting)
            Button(isSplitting ? "拆分中…" : "确定拆分") { doSplit() }
                .buttonStyle(.borderedProminent)
                .disabled(isSplitting || isTooShortToSplit)
        }
        .padding(DesignTokens.Spacing.normal)
    }

    private func setup() {
        guard let path = segment.video?.localPath else { return }
        let p = AVPlayer(url: URL(fileURLWithPath: path))
        p.isMuted = true
        player = p
        // 中点必须夹到合法区间内，否则短分镜下初值会落在 Slider 区间之外
        cutFrame = min(max((startFrame + endFrame) / 2, lo), max(lo, hi))
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
            let outcome = await importVM.splitSegment(segment, atFrame: target) { onSplit() }
            isSplitting = false
            // 只有真的拆成功才关窗。以前不管成败一律 dismiss，
            // 失败时用户看到弹窗正常关闭、列表却毫无变化，完全不知道出了什么事。
            switch outcome {
            case .success:
                ToastCenter.shared.show("已拆分为两个分镜", icon: "checkmark.seal.fill", style: .success)
                dismiss()
            case .successWithWarning(let warning):
                ToastCenter.shared.show(warning, icon: "exclamationmark.triangle.fill",
                                        style: .warning, duration: 6)
                dismiss()
            case .failed(let reason):
                splitError = reason   // 留在弹窗里把原因讲清楚
            }
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
