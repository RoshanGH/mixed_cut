import SwiftUI
import AVFoundation

/// 逐句字幕时间编辑器（弹窗）：文本只读、只调时间；点句播对应配音段；可一键重新自动对齐。
/// 见 spec 2026-07-09-per-sentence-subtitle-timing-design.md §5。
struct CaptionTimingEditorSheet: View {
    let dub: SegmentDub
    @Bindable var dubVM: DubbingViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var lines: [CaptionLine] = []
    @State private var player: AVAudioPlayer?
    @State private var playingIndex: Int?
    @State private var stopToken = 0
    @State private var confirmRealign = false
    @State private var isRealigning = false
    @State private var splittingIndex: Int?      // 正处于「拆分模式」的句子下标
    /// 对齐/试听等操作的失败说明。非 nil 时弹 alert —— 这类操作以前失败是完全静默的，
    /// 用户点了没反应只会以为按钮坏了。
    @State private var realignMessage: String?

    private var segDuration: Double { dub.segment?.duration ?? 0 }
    private let step = 0.1

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if lines.isEmpty {
                Spacer()
                Text(isRealigning ? "正在对齐…" : "还没有逐句字幕数据")
                    .foregroundStyle(.secondary).font(.callout)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: DesignTokens.Spacing.compact) {
                        ForEach(lines.indices, id: \.self) { i in
                            row(i)
                        }
                    }
                    .padding(14)
                }
            }
            Divider()
            footer
        }
        .frame(width: 460, height: 560)
        .task(id: dub.id) { lines = dub.captionLines }
        .onDisappear { player?.stop() }
        .confirmationDialog("重新自动对齐？", isPresented: $confirmRealign) {
            Button("重新对齐（覆盖当前时间）", role: .destructive) { Task { await realign() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将用配音重新识别每句时间，覆盖你手动调过的时间。文本不变。")
        }
        .alert("字幕对齐", isPresented: Binding(
            get: { realignMessage != nil },
            set: { if !$0 { realignMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { realignMessage = nil }
        } message: {
            Text(realignMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.compact) {
            Image(systemName: "captions.bubble.fill").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("逐句字幕时间").font(.headline)
                Text("改写版 \(Character(UnicodeScalar(65 + dub.textVariantIndex)!)) · 分镜时长 \(String(format: "%.1f", segDuration))s")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("关闭") { dismiss() }
                .keyboardShortcut(.cancelAction)   // Esc 关闭（macOS sheet 默认不响应 Esc，必须显式挂）
        }
        .padding(DesignTokens.Spacing.normal)
    }

    private func row(_ i: Int) -> some View {
        let playing = playingIndex == i
        return HStack(alignment: .top, spacing: 10) {
            // 播放/序号
            Button {
                playLine(i)
            } label: {
                Image(systemName: playing ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title3).foregroundStyle(playing ? .red : .green)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(playing ? "停止试听" : "试听这句")
            .help("试听这句配音")

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: DesignTokens.Spacing.compact) {
                    if splittingIndex == i {
                        splitEditor(i)
                    } else {
                        Text(lines[i].text.isEmpty ? "（空）" : lines[i].text)
                            .font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    splitToggle(i)
                }
                HStack(spacing: DesignTokens.Spacing.normal) {
                    timeStepper("起", value: lines[i].start) { setStart(i, $0) }
                    timeStepper("止", value: lines[i].end) { setEnd(i, $0) }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(.controlBackgroundColor).opacity(playing ? 0.9 : 0.5)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.separator, lineWidth: 0.5))
    }

    private func timeStepper(_ label: String, value: Double, _ set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: DesignTokens.Spacing.tight) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            Button { set(value - step) } label: { Image(systemName: "minus") }
                .buttonStyle(.borderless).controlSize(.small)
                .accessibilityLabel("\(label)时间提前")
            Text(String(format: "%.1fs", value))
                .font(DesignTokens.Typography.labelMono).frame(width: 44)
            Button { set(value + step) } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless).controlSize(.small)
                .accessibilityLabel("\(label)时间延后")
        }
    }

    // MARK: - 手动拆分句子（剪刀模式）

    /// ✂ 开关：进入/退出拆分模式。少于 2 字不能拆，按钮禁用。
    private func splitToggle(_ i: Int) -> some View {
        let canSplit = CaptionBoundaryEditor.charsOf(lines[i]).count >= 2
        let active = splittingIndex == i
        return Button {
            splittingIndex = active ? nil : i
        } label: {
            Image(systemName: active ? "xmark.circle.fill" : "scissors")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(active ? Color.secondary : (canSplit ? Color.accentColor : Color.secondary.opacity(0.4)))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(active ? "取消拆分" : "拆分句子")
        .disabled(!canSplit)
        .help(active ? "退出拆分" : (canSplit ? "拆分这一句：点两字之间的竖线切开" : "只有一个字，无法拆分"))
    }

    /// 拆分模式：逐字块 + 字间可点竖线（点竖线 = 在该处拆成两句）。
    private func splitEditor(_ i: Int) -> some View {
        let cs = CaptionBoundaryEditor.charsOf(lines[i])
        return WrapHStack(spacing: 2) {
            ForEach(cs.indices, id: \.self) { k in
                Text(cs[k].ch)
                    .font(.callout)
                    .padding(.vertical, 2).padding(.horizontal, 1)
                // 字之间的分界（末字后不放，避免拆出空句）
                if k < cs.count - 1 {
                    Button { splitLine(i, afterCharIndex: k) } label: {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(Color.accentColor)
                            .frame(width: 3, height: 18)
                            .padding(.horizontal, 2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("在此拆成两句")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 执行拆分：在第 i 句第 k 字后切开，写库，退出拆分模式。
    private func splitLine(_ i: Int, afterCharIndex k: Int) {
        let next = CaptionBoundaryEditor.splitLine(lines, at: i, afterCharIndex: k)
        guard next.count != lines.count else { splittingIndex = nil; return }
        lines = next
        splittingIndex = nil
        persist()
    }

    private var footer: some View {
        HStack {
            Button {
                confirmRealign = true
            } label: {
                Label("重新自动对齐", systemImage: "wand.and.stars")
            }
            .disabled(isRealigning)
            Spacer()
            Text("字幕文字要改？去改这版台词（会重新配音并重新对齐）")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(DesignTokens.Spacing.normal)
    }

    // MARK: - 编辑（即时写库，带约束）

    private let minGap = 0.05

    // 「起」= 与上一句的分界；「止」= 与下一句的分界。动分界 → 字按时间在相邻句间迁移/合并（联动）。
    private func setStart(_ i: Int, _ v: Double) {
        if i > 0 {
            moveBoundary(after: i - 1, to: v)           // 第 i 句的起 = 第 i-1 句的止（同一分界）
        } else {
            // 首句起：只调它自己的显示起点（无上一句可交换），clamp [0, 止-gap]
            lines[0].start = min(max(0, v), lines[0].end - minGap)
            persist()
        }
    }

    private func setEnd(_ i: Int, _ v: Double) {
        if i + 1 < lines.count {
            moveBoundary(after: i, to: v)               // 第 i 句的止 = 第 i+1 句的起（同一分界）
        } else {
            // 末句止：只调显示止点，clamp [起+gap, 分镜时长]
            lines[i].end = min(max(lines[i].start + minGap, v), segDuration)
            persist()
        }
    }

    /// 移动第 i 句与第 i+1 句之间的分界到时间 t（联动合并/迁移），委托纯函数 CaptionBoundaryEditor。
    private func moveBoundary(after i: Int, to t: Double) {
        let next = CaptionBoundaryEditor.moveBoundary(lines, after: i, to: t, minGap: minGap)
        guard next.count != lines.count || next != lines else { return }
        lines = next
        persist()
    }

    private func persist() {
        dub.captionLines = lines
        // 保存失败必须提示：否则界面显示新时间、库里还是旧值，
        // 之后烧录字幕用的是旧时间，用户拿到成片才发现对不上。
        modelContext.saveOrWarn("字幕时间")
    }

    private func realign() async {
        isRealigning = true
        // 用户可能已经逐句手调过时间：ASR 跑不通时**不允许**用估算值覆盖，宁可什么都不改并说明原因
        let outcome = await dubVM.alignCaptions(for: dub, context: modelContext,
                                                allowApproximation: false)
        lines = dub.captionLines
        isRealigning = false

        switch outcome {
        case .aligned:
            ToastCenter.shared.show("已按语音重新对齐 \(lines.count) 句字幕",
                                    icon: "checkmark.seal.fill", style: .success)
        case .approximated(let reason):
            realignMessage = "已按字数比例估算字幕时间（精度有限）。\n语音识别未成功：\(reason)"
        case .skipped(let reason):
            realignMessage = reason
        }
    }

    // MARK: - 播放某句音频段（纯音频，不用视频播放器避免黑屏）

    private func playLine(_ i: Int) {
        player?.stop()
        stopToken += 1
        if playingIndex == i { playingIndex = nil; return }
        // 试听失败以前是完全静默的：点播放键毫无反应，用户只会以为按钮坏了
        guard let path = dub.audioFilePath else {
            realignMessage = "这一版还没有生成配音音频，无法试听。请先在分镜卡片上生成配音。"
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            realignMessage = "配音音频文件已丢失（可能被清理或手动删除）。请重新生成这一版配音后再试听。"
            return
        }
        let p: AVAudioPlayer
        do {
            p = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
        } catch {
            realignMessage = "配音音频无法播放：\(FriendlyError.reason(for: error))\n建议重新生成这一版配音。"
            return
        }
        let line = lines[i]
        p.currentTime = max(0, line.start)
        p.play()
        player = p
        playingIndex = i
        let dur = max(0.1, line.end - line.start)
        let myToken = stopToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(dur * 1_000_000_000))
            if myToken == stopToken { player?.stop(); playingIndex = nil }
        }
    }
}
