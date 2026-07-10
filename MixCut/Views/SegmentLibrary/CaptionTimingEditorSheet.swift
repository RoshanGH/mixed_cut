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
                    VStack(spacing: 8) {
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
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "captions.bubble.fill").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("逐句字幕时间").font(.headline)
                Text("改写版 \(Character(UnicodeScalar(65 + dub.textVariantIndex)!)) · 分镜时长 \(String(format: "%.1f", segDuration))s")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("关闭") { dismiss() }
        }
        .padding(12)
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
            .help("试听这句配音")

            VStack(alignment: .leading, spacing: 6) {
                Text(lines[i].text.isEmpty ? "（空）" : lines[i].text)
                    .font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 12) {
                    timeStepper("起", value: lines[i].start) { setStart(i, $0) }
                    timeStepper("止", value: lines[i].end) { setEnd(i, $0) }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.controlBackgroundColor).opacity(playing ? 0.9 : 0.5)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
    }

    private func timeStepper(_ label: String, value: Double, _ set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            Button { set(value - step) } label: { Image(systemName: "minus") }
                .buttonStyle(.borderless).controlSize(.small)
            Text(String(format: "%.1fs", value))
                .font(.system(size: 12, design: .monospaced)).frame(width: 44)
            Button { set(value + step) } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless).controlSize(.small)
        }
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
        .padding(12)
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
        try? modelContext.save()
    }

    private func realign() async {
        isRealigning = true
        await dubVM.alignCaptions(for: dub, context: modelContext)
        lines = dub.captionLines
        isRealigning = false
    }

    // MARK: - 播放某句音频段（纯音频，不用视频播放器避免黑屏）

    private func playLine(_ i: Int) {
        player?.stop()
        stopToken += 1
        if playingIndex == i { playingIndex = nil; return }
        guard let path = dub.audioFilePath,
              let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else { return }
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
