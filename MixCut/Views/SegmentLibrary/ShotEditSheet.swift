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
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.callout).foregroundStyle(.secondary)
                    Spacer()
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
        }
        .padding(12)
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
        VStack(spacing: 8) {
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
        VStack(spacing: 4) {
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
            .overlay(RoundedRectangle(cornerRadius: 8)
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
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor.opacity(0.55))
                .frame(width: 6, height: 170)
                .overlay(Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 8)).foregroundStyle(.white))
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
            .buttonStyle(.borderless).help("合并这两个镜头")
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
            Button { vm.nudgeBoundary(boundaryIndex: b, deltaFrames: 1, segment: segment, modelContext: modelContext) }
                label: { Image(systemName: "plus") }.buttonStyle(.borderless).controlSize(.small)
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

            Divider().padding(.vertical, 4)

            if editable {
                promptArea
            } else {
                Text(vm.ineligibleReason(shot, fps: fps) ?? "该分镜头不可编辑")
                    .font(.callout).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var isOriginalChosen: Bool {
        if case .original = (vm.selections[shot.orderIndex] ?? .original) { return true }
        return false
    }

    private var originalCard: some View {
        VStack(spacing: 4) {
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
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isOriginalChosen ? Color.accentColor : .clear, lineWidth: 2.5))
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
        VStack(spacing: 4) {
            Group {
                if v.status == .completed, let p = v.resultVideoPath {
                    RangeVideoPlayer(
                        videoPath: p, startTime: 0,
                        endTime: Double(shot.frameCount) / fps, fps: fps,
                        thumbnailPath: v.thumbnailPath, playID: v.id, playingID: $vm.playingID)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85))
                        if busy || v.status == .generating {
                            VStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(vm.progress[v.id] ?? "生成中").font(.caption2).foregroundStyle(.white.opacity(0.8))
                            }
                        } else if v.status == .failed {
                            VStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                Text("失败").font(.caption2).foregroundStyle(.white.opacity(0.8))
                            }
                        }
                    }
                }
            }
            .frame(width: 90, height: 160)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(chosen ? Color.accentColor : .clear, lineWidth: 2.5))
            .onTapGesture {
                if v.status == .completed { vm.select(orderIndex: shot.orderIndex, choice: .variant(v.id), modelContext: modelContext) }
            }

            Text(v.prompt).font(.caption2).lineLimit(1).frame(width: 90)
            // 变体时长 = 该镜头时长（VACE 等长）；标出让用户确认与原镜头一致
            if v.status == .completed {
                Text(String(format: "%.1fs", Double(shot.frameCount) / fps) + " · 同原长")
                    .font(.caption2).foregroundStyle(.green)
            }
            Button(role: .destructive) {
                vm.deleteVariant(v, modelContext: modelContext)
            } label: { Image(systemName: "trash").font(.caption2) }
            .buttonStyle(.borderless)
            .disabled(busy)
        }
    }

    private var promptArea: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            HStack(spacing: 8) {
                TextField("例如：把手里的可乐换成一瓶雪碧，手和背景不变", text: $promptText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                Button {
                    let p = promptText
                    Task {
                        await vm.generateVariant(shot: shot, prompt: p, segment: segment, modelContext: modelContext)
                        promptText = ""
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
