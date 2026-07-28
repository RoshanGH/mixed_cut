import Foundation
import SwiftData

// MARK: - 分镜修改工具（第二阶段）：寻址解析与 9 个 handler

extension MCPToolHandlers {
    struct SelectorArgs: Decodable {
        let project_id: String?
        let video_no: Int?
        let segment_nos: [Int]?
        let segment_ids: [String]?
    }

    /// 视频稳定顺序：项目内按导入时间（addedAt）升序，1-based 编号的依据
    static func orderedVideos(of project: Project) -> [Video] {
        project.projectVideos
            .sorted { $0.addedAt < $1.addedAt }
            .compactMap(\.video)
    }

    /// 分镜稳定顺序：视频内按开始帧升序（与 UI 卡片 # 编号口径一致）
    static func orderedSegments(of video: Video) -> [Segment] {
        video.segments.sorted { $0.startFrame < $1.startFrame }
    }

    /// 三档中文名：直接烧录 / 模糊虚化 / 纯色遮挡（与 SubtitleTreatment.from 口径一致）
    static func subtitleModeName(of segment: Segment) -> String {
        guard segment.hasHardSubtitle else { return "直接烧录" }
        switch segment.maskStyle {
        case .solid: return "纯色遮挡"
        default: return "模糊虚化"   // blur 与旧 dim 统一归模糊
        }
    }

    /// 该分镜是否存在「按旧时长合成」的过期配音
    static func hasStaleDubs(_ segment: Segment) -> Bool {
        segment.effectiveDubVariants.contains { dub in
            if case .stale = staleCheck(dub, segment: segment) { return true }
            return false
        }
    }

    static func staleCheck(_ dub: SegmentDub, segment: Segment) -> CheckResult {
        let snapshot = DubSnapshot(
            recordedStartFrame: dub.generatedForStartFrame,
            recordedEndFrame: dub.generatedForEndFrame,
            recordedTextHash: dub.generatedForTextHash)
        return DubStaleness.check(
            snapshot: snapshot,
            currentStartFrame: segment.startFrame,
            currentEndFrame: segment.endFrame,
            currentTextHash: DubStaleness.textHash(of: dub.rewrittenText))
    }

    /// all-or-nothing 定位：全部找到才返回，否则整个调用不执行
    func resolveSegments(_ sel: SelectorArgs) throws -> [Segment] {
        if let ids = sel.segment_ids, !ids.isEmpty {
            var result: [Segment] = []
            var missing: [String] = []
            for idString in ids {
                guard let uuid = UUID(uuidString: idString) else {
                    throw ToolFailure(code: .invalidArgument, message: "segment_id 不是合法 UUID：\(idString)")
                }
                let descriptor = FetchDescriptor<Segment>(predicate: #Predicate { $0.id == uuid })
                if let seg = try? context.fetch(descriptor).first { result.append(seg) }
                else { missing.append(idString) }
            }
            guard missing.isEmpty else {
                throw ToolFailure(code: .segmentNotFound, message: "找不到分镜：\(missing.joined(separator: "、"))")
            }
            return result
        }
        guard let pid = sel.project_id, let vno = sel.video_no,
              let nos = sel.segment_nos, !nos.isEmpty else {
            throw ToolFailure(code: .invalidArgument, message: "必须提供 segment_ids，或 project_id + video_no + segment_nos")
        }
        let project = try fetchProject(pid)
        let videos = Self.orderedVideos(of: project)
        guard vno >= 1, vno <= videos.count else {
            throw ToolFailure(code: .videoNotFound, message: "video_no \(vno) 超出范围（项目共 \(videos.count) 个视频）")
        }
        let ordered = Self.orderedSegments(of: videos[vno - 1])
        let missing = nos.filter { $0 < 1 || $0 > ordered.count }
        guard missing.isEmpty else {
            throw ToolFailure(
                code: .segmentNotFound,
                message: "视频 \(vno) 共 \(ordered.count) 个分镜，找不到编号：\(missing.map(String.init).joined(separator: "、"))")
        }
        return nos.map { ordered[$0 - 1] }
    }
}
