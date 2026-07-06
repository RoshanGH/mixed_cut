import SwiftUI

struct SchemeDetailView: View {
    let scheme: MixScheme
    @Bindable var viewModel: SchemeViewModel
    @Bindable var segmentLibraryVM: SegmentLibraryViewModel
    @Environment(\.modelContext) private var modelContext

    @State private var drawerOperation: SegmentPickerDrawer.Operation?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    schemeHeader

                    Divider()

                    narrativeStructureBar

                    Divider()

                    storyboardView

                    // 策略说明
                    if let reasoning = scheme.strategyReasoning, !reasoning.isEmpty {
                        infoSection(title: "策略说明", icon: "lightbulb", text: reasoning)
                    }

                    // 差异化说明
                    if let diff = scheme.differentiation, !diff.isEmpty {
                        infoSection(title: "差异化", icon: "arrow.triangle.branch", text: diff)
                    }
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity)

            if let op = drawerOperation, let project = scheme.project {
                Divider()
                SegmentPickerDrawer(
                    project: project,
                    scheme: scheme,
                    operation: op,
                    onPick: { segment in handlePick(segment, operation: op) },
                    onClose: { drawerOperation = nil }
                )
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeOut(duration: 0.2), value: drawerOperation)
        .task(id: scheme.id) { cleanupStaleDubs() }
    }

    /// 清理废弃的旧克隆变体：架构为「只克隆原声」，每个视频当前仅一个有效克隆声 ID
    /// （`video.clonedVoiceId`）。voiceId 不等于当前 ID 的 SegmentDub 是历史残留，删除其音频与记录。
    private func cleanupStaleDubs() {
        var changed = false
        for ss in scheme.orderedSegments {
            guard let seg = ss.segment, let current = seg.video?.clonedVoiceId else { continue }
            let stale = seg.segmentDubs.filter { $0.voiceId != current }
            guard !stale.isEmpty else { continue }
            for d in stale {
                if let path = d.audioFilePath {
                    try? FileManager.default.removeItem(atPath: path)
                }
                modelContext.delete(d)
                changed = true
            }
        }
        if changed { try? modelContext.save() }
    }

    private func handlePick(_ segment: Segment, operation: SegmentPickerDrawer.Operation) {
        switch operation {
        case .insert(let position):
            if viewModel.insertSegment(segment, at: position, in: scheme) {
                ToastCenter.shared.show("已插入到 #\(position)", icon: "checkmark.circle.fill", style: .success)
            }
        case .replace(let schemeSegmentID, _):
            if let schemeSeg = scheme.schemeSegments.first(where: { $0.id == schemeSegmentID }) {
                if viewModel.replaceSegment(schemeSeg, with: segment, in: scheme) {
                    ToastCenter.shared.show("已替换 #\(schemeSeg.position)", icon: "checkmark.circle.fill", style: .success)
                }
            }
        }
    }

    // MARK: - 方案头部

    private var schemeHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(scheme.name)
                    .font(.system(size: 20, weight: .semibold))
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(scheme.name, forType: .string)
                    ToastCenter.shared.show("方案名已复制", icon: "doc.on.doc.fill")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("复制方案名")

                Spacer()
                Text(String(format: "%.1f", scheme.totalDuration))
                    .font(.system(size: 24, weight: .light, design: .rounded))
                    .foregroundStyle(.secondary)
                +
                Text("s")
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(.tertiary)
            }

            if !scheme.schemeDescription.isEmpty {
                Text(scheme.schemeDescription)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }

            HStack(spacing: 8) {
                InfoChip(icon: "paintpalette", text: scheme.style)
                InfoChip(icon: "person.2", text: scheme.targetAudience)
                InfoChip(icon: "film.stack", text: "\(scheme.segmentCount) 分镜")
            }

            if !scheme.narrativeStructure.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right.arrow.left")
                        .font(.system(size: 9))
                        .foregroundStyle(.blue)
                    Text(scheme.narrativeStructure)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.blue.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - 叙事结构条

    private var narrativeStructureBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("叙事结构")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            // 叙事结构条：横向条形分布，节点不多但用 LazyHStack 保持懒加载一致性
            GeometryReader { geo in
                LazyHStack(spacing: 2) {
                    ForEach(scheme.orderedSegments) { schemeSeg in
                        if let segment = schemeSeg.segment {
                            let width = max(
                                30,
                                geo.size.width * (segment.duration / max(scheme.totalDuration, 1))
                            )
                            RoundedRectangle(cornerRadius: 4)
                                .fill(SemanticTypeTag.color(for: segment.semanticTypes.first ?? .transition))
                                .frame(width: width)
                                .overlay {
                                    Text(segment.semanticTypes.map(\.rawValue).joined(separator: "/"))
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                        .padding(.horizontal, 2)
                                }
                                .help("\(segment.semanticTypes.map(\.rawValue).joined(separator: "/")) - \(String(format: "%.1fs", segment.duration))")
                        }
                    }
                }
            }
            .frame(height: 28)

            // 图例
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(usedTypes, id: \.self) { type in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(SemanticTypeTag.color(for: type))
                                .frame(width: 6, height: 6)
                            Text(type.rawValue)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Storyboard 视图

    private var storyboardView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("分镜序列")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                combinationHint
            }

            ScrollView(.horizontal, showsIndicators: true) {
                // LazyHStack：横向懒加载，屏幕外的 StoryboardCard 不同步实例化
                LazyHStack(alignment: .top, spacing: 0) {
                    InsertGapButton { drawerOperation = .insert(position: 1) }

                    ForEach(Array(scheme.orderedSegments.enumerated()), id: \.element.id) { idx, schemeSeg in
                        StoryboardCard(
                            schemeSeg: schemeSeg,
                            segmentLibraryVM: segmentLibraryVM,
                            canDelete: scheme.schemeSegments.count > 1,
                            onDelete: { viewModel.removeSegment(schemeSeg, from: scheme) },
                            onReplace: {
                                let originalTypes = schemeSeg.segment?.semanticTypes ?? []
                                drawerOperation = .replace(schemeSegmentID: schemeSeg.id, originalSemantic: originalTypes)
                            }
                        )

                        InsertGapButton { drawerOperation = .insert(position: idx + 2) }
                    }
                }
                .padding(.bottom, 4)
                // 强制最小高度，避免 LazyHStack 被压缩
                .frame(minHeight: 380)
            }
            .frame(height: 400)
        }
    }

    /// 每镜可选项数（锁定=1，否则 原声+各改写=1+变体数），乘积=此方案导出可生成的变体组合数。
    private var slotFactors: [Int] {
        scheme.orderedSegments.map { ss in
            guard let seg = ss.segment else { return 1 }
            return seg.combinationSlotCount   // 与导出笛卡尔积一致（含参与过滤/兜底/锁定）
        }
    }

    /// 「此方案可生成 N 个变体组合（3×1×3×3）」提示。
    @ViewBuilder
    private var combinationHint: some View {
        let factors = slotFactors
        let total = factors.reduce(1, *)
        if total <= 1 {
            Label("暂无配音变体，导出为原声", systemImage: "waveform.slash")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        } else {
            Label("可生成 \(total) 个变体组合（\(factors.map(String.init).joined(separator: "×"))）",
                  systemImage: "square.grid.3x3.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tint)
                .help("此方案每个分镜可用「原声/改写A/改写B…」，全部排列组合共 \(total) 种；锁定原声的分镜计为 ×1。导出时按当前选定的一种组合输出一条视频。")
        }
    }

    // MARK: - 辅助

    private func infoSection(title: String, icon: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var usedTypes: [SemanticType] {
        let types = scheme.orderedSegments.flatMap { $0.segment?.semanticTypes ?? [] }
        return Array(Set(types)).sorted { $0.rawValue < $1.rawValue }
    }
}

// MARK: - Storyboard 卡片

struct StoryboardCard: View {
    let schemeSeg: SchemeSegment
    @Bindable var segmentLibraryVM: SegmentLibraryViewModel
    let canDelete: Bool
    let onDelete: () -> Void
    let onReplace: () -> Void
    @State private var isHovering = false
    @Environment(\.modelContext) private var modelContext

    private let cardWidth: CGFloat = 150

    /// 该槽当前选定的配音变体（仅在有效变体中查找；未选/选不到 → nil = 原声默认）
    private var chosenDub: SegmentDub? {
        guard let id = schemeSeg.selectedSegmentDubId else { return nil }
        return schemeSeg.segment?.effectiveDubVariants.first { $0.id == id }
    }
    /// 改写版字母：0→A、1→B…
    private func variantLetter(_ index: Int) -> String {
        guard let scalar = UnicodeScalar(65 + index) else { return "\(index + 1)" }
        return String(Character(scalar))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let segment = schemeSeg.segment {
                // 视频播放器 + 序号叠加 + hover 操作按钮
                // 用 .overlay 而非 ZStack，避免 ZStack propose 不传递 height 导致 SegmentInlinePlayer 塌缩
                // 视频与下方文字统一内边距（由卡片外层 .padding(6) 提供），避免满宽视频与内缩文字「错位白边」
                SegmentInlinePlayer(
                    segment: segment,
                    viewModel: segmentLibraryVM,
                    dubAudioPath: segment.isVoiceLocked ? nil : chosenDub?.audioFilePath
                )
                    .frame(width: cardWidth - 12, height: (cardWidth - 12) * 16.0 / 9.0)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topLeading) {
                        Text("#\(schemeSeg.position)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .padding(4)
                    }
                    .overlay(alignment: .topTrailing) {
                        if isHovering {
                            HStack(spacing: 4) {
                                cardActionButton(icon: "arrow.triangle.2.circlepath",
                                                 help: "替换",
                                                 action: onReplace)
                                cardActionButton(icon: "trash.fill",
                                                 help: canDelete ? "删除" : "方案至少保留 1 个分镜",
                                                 action: canDelete ? onDelete : {},
                                                 disabled: !canDelete)
                            }
                            .padding(4)
                        }
                    }

                VStack(alignment: .leading, spacing: 5) {
                    // 类型标签
                    HStack(spacing: 3) {
                        ForEach(segment.semanticTypes.prefix(2), id: \.self) { type in
                            SemanticTypeTag(type: type)
                        }
                        if segment.semanticTypes.count > 2 {
                            Text("+\(segment.semanticTypes.count - 2)")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // 台词（hover 显示完整）
                    Text(segment.text)
                        .font(.system(size: 10))
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineSpacing(2)
                        .help(segment.text)

                    // 配音变体标 + 换变体（P5）
                    dubBadge(for: segment)

                    // 紧凑时间调整
                    StoryboardTimeRow(segment: segment, viewModel: segmentLibraryVM)
                }
            } else {
                VStack(spacing: 6) {
                    Text("#\(schemeSeg.position)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.tertiary)
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 14))
                        .foregroundStyle(.orange)
                    Text("分镜数据缺失")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(width: cardWidth - 12, height: 80)
            }
        }
        .padding(6)
        .frame(width: cardWidth)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovering
                      ? Color(.controlBackgroundColor).opacity(0.9)
                      : Color(.controlBackgroundColor).opacity(0.5))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.secondary.opacity(isHovering ? 0.15 : 0.06), lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .contextMenu {
            Button("替换为...", action: onReplace)
            Divider()
            Button("删除", role: .destructive, action: onDelete)
                .disabled(!canDelete)
        }
    }

    @ViewBuilder
    private func dubBadge(for segment: Segment) -> some View {
        if segment.isVoiceLocked {
            // 锁定分镜：只播原声，不可切换
            Label("原声（锁定）", systemImage: "lock.fill")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.orange.opacity(0.15)))
        } else {
            let variants = segment.effectiveDubVariants
            if variants.isEmpty {
                // 尚无任何已生成的改写版 → 仅原声，无可选
                Label("原声", systemImage: "waveform")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.gray.opacity(0.12)))
            } else {
                // 非锁定：永远是下拉，默认「原声」，可切到任一克隆改写版
                let chosen = chosenDub        // nil = 原声
                Menu {
                    Button {
                        schemeSeg.selectedSegmentDubId = nil
                        try? modelContext.save()
                    } label: {
                        Text("原声" + (chosen == nil ? "  ✓" : ""))
                    }
                    Divider()
                    ForEach(variants, id: \.id) { v in
                        Button {
                            schemeSeg.selectedSegmentDubId = v.id
                            try? modelContext.save()
                        } label: {
                            Text("改写\(variantLetter(v.textVariantIndex))" + (v.id == chosen?.id ? "  ✓" : ""))
                        }
                    }
                } label: {
                    Label(chosen == nil ? "原声" : "改写\(variantLetter(chosen!.textVariantIndex))",
                          systemImage: "waveform")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(chosen == nil ? Color.secondary : Color.green)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(chosen == nil ? Color.gray.opacity(0.12) : Color.green.opacity(0.15)))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private func cardActionButton(icon: String,
                                  help: String,
                                  action: @escaping () -> Void,
                                  disabled: Bool = false) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(disabled ? .gray.opacity(0.4) : .black.opacity(0.6))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}

// MARK: - 分镜序列专用时间调整行

struct StoryboardTimeRow: View {
    let segment: Segment
    @Bindable var viewModel: SegmentLibraryViewModel

    private var fps: Double { segment.video?.fps ?? 30 }

    var body: some View {
        // 上下两行（始/止），每行「标签 + − + 时码(弹性) + +」，最小 ~101px，稳放进 138px 卡片，绝不溢出
        VStack(spacing: 3) {
            adjustRow(label: "始",
                      frame: segment.startFrame,
                      onMinus: { viewModel.adjustStartFrame(for: segment, by: -1) },
                      onPlus: { viewModel.adjustStartFrame(for: segment, by: 1) })
            adjustRow(label: "止",
                      frame: segment.endFrame,
                      onMinus: { viewModel.adjustEndFrame(for: segment, by: -1) },
                      onPlus: { viewModel.adjustEndFrame(for: segment, by: 1) })
        }
        .frame(maxWidth: .infinity)
    }

    private func adjustRow(label: String,
                           frame: Int,
                           onMinus: @escaping () -> Void,
                           onPlus: @escaping () -> Void) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
            miniAdjustButton(icon: "minus", action: onMinus)
            Text(FrameTime.timecode(frame: frame, fps: fps))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            miniAdjustButton(icon: "plus", action: onPlus)
        }
    }

    private func miniAdjustButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 6, weight: .heavy))
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 16)
                .background(.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 信息芯片

struct InfoChip: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.secondary.opacity(0.06))
        .clipShape(Capsule())
    }
}
