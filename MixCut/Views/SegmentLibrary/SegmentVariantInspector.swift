import SwiftUI

/// 右侧变体池矩阵：行 = 改写版（0..K-1），列 = 选定音色，格 = 按需配音（生成 / 试听 / 重生成）。
struct SegmentVariantInspector: View {
    let segment: Segment
    @Bindable var dubVM: DubbingViewModel
    @Environment(\.modelContext) private var modelContext

    // 改写版台词行内编辑
    @State private var editingVariant: Int? = nil
    @State private var draftText = ""
    @State private var variantPendingDelete: Int? = nil
    @FocusState private var editorFocused: Bool

    private func variantLetter(_ t: Int) -> String { String(Character(UnicodeScalar(65 + t)!)) }

    private var voices: [String] { segment.video?.selectedVoiceIds ?? [] }
    /// 实际已存在的改写版下标（升序），按它渲染变体卡片，数量随设置自适应。
    private var presentVariantIndices: [Int] {
        Array(Set(segment.segmentDubs.map { $0.textVariantIndex })).sorted()
    }
    private func voiceName(_ id: String) -> String {
        if id == segment.video?.clonedVoiceId { return "原声克隆" }
        return VoiceCatalog.displayName(id: id)
    }
    private func dub(textVariant t: Int, voiceId v: String) -> SegmentDub? {
        segment.segmentDubs.first { $0.textVariantIndex == t && $0.voiceId == v }
    }
    /// 该改写版参与组合用的"有效变体"（已生成音频、去重后那条）
    private func effectiveDub(_ t: Int) -> SegmentDub? {
        segment.effectiveDubVariants.first { $0.textVariantIndex == t }
    }
    private func f(_ x: Double) -> String { String(format: "%.1f", x) }

    /// 提示基准 = 原分镜台词字数。比原台词多很多才算「偏多」（阈值：+20% 且至少 +5 字）。
    private var origCharCount: Int { segment.text.count }
    private func isTooMany(_ count: Int) -> Bool {
        origCharCount > 0 && count > origCharCount + max(5, Int(Double(origCharCount) * 0.2))
    }
    /// 比原台词少很多（阈值：少于原台词一半）→ 配音可能短于画面、末尾留白。
    private func isTooFew(_ count: Int) -> Bool {
        origCharCount > 0 && count < max(2, origCharCount / 2)
    }

    private func isStale(_ dub: SegmentDub) -> Bool {
        guard dub.audioFilePath != nil else { return false }
        let snap = DubSnapshot(recordedStartFrame: dub.generatedForStartFrame,
                               recordedEndFrame: dub.generatedForEndFrame,
                               recordedTextHash: dub.generatedForTextHash)
        if case .stale = DubStaleness.check(snapshot: snap,
                                            currentStartFrame: segment.startFrame,
                                            currentEndFrame: segment.endFrame,
                                            currentTextHash: DubStaleness.textHash(of: dub.rewrittenText)) {
            return true
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 340)
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("删除改写版？",
                            isPresented: Binding(get: { variantPendingDelete != nil },
                                                 set: { if !$0 { variantPendingDelete = nil } }),
                            presenting: variantPendingDelete) { t in
            Button("删除「改写版 \(variantLetter(t))」", role: .destructive) {
                dubVM.deleteVariant(segment, textVariantIndex: t, context: modelContext)
                if editingVariant == t { editingVariant = nil }
                variantPendingDelete = nil
            }
            Button("取消", role: .cancel) { variantPendingDelete = nil }
        } message: { t in
            Text("将删除「改写版 \(variantLetter(t))」的台词与配音，不可恢复。")
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text("配音变体池").font(.headline)
            }
            Text("分镜 #\(segment.segmentIndex) · 时长 \(String(format: "%.1f", segment.duration))s")
                .font(.caption).foregroundStyle(.secondary)
            if !segment.isVoiceLocked {
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(
                        get: { segment.originalParticipatesInCombination },
                        set: { segment.originalParticipatesInCombination = $0; try? modelContext.save() }
                    )) { Text("原版参与组合").font(.caption2) }
                    .toggleStyle(.checkbox)
                    .help("勾选后原版参与导出排列组合；与各改写版的「参与组合」共同决定组合数")
                    Spacer()
                    Text("参与 \(segment.combinationSlotCount) 档")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if segment.isVoiceLocked {
            emptyHint(icon: "lock.fill",
                      text: "保留原声\n（明星出镜锁定，不参与配音）",
                      color: .orange)
        } else if segment.segmentDubs.isEmpty {
            VStack(spacing: 14) {
                emptyHint(icon: "wand.and.stars",
                          text: "点顶部「一键改写台词」自动克隆原声并生成配音\n或在下方手动添加一版自己写台词",
                          color: .secondary)
                addManualVariantButton.padding(.horizontal, 14)
            }
        } else {
            matrix
        }
    }

    private func emptyHint(icon: String, text: String, color: Color) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(color)
            Text(text).font(.callout).foregroundStyle(color)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var matrix: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                rewriteBar
                ForEach(presentVariantIndices, id: \.self) { t in
                    versionCard(t)
                }
                addManualVariantButton
            }
            .padding(14)
        }
    }

    /// 手动新增一版：自己写台词 → 自动用克隆原声配音。
    @ViewBuilder
    private var addManualVariantButton: some View {
        if !dubVM.isBusy(videoID: segment.video?.id) {
            Button {
                Task {
                    if let newIndex = await dubVM.addManualVariant(for: segment, context: modelContext) {
                        draftText = ""
                        editingVariant = newIndex
                        editorFocused = true
                    }
                }
            } label: {
                Label("手动添加一版（自己写台词）", systemImage: "plus.circle")
                    .font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .help("新增一个空白改写版，自己填台词，保存后自动用克隆原声生成配音")
        }
    }

    /// 单分镜「重新改写」入口（改完原台词后用）。
    private var rewriteBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if dubVM.isBusy(videoID: segment.video?.id) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(dubVM.progressText(videoID: segment.video?.id)).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task { await dubVM.rewriteSegment(segment, context: modelContext) }
                } label: {
                    Label("重新改写本分镜", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("基于当前原台词，重出 \(dubVM.variantCount) 套改写版并重新生成配音")
            }
            Text("改了原台词后，点此用新原文重写本分镜")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 单个改写版卡片

    private func versionCard(_ t: Int) -> some View {
        let text = dub(textVariant: t, voiceId: voices.first ?? "")?.rewrittenText ?? ""
        let editing = editingVariant == t
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("改写版 \(Character(UnicodeScalar(65 + t)!))")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
                charHint(count: editing ? draftText.count : text.count)
                // 参与导出组合勾选（仅该版已生成音频时显示；锁定原声时禁用）
                if let ed = effectiveDub(t) {
                    Toggle(isOn: Binding(
                        get: { ed.participatesInCombination },
                        set: { ed.participatesInCombination = $0; try? modelContext.save() }
                    )) {
                        Text("参与组合").font(.caption2)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(segment.isVoiceLocked)
                    .help(segment.isVoiceLocked ? "已锁原声，不参与组合" : "勾选后此改写版参与导出排列组合")
                }
                Spacer()
                if editing {
                    Button { editingVariant = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                    }.buttonStyle(.borderless).foregroundStyle(.secondary).help("取消")
                    Button { saveEditedVariant(t) } label: {
                        Image(systemName: "checkmark.circle.fill")
                    }.buttonStyle(.borderless).foregroundStyle(.green).help("保存并重新生成配音（⌘↩）")
                } else if !dubVM.isBusy(videoID: segment.video?.id) {
                    Button {
                        draftText = text
                        editingVariant = t
                        editorFocused = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }.buttonStyle(.borderless).foregroundStyle(.secondary).help("编辑这版台词")
                    Button {
                        variantPendingDelete = t
                    } label: {
                        Image(systemName: "trash")
                    }.buttonStyle(.borderless).foregroundStyle(.red).help("删除这版（台词+配音）")
                }
            }

            if editing {
                TextEditor(text: $draftText)
                    .font(.callout)
                    .frame(height: 80)
                    .focused($editorFocused)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor.opacity(0.5), lineWidth: 1))
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.command) { saveEditedVariant(t); return .handled }
                        return .ignored
                    }
            } else {
                Text(text.isEmpty ? "（无文本）" : text)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.9))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            variantAudioWarning(t)

            // 音色格：每列一个音色
            HStack(spacing: 8) {
                ForEach(voices, id: \.self) { v in
                    cell(textVariant: t, voiceId: v)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
    }

    /// 字数提示（基准=原分镜台词）：仅在比原台词「多很多」红字、「少很多」橙字；其余灰字不打扰。
    @ViewBuilder
    private func charHint(count: Int) -> some View {
        let many = isTooMany(count)
        let few = isTooFew(count)
        HStack(spacing: 3) {
            Text("\(count)字").font(.caption2.monospacedDigit())
                .foregroundStyle(many ? AnyShapeStyle(Color.red)
                                 : few ? AnyShapeStyle(Color.orange)
                                 : AnyShapeStyle(.tertiary))
            if origCharCount > 0 {
                if many {
                    Text("· 比原台词(\(origCharCount)字)多很多，配音会明显加速，建议精简")
                        .font(.caption2).foregroundStyle(.red)
                } else if few {
                    Text("· 比原台词(\(origCharCount)字)少很多，末尾会留白，建议加字")
                        .font(.caption2).foregroundStyle(.orange)
                } else {
                    Text("/ 原\(origCharCount)字").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// 生成后时长警告（只有两种）：① 字数比原片多很多→红字；② 配音确实短于画面（留白）→橙字。
    /// 台词多但仍被 atempo 加速塞进画面属正常，不报「超时」。
    @ViewBuilder
    private func variantAudioWarning(_ t: Int) -> some View {
        if let d = dub(textVariant: t, voiceId: voices.first ?? ""),
           d.audioFilePath != nil, d.audioDuration > 0 {
            let target = segment.duration
            let count = d.rewrittenText.count
            if isTooMany(count) {
                warnLabel("台词比原片(\(origCharCount)字)多 \(count - origCharCount) 字，配音已大幅加速，建议精简",
                          .red, "exclamationmark.triangle.fill")
            } else if target - d.audioDuration > 0.5 {
                warnLabel("配音比画面短 \(f(target - d.audioDuration))s，末尾留白，建议加字",
                          .orange, "exclamationmark.circle.fill")
            }
        }
    }

    private func warnLabel(_ text: String, _ color: Color, _ icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func saveEditedVariant(_ t: Int) {
        let newText = draftText
        editingVariant = nil
        editorFocused = false
        Task { await dubVM.updateVariantText(segment: segment, textVariantIndex: t,
                                              newText: newText, context: modelContext) }
    }

    // MARK: - 单格（音色 × 改写版）

    @ViewBuilder
    private func cell(textVariant t: Int, voiceId v: String) -> some View {
        let d = dub(textVariant: t, voiceId: v)
        VStack(spacing: 5) {
            Text(voiceName(v))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let d, dubVM.busyDubIDs.contains(d.id) {
                ProgressView().controlSize(.small)
            } else if let d, d.audioFilePath != nil {
                generatedControls(d)
            } else if let d {
                Button {
                    Task { await dubVM.generateAudio(for: d, context: modelContext) }
                } label: {
                    Label("生成", systemImage: "waveform").font(.caption2)
                }
                .buttonStyle(.bordered).controlSize(.mini).tint(.accentColor)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 64)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// 已生成音频：▶ 播放/⏹ 停止 + ↻ 重新生成（过期标橙）+ 对齐后时长
    private func generatedControls(_ d: SegmentDub) -> some View {
        let playing = dubVM.playingDubID == d.id
        let stale = isStale(d)
        // 对齐后音频时长与分镜时长的偏差：≤0.2s 视为贴合（绿），否则橙（会拉长/留白）
        let target = segment.duration
        let drift = abs(d.audioDuration - target)
        let aligned = d.audioDuration <= 0 || drift <= 0.2
        return VStack(spacing: 3) {
            HStack(spacing: 10) {
                Button {
                    dubVM.playDub(d)
                } label: {
                    Image(systemName: playing ? "stop.circle.fill" : "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(playing ? .red : (stale ? .orange : .green))
                }
                .buttonStyle(.borderless)
                .help(playing ? "停止" : "试听这条配音")

                Button {
                    Task { await dubVM.generateAudio(for: d, context: modelContext) }
                } label: {
                    Image(systemName: stale ? "exclamationmark.arrow.circlepath" : "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(stale ? .orange : .secondary)
                }
                .buttonStyle(.borderless)
                .help(stale ? "分镜或台词已变，点重新生成" : "重新生成")
            }
            if d.audioDuration > 0 {
                Text(String(format: "%.1fs", d.audioDuration))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(aligned ? .green : .orange)
                    .help("配音时长 \(String(format: "%.1f", d.audioDuration))s / 分镜 \(String(format: "%.1f", target))s")
            }
        }
    }
}
