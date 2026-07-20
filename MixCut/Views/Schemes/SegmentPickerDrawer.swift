import SwiftUI
import SwiftData

/// 选择分镜的右侧抽屉，支持插入/替换两种语义
struct SegmentPickerDrawer: View {
    enum Operation: Equatable {
        case insert(position: Int)
        case replace(schemeSegmentID: UUID, originalSemantic: [SemanticType])
    }

    let project: Project
    let scheme: MixScheme
    let operation: Operation
    let onPick: (Segment) -> Void
    let onClose: () -> Void

    @State private var searchText = ""
    @State private var filterType: SemanticType? = nil
    @State private var showAllTypes = false

    private var operationTitle: String {
        switch operation {
        case .insert(let position): return "在 #\(position) 处插入"
        case .replace: return "选择替换分镜"
        }
    }

    private var existingSegmentIDs: Set<UUID> {
        Set(scheme.schemeSegments.compactMap { $0.segment?.id })
    }

    /// 项目里所有视频的所有分镜（按视频名 + 起始时间排序）
    /// 注意：MixCut 视频全局共享，但这里只列「当前项目用到的视频」对应的分镜
    ///
    /// ⚠️ 性能：这里以前是**无缓存的计算属性**，`filteredSegments`（每次搜索/筛选变化）和
    /// header 的计数各触发一次完整 flatMap + 排序 —— 每敲一个字符要跑两遍全量。
    /// 改为进抽屉时算一次存进 @State，之后只做过滤。
    @State private var allSegments: [Segment] = []

    private func rebuildAllSegments() {
        let videos = project.projectVideos.compactMap { $0.video }
        allSegments = videos.flatMap(\.segments).sorted {
            ($0.video?.name ?? "", $0.startTime) < ($1.video?.name ?? "", $1.startTime)
        }
    }

    private var filteredSegments: [Segment] {
        var result = allSegments

        // 用户筛选（语义类型）
        if let f = filterType {
            result = result.filter { $0.semanticTypes.contains(f) }
        }

        // 用户搜索（台词）
        if !searchText.isEmpty {
            result = result.filter {
                $0.text.localizedCaseInsensitiveContains(searchText)
            }
        }

        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            content
        }
        .frame(width: 320)
        .background(.regularMaterial)
        // 切项目铁律：挂在 body 最外层且以 project.id 为 id，切换项目自动重建，
        // 不会残留上一个项目的分镜。
        .task(id: project.id) { rebuildAllSegments() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(operationTitle)
                    .font(DesignTokens.Typography.bodyEmphasis)
                let total = allSegments.count
                let inScheme = existingSegmentIDs.count
                Text("共 \(total) 个分镜 · 已在方案 \(inScheme) 个")
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(DesignTokens.Typography.bodyLarge)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
            // 抽屉不是 sheet，Esc 不会自动生效；不挂这个就只能用鼠标点右上角 ✕
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var filterBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.tertiary)
            TextField("搜索台词", text: $searchText)
                .textFieldStyle(.plain)
                .font(DesignTokens.Typography.label)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.secondary.opacity(DesignTokens.Palette.Alpha.subtle))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var content: some View {
        // ⚠️ 提到 ForEach 外面算一次。放在循环体里的话，每渲染一个卡片就要重建一遍这个 Set，
        // 而它内部 `$0.segment?.id` 会触发 SwiftData 关系加载 ——
        // 300 个分镜时，每敲一个搜索字符就是 300 次关系遍历，输入框会明显卡顿。
        let existing = existingSegmentIDs
        return ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DesignTokens.Spacing.compact) {
                ForEach(filteredSegments, id: \.id) { seg in
                    let isAlreadyInScheme = existing.contains(seg.id)
                    SegmentCardCompact(
                        segment: seg,
                        isDisabled: isAlreadyInScheme,
                        disabledReason: isAlreadyInScheme ? "该分镜已在方案中" : nil,
                        onTap: { onPick(seg) }
                    )
                }
            }
            .padding(10)

            if filteredSegments.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "film")
                        .font(DesignTokens.Typography.headline)
                        .foregroundStyle(.tertiary)
                    Text("没有匹配的分镜")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 30)
            }
        }
    }
}
