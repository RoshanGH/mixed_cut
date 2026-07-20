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
        var minDuration: Double? = nil
        var maxDuration: Double? = nil
    }

    /// 本地编辑态段位（值类型，编辑期间不直接写库；点保存/生成时落库）
    @State private var slots: [SlotRow] = []
    /// 当前项目库内真实有分镜的可选标签（body 顶层 .task 加载，遵守切项目铁律）
    @State private var availableTags: [SemanticType] = []
    /// 生成变体数
    @State private var requestedCount = 5
    /// 正在弹出加标签面板的段位行 id（用稳定 id 而非 index，删除/拖拽后不错位）
    @State private var tagPickerSlotID: SlotRow.ID?
    /// 项目库分镜的轻量描述缓存：仅随项目切换重算（.task），避免每次重绘碾 SwiftData 导致输入框聚焦卡顿
    @State private var descriptors: [SegmentDescriptor] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.comfortable) {
                    previewNameSection
                    slotsSection
                    addSlotButton
                }
                .padding(DesignTokens.Padding.page)
            }

            Divider()
            footer
        }
        .frame(width: 560, height: 600)
        // 切项目铁律：可选标签随项目刷新；同时把库内段位载入本地编辑态
        .task(id: project.id) {
            availableTags = viewModel.availableTags(in: project)
            descriptors = buildDescriptors()
            // 库里的 NarrativeSlot 映射回 SlotRow（各生成新 UUID，order 按当前顺序丢弃）
            slots = strategy.narrativeSlots
                .sorted { $0.order < $1.order }
                .map { SlotRow(tags: $0.tags, minDuration: $0.minDuration, maxDuration: $0.maxDuration) }
        }
        .sheet(item: tagPickerBinding) { boxed in
            tagPickerSheet(for: boxed.id)
        }
    }

    // MARK: - 顶部标题

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.compact) {
            Image(systemName: "list.bullet.indent")
                .font(DesignTokens.Typography.bodyLarge)
                .foregroundStyle(.purple)
            Text("叙事结构编辑器")
                .font(DesignTokens.Typography.bodyLargeEmphasis)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - 预览名（只读，实时拼接）

    private var previewNameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("结构名（自动生成）")
                .font(DesignTokens.Typography.captionEmphasis)
                .foregroundStyle(.secondary)
            Text(previewName.isEmpty ? "添加段位与标签后自动生成" : previewName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(previewName.isEmpty ? .tertiary : .primary)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(DesignTokens.Palette.Alpha.medium))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                    .font(DesignTokens.Typography.captionEmphasis)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if slots.isEmpty {
                Text("还没有段位，点下方「＋ 添加一段」开始")
                    .font(DesignTokens.Typography.label)
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
                .frame(height: CGFloat(slots.count) * 100 + 8)
            }
        }
    }

    private func slotRow(index: Int, row: SlotRow) -> some View {
        let candidateCount = candidateCount(for: row)
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

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.compact) {
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
                                .font(DesignTokens.Typography.microBold)
                            Text("加标签")
                                .font(DesignTokens.Typography.caption)
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

                // 时长区间过滤(留空=不限)
                HStack(spacing: 6) {
                    Image(systemName: "timer").font(DesignTokens.Typography.microRegular).foregroundStyle(.secondary)
                    Text("时长").font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
                    TextField("不限", text: durationBinding(for: index, keyPath: \.minDuration))
                        .frame(width: 44).textFieldStyle(.roundedBorder).font(DesignTokens.Typography.caption)
                    Text("~").font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
                    TextField("不限", text: durationBinding(for: index, keyPath: \.maxDuration))
                        .frame(width: 44).textFieldStyle(.roundedBorder).font(DesignTokens.Typography.caption)
                    Text("秒").font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
                    if let lo = row.minDuration, let hi = row.maxDuration, lo > hi {
                        Label("最短>最长", systemImage: "exclamationmark.triangle.fill")
                            .font(DesignTokens.Typography.microRegular).foregroundStyle(.orange)
                    }
                }

                // 候选数 / 标红提示
                HStack(spacing: 6) {
                    if row.tags.isEmpty {
                        Label("未选标签", systemImage: "exclamationmark.triangle.fill")
                            .font(DesignTokens.Typography.microRegular)
                            .foregroundStyle(.red)
                    } else if candidateCount == 0 {
                        Label("无候选分镜", systemImage: "exclamationmark.triangle.fill")
                            .font(DesignTokens.Typography.microRegular)
                            .foregroundStyle(.red)
                    } else if candidateCount > narrativeCandidateLimit {
                        // 超过上限：只取前 30 送 AI，明确告知避免误以为变体会更多
                        Text("候选 \(sentToAI)（共 \(candidateCount)，按质量取前 \(narrativeCandidateLimit) 送 AI）")
                            .font(DesignTokens.Typography.microRounded)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("候选 \(candidateCount)")
                            .font(DesignTokens.Typography.microRounded)
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
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除段位")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isInvalid ? Color.red.opacity(0.05) : Color.secondary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isInvalid ? Color.red.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }

    private func tagChip(_ tag: String, slotIndex: Int) -> some View {
        HStack(spacing: 3) {
            Text(tag)
                .font(DesignTokens.Typography.captionStrong)
            Button {
                removeTag(tag, fromSlotAt: slotIndex)
            } label: {
                Image(systemName: "xmark")
                    .font(DesignTokens.Typography.microBold)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除标签")
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
                    .font(DesignTokens.Typography.label)
                Text("添加一段")
                    .font(DesignTokens.Typography.labelStrong)
            }
            .foregroundStyle(.purple)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.purple.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4]))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底部：生成数 + 生成按钮

    private var footer: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.compact) {
            // 生成失败的原因必须**看得见**。这个编辑器原来根本没有展示 errorMessage 的地方，
            // 失败时只有一个转瞬即逝的 Toast，用户回过神来已经不知道发生了什么。
            if let message = viewModel.errorMessage, !message.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignTokens.Palette.Status.warning)
                    Text(message)
                        .font(DesignTokens.Typography.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        viewModel.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(DesignTokens.Typography.microRegular)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭提示")
                }
                .padding(DesignTokens.Spacing.compact)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignTokens.Palette.Status.warning.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: DesignTokens.Corner.small, style: .continuous))
            }

            footerControls
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footerControls: some View {
        HStack(spacing: DesignTokens.Spacing.comfortable) {
            HStack(spacing: 6) {
                Text("生成变体数")
                    .font(DesignTokens.Typography.label)
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
                        .font(DesignTokens.Typography.microRegular)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Button {
                generate()
            } label: {
                HStack(spacing: DesignTokens.Spacing.tight) {
                    Image(systemName: "wand.and.stars")
                        .font(DesignTokens.Typography.caption)
                    Text("生成方案")
                }
            }
            // ⚠️ 不挂 .defaultAction：本弹窗里有「最短/最长秒数」输入框，
            // 用户填完数字习惯性按回车就会直接发起一次**按次计费**的 AI 生成，没有任何确认。
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(!canGenerate)
        }
    }

    // MARK: - 生成可用性

    /// 至少一段；每段都有标签且候选 > 0
    private var canGenerate: Bool {
        guard !viewModel.isNarrativeGenerating else { return false }
        guard !normalizedSlots.isEmpty else { return false }
        return normalizedSlots.allSatisfy {
            !$0.tags.isEmpty && !NarrativeStructureEngine.candidatePool(for: $0, in: descriptors).isEmpty
        }
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
                    .font(DesignTokens.Typography.bodyEmphasis)
                Spacer()
                Button("完成") { tagPickerSlotID = nil }
                    .controlSize(.small)
            }
            .padding(DesignTokens.Spacing.comfortable)
            Divider()

            if availableTags.isEmpty {
                Text("当前项目库内还没有可用标签（需先导入并分析视频）")
                    .font(DesignTokens.Typography.label)
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
                                HStack(spacing: DesignTokens.Spacing.tight) {
                                    if isOn {
                                        Image(systemName: "checkmark")
                                            .font(DesignTokens.Typography.microBold)
                                    }
                                    Text(type.rawValue)
                                        .font(DesignTokens.Typography.label)
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
                    .padding(DesignTokens.Spacing.comfortable)
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
            NarrativeSlot(order: i, tags: row.tags, minDuration: row.minDuration, maxDuration: row.maxDuration)
        }
    }

    private func candidateCount(for row: SlotRow) -> Int {
        let slot = NarrativeSlot(order: 0, tags: row.tags, minDuration: row.minDuration, maxDuration: row.maxDuration)
        return NarrativeStructureEngine.candidatePool(for: slot, in: descriptors).count
    }

    /// 把可选秒数与输入框文本互转:空串↔nil;非法输入(负数/非数字)忽略,保留原值
    private func durationBinding(for index: Int, keyPath: WritableKeyPath<SlotRow, Double?>) -> Binding<String> {
        Binding(
            get: {
                guard index < self.slots.count, let v = self.slots[index][keyPath: keyPath] else { return "" }
                return v.rounded() == v ? String(Int(v)) : String(v)
            },
            set: { newText in
                guard index < self.slots.count else { return }
                let trimmed = newText.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    self.slots[index][keyPath: keyPath] = nil
                } else if let d = Double(trimmed), d >= 0 {
                    self.slots[index][keyPath: keyPath] = d
                }
                self.persist()
            }
        )
    }

    /// 构建项目库分镜的轻量描述（仅在 .task 切项目时调用一次，结果缓存到 descriptors）
    private func buildDescriptors() -> [SegmentDescriptor] {
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
            // 按**真实生成结果**决定去留，不能再看 errorMessage：
            // 有好几条失败路径只弹 Toast 不设 errorMessage，那样会把失败当成功、直接关窗。
            let didGenerate = await viewModel.generateNarrativeVariants(
                for: strategy, in: project, requested: requested)
            if didGenerate {
                dismiss()   // 变体已落到方案列表
            }
            // 失败则留在编辑器里，让用户看着提示直接调整段位/标签再试
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
