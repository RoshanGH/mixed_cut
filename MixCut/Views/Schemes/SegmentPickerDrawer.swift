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
    private var allSegments: [Segment] {
        let videos = project.projectVideos.compactMap { $0.video }
        let segments = videos.flatMap(\.segments)
        return segments.sorted { ($0.video?.name ?? "") + String($0.startTime) <
                                ($1.video?.name ?? "") + String($1.startTime) }
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
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(operationTitle)
                    .font(.system(size: 13, weight: .semibold))
                let total = allSegments.count
                let inScheme = existingSegmentIDs.count
                Text("共 \(total) 个分镜 · 已在方案 \(inScheme) 个")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var filterBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("搜索台词", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var content: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(filteredSegments, id: \.id) { seg in
                    let isAlreadyInScheme = existingSegmentIDs.contains(seg.id)
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
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                    Text("没有匹配的分镜")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 30)
            }
        }
    }
}
