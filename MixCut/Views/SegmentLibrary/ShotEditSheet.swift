import SwiftUI

/// 分镜头替换工作区（全屏 sheet）：切分镜头 → 选一个分镜头 → 提示词生成变体 → 占位式选定 → 合成新分镜。
struct ShotEditSheet: View {
    let segment: Segment
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var vm = ShotEditViewModel()
    @State private var selectedOrder: Int?
    @State private var promptText = ""

    private var fps: Double { segment.video?.fps ?? 30 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if vm.isSlicing {
                Spacer()
                ProgressView("正在切分镜头…")
                Spacer()
            } else if vm.shots.isEmpty {
                Spacer()
                Text("未能切出分镜头（该分镜可能过短或无画面切换）")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ShotTrackRow(shots: vm.shots, segment: segment, vm: vm, fps: fps, selectedOrder: $selectedOrder)
                    .padding(.vertical, 12)
                Divider()
                if let order = selectedOrder, let shot = vm.shots.first(where: { $0.orderIndex == order }) {
                    ShotVariantPicker(shot: shot, segment: segment, vm: vm, promptText: $promptText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer()
                    Text("选择上方一个分镜头来替换").foregroundStyle(.secondary)
                    Spacer()
                }
            }

            if let err = vm.errorMessage {
                Divider()
                HStack(alignment: .top, spacing: DesignTokens.Spacing.compact) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    // 可选中复制 + 允许换行：错误信息经常包含接口原文，
                    // 之前单行截断，用户既看不全也复制不走，没法反馈给我们排查。
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { vm.errorMessage = nil } label: {
                        Image(systemName: "xmark").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭提示")
                }
                .padding(10)
                .background(Color.orange.opacity(0.08))
            }
        }
        .frame(minWidth: 760, minHeight: 580)
        .task(id: segment.id) {
            await vm.loadShots(for: segment, modelContext: modelContext)
            if selectedOrder == nil { selectedOrder = vm.shots.first?.orderIndex }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("分镜头替换").font(.headline)
                Text(segment.text.isEmpty ? "无台词" : segment.text)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button {
                Task {
                    if await vm.compose(segment: segment, modelContext: modelContext) {
                        dismiss()
                    }
                }
            } label: {
                if vm.isComposing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("合成新分镜", systemImage: "square.stack.3d.down.forward")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!vm.canCompose || vm.isComposing || vm.shots.isEmpty)

            Button("关闭") { dismiss() }
                .keyboardShortcut(.cancelAction)   // Esc 关闭（macOS sheet 默认不响应 Esc，必须显式挂）
        }
        .padding(DesignTokens.Spacing.normal)
    }
}

// MARK: - 分镜头轨道（横向，9:16）

struct ShotTrackRow: View {
    let shots: [PhysicalShot]
    let segment: Segment
    @Bindable var vm: ShotEditViewModel
    let fps: Double
    @Binding var selectedOrder: Int?
    @Environment(\.modelContext) private var modelContext

    @State private var dragBase: Int? = nil   // 拖动起始时该切分点的 endFrame

    private var srcPath: String { segment.video?.localPath ?? "" }

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.compact) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(shots.enumerated()), id: \.element.id) { idx, shot in
                        card(for: shot, index: idx)
                            .onTapGesture { selectedOrder = shot.orderIndex }
                        if idx < shots.count - 1 {
                            boundaryControl(boundaryIndex: idx)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            editRow   // 选中镜头的 ±帧微调 + 拆分
        }
    }

    @ViewBuilder
    private func card(for shot: PhysicalShot, index: Int) -> some View {
        let selected = selectedOrder == shot.orderIndex
        let editable = vm.isEditable(shot, fps: fps)
        let dur = vm.duration(of: shot, fps: fps)
        VStack(spacing: DesignTokens.Spacing.tight) {
            RangeVideoPlayer(
                videoPath: srcPath,
                startTime: Double(shot.startFrame) / fps,
                endTime: Double(shot.endFrame) / fps,
                fps: fps,
                thumbnailPath: shot.thumbnailPath,
                playID: shot.id,
                playingID: $vm.playingID
            )
            .frame(width: 96, height: 170)   // 9:16
            .overlay(alignment: .topLeading) {
                Text("镜头 \(shot.orderIndex)")
                    .font(.caption2).bold().padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.5)).foregroundStyle(.white).clipShape(Capsule())
                    .padding(4)
            }
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(selected ? Color.accentColor : .clear, lineWidth: 2.5))

            Text(String(format: "%.1fs", dur)).font(.caption2).foregroundStyle(.secondary)
            if editable {
                Text(isVariantChosen(shot) ? "已选变体" : "原版")
                    .font(.caption2)
                    .foregroundStyle(isVariantChosen(shot) ? Color.accentColor : .secondary).lineLimit(1)
            } else {
                Text("超限·仅原版").font(.caption2).foregroundStyle(.orange)
            }
        }
        .frame(width: 96)
    }

    /// 两相邻镜头之间：可拖动分界手柄 + 合并按钮
    @ViewBuilder
    private func boundaryControl(boundaryIndex b: Int) -> some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.accentColor.opacity(0.55))
                .frame(width: 6, height: 170)
                .overlay(Image(systemName: "arrow.left.and.right")
                    .font(DesignTokens.Typography.microRegular).foregroundStyle(.white))
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let sorted = shots.sorted { $0.orderIndex < $1.orderIndex }
                            guard b < sorted.count else { return }
                            if dragBase == nil { dragBase = sorted[b].endFrame }
                            let delta = Int(value.translation.width / 2)   // 2pt≈1帧（粗调；精调用 ±帧）
                            vm.dragBoundary(boundaryIndex: b, toFrame: (dragBase ?? sorted[b].endFrame) + delta)
                        }
                        .onEnded { _ in
                            dragBase = nil
                            vm.endBoundaryEdit(boundaryIndex: b, segment: segment, modelContext: modelContext)
                        }
                )
            Button {
                vm.mergeShots(at: b, segment: segment, modelContext: modelContext)
            } label: {
                Image(systemName: "arrow.trianglehead.merge").font(.caption2)
            }
            .buttonStyle(.borderless).accessibilityLabel("合并镜头").help("合并这两个镜头")
        }
        .frame(width: 28)
        .padding(.horizontal, 2)
    }

    /// 选中镜头的 ±帧微调（调它与相邻镜头的边界）+ 拆分
    @ViewBuilder
    private var editRow: some View {
        if let order = selectedOrder,
           let sel = shots.first(where: { $0.orderIndex == order }) {
            let sorted = shots.sorted { $0.orderIndex < $1.orderIndex }
            let i = (sorted.firstIndex(where: { $0.id == sel.id }) ?? 0)
            // 该镜头可调的切分点：右边界（与下一镜头之间）优先；末镜头用左边界（与上一镜头）
            let rightB = i < sorted.count - 1 ? i : nil          // 右边界 = boundaryIndex i
            let leftB = i > 0 ? i - 1 : nil                      // 左边界 = boundaryIndex i-1
            HStack(spacing: 10) {
                Text("镜头 \(order) 边界").font(.caption2).foregroundStyle(.secondary)
                if let b = leftB {
                    stepper("左", b: b)
                }
                if let b = rightB {
                    stepper("右", b: b)
                }
                Button {
                    vm.splitShot(at: i, segment: segment, modelContext: modelContext)
                } label: { Label("拆分", systemImage: "scissors").font(.caption2) }
                .buttonStyle(.bordered).controlSize(.small)
                Spacer()
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func stepper(_ label: String, b: Int) -> some View {
        HStack(spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            Button { vm.nudgeBoundary(boundaryIndex: b, deltaFrames: -1, segment: segment, modelContext: modelContext) }
                label: { Image(systemName: "minus") }.buttonStyle(.borderless).controlSize(.small)
                .accessibilityLabel("\(label)边界左移")
            Button { vm.nudgeBoundary(boundaryIndex: b, deltaFrames: 1, segment: segment, modelContext: modelContext) }
                label: { Image(systemName: "plus") }.buttonStyle(.borderless).controlSize(.small)
                .accessibilityLabel("\(label)边界右移")
        }
    }

    private func isVariantChosen(_ shot: PhysicalShot) -> Bool {
        if case .variant = (vm.selections[shot.orderIndex] ?? .original) { return true }
        return false
    }
}

// MARK: - 单分镜头的版本选择 + 生成

struct ShotVariantPicker: View {
    let shot: PhysicalShot
    let segment: Segment
    @Bindable var vm: ShotEditViewModel
    @Binding var promptText: String
    @Environment(\.modelContext) private var modelContext

    @State private var confirmRegen: ShotVariant?   // 待二次确认「重新生成(会计费)」的变体

    private var fps: Double { segment.video?.fps ?? 30 }
    private var editable: Bool { vm.isEditable(shot, fps: fps) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("镜头 \(shot.orderIndex) · 选一个版本用于合成").font(.subheadline).bold()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    originalCard
                    ForEach(shot.variants.sorted { $0.createdAt < $1.createdAt }) { v in
                        variantCard(v)
                    }
                }
                .padding(.horizontal, 2)
            }
            .confirmationDialog(
                "重新生成会发起一次新任务并按次计费，确定吗？",
                isPresented: Binding(get: { confirmRegen != nil },
                                     set: { if !$0 { confirmRegen = nil } }),
                presenting: confirmRegen
            ) { v in
                Button("重新生成（计费）", role: .destructive) {
                    Task { await vm.regenerate(v, shot: shot, segment: segment, modelContext: modelContext) }
                }
                Button("取消", role: .cancel) {}
            } message: { v in
                Text(v.friendlyError ?? "旧任务结果已无法获取，需要重新发起。")
            }

            Divider().padding(.vertical, 4)

            if editable {
                promptArea
            } else {
                Text(vm.ineligibleReason(shot, fps: fps) ?? "该分镜头不可编辑")
                    .font(.callout).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
        .padding(DesignTokens.Spacing.comfortable)
    }

    private var isOriginalChosen: Bool {
        if case .original = (vm.selections[shot.orderIndex] ?? .original) { return true }
        return false
    }

    private var originalCard: some View {
        VStack(spacing: DesignTokens.Spacing.tight) {
            RangeVideoPlayer(
                videoPath: segment.video?.localPath ?? "",
                startTime: Double(shot.startFrame) / fps,
                endTime: Double(shot.endFrame) / fps,
                fps: fps,
                thumbnailPath: shot.thumbnailPath,
                playID: shot.id,
                playingID: $vm.playingID
            )
            .frame(width: 90, height: 160)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(isOriginalChosen ? Color.accentColor : .clear, lineWidth: 2.5))
            Text("原版").font(.caption2)
            Text(String(format: "%.1fs", Double(shot.frameCount) / fps))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onTapGesture { vm.select(orderIndex: shot.orderIndex, choice: .original, modelContext: modelContext) }
    }

    @ViewBuilder
    private func variantCard(_ v: ShotVariant) -> some View {
        let busy = vm.busyVariantIDs.contains(v.id)
        let chosen: Bool = {
            if case .variant(let id) = (vm.selections[shot.orderIndex] ?? .original) { return id == v.id }
            return false
        }()
        VStack(spacing: DesignTokens.Spacing.tight) {
            Group {
                if v.status == .completed, let p = v.resultVideoPath {
                    RangeVideoPlayer(
                        videoPath: p, startTime: 0,
                        endTime: Double(shot.frameCount) / fps, fps: fps,
                        thumbnailPath: v.thumbnailPath, playID: v.id, playingID: $vm.playingID)
                } else {
                    variantPlaceholder(v, busy: busy)
                }
            }
            .frame(width: 90, height: 160)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(chosen ? Color.accentColor : .clear, lineWidth: 2.5))
            .onTapGesture {
                if v.status == .completed { vm.select(orderIndex: shot.orderIndex, choice: .variant(v.id), modelContext: modelContext) }
            }

            Text(v.prompt).font(.caption2).lineLimit(1).frame(width: 90)
            // 变体时长 = 该镜头时长（VACE 等长）；标出让用户确认与原镜头一致
            if v.status == .completed {
                Text(String(format: "%.1fs", Double(shot.frameCount) / fps) + " · 同原长")
                    .font(.caption2).foregroundStyle(.green)
            }
            variantActions(v, busy: busy)
        }
    }

    /// 占位画面：生成中(转圈) / 已超时(琥珀感叹号) / 已失败(红感叹号)。感叹号 hover 出具体信息。
    @ViewBuilder
    private func variantPlaceholder(_ v: ShotVariant, busy: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.85))
            if busy || v.status == .generating {
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(vm.progress[v.id] ?? "生成中").font(.caption2).foregroundStyle(.white.opacity(0.8))
                }
            } else if v.status == .timedOut {
                VStack(spacing: DesignTokens.Spacing.tight) {
                    Image(systemName: "clock.badge.exclamationmark.fill").foregroundStyle(.yellow)
                    Text("已超时").font(.caption2).foregroundStyle(.white.opacity(0.85))
                }
                .help(v.friendlyError ?? "本地等待超时，任务可能仍在云端生成，点「重试」重新获取结果，不会重复扣费。")
            } else if v.status == .failed {
                VStack(spacing: DesignTokens.Spacing.tight) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text("失败").font(.caption2).foregroundStyle(.white.opacity(0.85))
                }
                .help(v.friendlyError ?? "生成失败")
            }
        }
    }

    /// 卡片底部操作：按状态给「重试(查旧任务) / 重新生成(计费) / 无」+ 删除。
    @ViewBuilder
    private func variantActions(_ v: ShotVariant, busy: Bool) -> some View {
        HStack(spacing: 6) {
            switch v.status {
            case .timedOut:
                // 超时：只查旧任务，安全不扣费
                Button("重试") {
                    Task { await vm.retryFetch(v, shot: shot, segment: segment, modelContext: modelContext) }
                }
                .buttonStyle(.bordered).controlSize(.mini).disabled(busy)
                .help("重新获取这次任务的结果，不会重复扣费")
            case .failed:
                if v.taskId == nil {
                    // 提交阶段就失败：从没扣过费，重试=重新提交，无风险
                    Button("重试") {
                        Task { await vm.regenerate(v, shot: shot, segment: segment, modelContext: modelContext) }
                    }
                    .buttonStyle(.bordered).controlSize(.mini).disabled(busy)
                    .help("上次没提交成功、未扣费，点此重新发起")
                } else {
                    // 阿里 FAILED / 结果过期：旧结果拿不回，只能新任务，会计费 → 二次确认
                    Button("重新生成") { confirmRegen = v }
                        .buttonStyle(.bordered).controlSize(.mini).disabled(busy)
                        .help("旧任务结果已失效，将发起一次新任务并按次计费")
                }
            default:
                EmptyView()
            }
            Button(role: .destructive) {
                vm.deleteVariant(v, modelContext: modelContext)
            } label: { Image(systemName: "trash").font(.caption2) }
            .buttonStyle(.borderless)
            .accessibilityLabel("删除变体")
            .disabled(busy)
        }
    }

    private var promptArea: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.compact) {
            HStack {
                Text("提示词").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu("预设") {
                    ForEach(PromptPresets.groups) { g in
                        Menu(g.title) {
                            ForEach(g.prompts, id: \.self) { p in
                                Button(p) { promptText = p }
                            }
                        }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            HStack(spacing: DesignTokens.Spacing.compact) {
                TextField("例如：把手里的可乐换成一瓶雪碧，手和背景不变", text: $promptText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                Button {
                    let p = promptText
                    // 立刻清空输入框：生成要 2~4 分钟，输入框一直留着内容会让用户以为没提交成功、
                    // 从而再点一次（每次都计费）。清空是最直接的"已受理"反馈。
                    promptText = ""
                    Task {
                        await vm.generateVariant(shot: shot, prompt: p, segment: segment, modelContext: modelContext)
                    }
                } label: {
                    Label("生成变体", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("约 2~4 分钟生成，按次计费。同类替换（可乐↔雪碧、换背景、换颜色）效果最好。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
