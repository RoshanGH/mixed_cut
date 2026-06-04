import SwiftUI

/// 叙事结构编辑器：用系统标签定义有序段位，每段一组标签，
/// AI 在每段候选分镜里挑片生成多变体。
struct NarrativeStructureEditorView: View {
    let project: Project
    let strategy: MixStrategy
    @Bindable var viewModel: SchemeViewModel
    @Environment(\.dismiss) private var dismiss

    /// 本地编辑态行模型（带稳定 UUID，拖拽/删除全程 id 不变；落库时再映射为 NarrativeSlot）
    private struct SlotRow: Identifiable {
        let id = UUID()
        var tags: [String]
    }

    /// 本地编辑态段位（值类型，编辑期间不直接写库；点保存/生成时落库）
    @State private var slots: [SlotRow] = []
    /// 当前项目库内真实有分镜的可选标签（body 顶层 .task 加载，遵守切项目铁律）
    @State private var availableTags: [SemanticType] = []
    /// 生成变体数
    @State private var requestedCount = 5
    /// 正在弹出加标签面板的段位行 id（用稳定 id 而非 index，删除/拖拽后不错位）
    @State private var tagPickerSlotID: SlotRow.ID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    previewNameSection
                    slotsSection
                    addSlotButton
                }
                .padding(20)
            }

            Divider()
            footer
        }
        .frame(width: 560, height: 600)
        // 切项目铁律：可选标签随项目刷新；同时把库内段位载入本地编辑态
        .task(id: project.id) {
            availableTags = viewModel.availableTags(in: project)
            // 库里的 NarrativeSlot 映射回 SlotRow（各生成新 UUID，order 按当前顺序丢弃）
            slots = strategy.narrativeSlots
                .sorted { $0.order < $1.order }
                .map { SlotRow(tags: $0.tags) }
        }
        .sheet(item: tagPickerBinding) { boxed in
            tagPickerSheet(for: boxed.id)
        }
    }

    // MARK: - 顶部标题

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 14))
                .foregroundStyle(.purple)
            Text("叙事结构编辑器")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - 预览名（只读，实时拼接）

    private var previewNameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("结构名（自动生成）")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(previewName.isEmpty ? "添加段位与标签后自动生成" : previewName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(previewName.isEmpty ? .tertiary : .primary)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var previewName: String {
        NarrativeStructureEngine.structureName(for: normalizedSlots)
    }

    // MARK: - 段位列表

    private var slotsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("段位（顺序 = 成片顺序，可拖拽排序）")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if slots.isEmpty {
                Text("还没有段位，点下方「＋ 添加一段」开始")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                List {
                    ForEach(Array(slots.enumerated()), id: \.element.id) { index, row in
                        slotRow(index: index, row: row)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    .onMove(perform: moveSlots)
                }
                .listStyle(.plain)
                .scrollDisabled(true)
                .frame(height: CGFloat(slots.count) * 72 + 8)
            }
        }
    }

    private func slotRow(index: Int, row: SlotRow) -> some View {
        let candidateCount = candidateCount(forTags: row.tags)
        // 送 AI 的候选会截断到 30，这里据此展示，避免"候选很多但变体少"的困惑
        let sentToAI = min(candidateCount, narrativeCandidateLimit)
        let isInvalid = row.tags.isEmpty || candidateCount == 0

        return HStack(alignment: .top, spacing: 10) {
            // 段序号
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(isInvalid ? Color.red : Color.purple))

            VStack(alignment: .leading, spacing: 8) {
                // 已选标签 chips + ＋加标签
                FlowChips {
                    ForEach(row.tags, id: \.self) { tag in
                        tagChip(tag, slotIndex: index)
                    }
                    Button {
                        tagPickerSlotID = row.id
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .bold))
                            Text("加标签")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .overlay(
                            Capsule().strokeBorder(Color.purple.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3]))
                        )
                    }
                    .buttonStyle(.plain)
                }

                // 候选数 / 标红提示
                HStack(spacing: 6) {
                    if row.tags.isEmpty {
                        Label("未选标签", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    } else if candidateCount == 0 {
                        Label("无候选分镜", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    } else if candidateCount > narrativeCandidateLimit {
                        // 超过上限：只取前 30 送 AI，明确告知避免误以为变体会更多
                        Text("候选 \(sentToAI)（共 \(candidateCount)，按质量取前 \(narrativeCandidateLimit) 送 AI）")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("候选 \(candidateCount)")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)

            // 删除
            Button {
                deleteSlot(at: index)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isInvalid ? Color.red.opacity(0.05) : Color.secondary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isInvalid ? Color.red.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }

    private func tagChip(_ tag: String, slotIndex: Int) -> some View {
        HStack(spacing: 3) {
            Text(tag)
                .font(.system(size: 11, weight: .medium))
            Button {
                removeTag(tag, fromSlotAt: slotIndex)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(colorForTag(tag))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(colorForTag(tag).opacity(0.12))
        .clipShape(Capsule())
    }

    private var addSlotButton: some View {
        Button {
            addSlot()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 12))
                Text("添加一段")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.purple)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.purple.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4]))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底部：生成数 + 生成按钮

    private var footer: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Text("生成变体数")
                    .font(.system(size: 12))
                Picker("", selection: $requestedCount) {
                    ForEach([3, 5, 8, 10, 15, 20], id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .labelsHidden()
                .frame(width: 70)
            }

            Spacer()

            if viewModel.isNarrativeGenerating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(viewModel.generationProgress.isEmpty ? "生成中…" : viewModel.generationProgress)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Button {
                generate()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 11))
                    Text("生成方案")
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(!canGenerate)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - 生成可用性

    /// 至少一段；每段都有标签且候选 > 0
    private var canGenerate: Bool {
        guard !viewModel.isNarrativeGenerating else { return false }
        guard !normalizedSlots.isEmpty else { return false }
        return normalizedSlots.allSatisfy { !$0.tags.isEmpty && candidateCount(forTags: $0.tags) > 0 }
    }

    // MARK: - 加标签面板

    /// Picker 用的包装：把可选行 id 转为 Identifiable item 以驱动 .sheet(item:)
    private struct IDBox: Identifiable {
        let id: SlotRow.ID
    }

    private var tagPickerBinding: Binding<IDBox?> {
        Binding(
            get: { tagPickerSlotID.map(IDBox.init) },
            set: { tagPickerSlotID = $0?.id }
        )
    }

    private func tagPickerSheet(for slotID: SlotRow.ID) -> some View {
        // 用稳定 id 定位行，删除/拖拽后不会错位；失效 id 退化为空选
        let selected = Set(slots.first(where: { $0.id == slotID })?.tags ?? [])
        return VStack(spacing: 0) {
            HStack {
                Text("选择标签")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("完成") { tagPickerSlotID = nil }
                    .controlSize(.small)
            }
            .padding(16)
            Divider()

            if availableTags.isEmpty {
                Text("当前项目库内还没有可用标签（需先导入并分析视频）")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
            } else {
                ScrollView {
                    FlowChips {
                        ForEach(availableTags) { type in
                            let isOn = selected.contains(type.rawValue)
                            Button {
                                toggleTag(type.rawValue, forSlotID: slotID)
                            } label: {
                                HStack(spacing: 4) {
                                    if isOn {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9, weight: .bold))
                                    }
                                    Text(type.rawValue)
                                        .font(.system(size: 12))
                                }
                                .foregroundStyle(isOn ? .white : colorForTag(type.rawValue))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().fill(isOn ? colorForTag(type.rawValue) : colorForTag(type.rawValue).opacity(0.12))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 360, height: 320)
    }

    // MARK: - 段位本地编辑（值类型，立即写回 strategy 库）

    /// 送 AI 的每段候选上限（与 generateNarrativeVariants 里的 topCandidates(limit:) 保持一致）
    private let narrativeCandidateLimit = 30

    /// 已规整 order 的段位（按当前数组下标重排 order，tags 照搬）
    private var normalizedSlots: [NarrativeSlot] {
        slots.enumerated().map { i, row in
            NarrativeSlot(order: i, tags: row.tags)
        }
    }

    private func candidateCount(forTags tags: [String]) -> Int {
        NarrativeStructureEngine.candidatePool(for: NarrativeSlot(order: 0, tags: tags), in: descriptors).count
    }

    /// 项目库分镜的轻量描述（用于候选数计算）
    private var descriptors: [SegmentDescriptor] {
        project.videos.flatMap(\.segments).map { seg in
            SegmentDescriptor(
                id: seg.id,
                tags: seg.semanticTypes.map(\.rawValue),
                text: seg.text,
                duration: seg.endTime - seg.startTime,
                quality: seg.qualityScore
            )
        }
    }

    private func addSlot() {
        slots.append(SlotRow(tags: []))
        persist()
    }

    private func deleteSlot(at index: Int) {
        guard index < slots.count else { return }
        let removedID = slots[index].id
        slots.remove(at: index)
        // 删除的正是当前打开标签面板的行 → 关闭面板，避免 sheet 读取失效 id
        if tagPickerSlotID == removedID {
            tagPickerSlotID = nil
        }
        persist()
    }

    private func moveSlots(from source: IndexSet, to destination: Int) {
        slots.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func toggleTag(_ tag: String, forSlotID id: SlotRow.ID) {
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return }
        if let pos = slots[index].tags.firstIndex(of: tag) {
            slots[index].tags.remove(at: pos)
        } else {
            slots[index].tags.append(tag)
        }
        persist()
    }

    private func removeTag(_ tag: String, fromSlotAt index: Int) {
        guard index < slots.count else { return }
        slots[index].tags.removeAll { $0 == tag }
        persist()
    }

    /// 把本地编辑态规整 order 后落库（同时重算 strategy.name）
    private func persist() {
        viewModel.updateSlots(normalizedSlots, for: strategy)
    }

    private func generate() {
        persist()
        let requested = requestedCount
        Task {
            await viewModel.generateNarrativeVariants(for: strategy, in: project, requested: requested)
            // 生成成功后关闭编辑器（变体已落到方案列表）
            if viewModel.errorMessage == nil {
                dismiss()
            }
        }
    }

    // MARK: - 颜色

    private func colorForTag(_ tag: String) -> Color {
        guard let type = SemanticType(rawValue: tag) else { return .gray }
        return Color(named: type.colorName)
    }
}

// MARK: - 简易自动换行 chip 容器

/// 轻量 Flow 布局：chip 超出宽度自动换行
private struct FlowChips: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth - spacing)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth - spacing)
        return CGSize(width: maxWidth == .infinity ? totalWidth : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Color 命名辅助

private extension Color {
    init(named name: String) {
        switch name {
        case "red": self = .red
        case "orange": self = .orange
        case "blue": self = .blue
        case "green": self = .green
        case "purple": self = .purple
        case "yellow": self = .yellow
        case "pink": self = .pink
        case "mint": self = .mint
        case "teal": self = .teal
        case "indigo": self = .indigo
        case "gray": self = .gray
        default: self = .gray
        }
    }
}
