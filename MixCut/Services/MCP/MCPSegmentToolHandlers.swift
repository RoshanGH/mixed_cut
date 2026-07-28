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

    // MARK: - 标签

    struct UpdateTagsArgs: Decodable {
        let project_id: String?
        let video_no: Int?
        let segment_nos: [Int]?
        let segment_ids: [String]?
        let add_semantic_types: [String]?
        let remove_semantic_types: [String]?
        let set_semantic_types: [String]?
        let position_type: String?
    }

    func updateSegmentTags(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(UpdateTagsArgs.self, from: data)
        let segments = try resolveSegments(SelectorArgs(
            project_id: args.project_id, video_no: args.video_no,
            segment_nos: args.segment_nos, segment_ids: args.segment_ids))
        let opCount = [args.add_semantic_types, args.remove_semantic_types, args.set_semantic_types]
            .compactMap { $0 }.count
        guard opCount <= 1 else {
            throw ToolFailure(code: .invalidArgument, message: "add/remove/set_semantic_types 只能提供一个")
        }
        guard opCount == 1 || args.position_type != nil else {
            throw ToolFailure(code: .invalidArgument, message: "至少提供一种修改：语义类型或 position_type")
        }
        func parseTypes(_ raw: [String]) throws -> [SemanticType] {
            try raw.map {
                guard let t = SemanticType(rawValue: $0) else {
                    throw ToolFailure(
                        code: .invalidArgument,
                        message: "非法语义类型「\($0)」，合法值：\(SemanticType.allCases.map(\.rawValue).joined(separator: "、"))")
                }
                return t
            }
        }
        var position: PositionType?
        if let p = args.position_type {
            guard let parsed = PositionType(rawValue: p) else {
                throw ToolFailure(code: .invalidArgument, message: "非法位置「\(p)」，合法值：开头、中间、结尾")
            }
            position = parsed
        }
        var results: [[String: Any]] = []
        for seg in segments {
            var note = "已修改"
            if let add = args.add_semantic_types {
                let types = try parseTypes(add)
                var current = seg.semanticTypes
                for t in types where !current.contains(t) { current.append(t) }
                seg.semanticTypes = current
            } else if let remove = args.remove_semantic_types {
                let types = try parseTypes(remove)
                let remaining = seg.semanticTypes.filter { !types.contains($0) }
                if remaining.isEmpty { note = "跳过：至少要保留 1 个语义类型" }
                else { seg.semanticTypes = remaining }
            } else if let set = args.set_semantic_types {
                let types = try parseTypes(set)
                if types.isEmpty { note = "跳过：至少要保留 1 个语义类型" }
                else { seg.semanticTypes = types }
            }
            if let position { seg.positionType = position }
            results.append([
                "segment_index": seg.segmentIndex,
                "note": note,
                "semantic_types": seg.semanticTypes.map(\.rawValue),
                "position_type": seg.positionType.rawValue,
            ])
        }
        context.safeSave()
        Self.notifyUIReload()
        return success(["results": results])
    }

    // MARK: - 字幕模式

    struct SubtitleModeArgs: Decodable {
        let project_id: String?
        let video_no: Int?
        let segment_nos: [Int]?
        let segment_ids: [String]?
        let mode: String
        let font_ratio: Double?
        let mask_y: Double?
        let mask_height: Double?
    }

    func setSubtitleMode(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(SubtitleModeArgs.self, from: data)
        let segments = try resolveSegments(SelectorArgs(
            project_id: args.project_id, video_no: args.video_no,
            segment_nos: args.segment_nos, segment_ids: args.segment_ids))
        guard ["直接烧录", "模糊虚化", "纯色遮挡"].contains(args.mode) else {
            throw ToolFailure(code: .invalidArgument, message: "mode 只认三档：直接烧录、模糊虚化、纯色遮挡")
        }
        var results: [[String: Any]] = []
        for seg in segments {
            if seg.isVoiceLocked {
                results.append(["segment_index": seg.segmentIndex, "note": "已跳过（保留原声，不加字幕）"])
                continue
            }
            switch args.mode {
            case "直接烧录": seg.hasHardSubtitle = false
            case "模糊虚化": seg.hasHardSubtitle = true; seg.maskStyle = .blur
            default: seg.hasHardSubtitle = true; seg.maskStyle = .solid
            }
            if let ratio = args.font_ratio {
                let clamped = SubtitleFontSize.clamp(ratio)
                seg.subtitleFontRatio = clamped
                SubtitleFontSize.rememberPreferred(clamped)
            }
            if args.mask_y != nil || args.mask_height != nil {
                var rect = seg.maskRect
                if let y = args.mask_y { rect.y = y }
                if let h = args.mask_height { rect.height = h }
                seg.maskRect = rect   // setter 自带 clamped()
            }
            results.append([
                "segment_index": seg.segmentIndex,
                "note": "已修改",
                "subtitle_mode": Self.subtitleModeName(of: seg),
                "font_ratio": seg.subtitleFontRatio,
            ])
        }
        context.safeSave()
        Self.notifyUIReload()
        return success(["results": results])
    }

    // MARK: - 保留原声 / 变体参与

    struct VoiceKeepArgs: Decodable {
        let project_id: String?
        let video_no: Int?
        let segment_nos: [Int]?
        let segment_ids: [String]?
        let keep_original: Bool
        let original_in_combination: Bool?
    }

    func setVoiceKeepOriginal(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(VoiceKeepArgs.self, from: data)
        let segments = try resolveSegments(SelectorArgs(
            project_id: args.project_id, video_no: args.video_no,
            segment_nos: args.segment_nos, segment_ids: args.segment_ids))
        for seg in segments {
            seg.isVoiceLocked = args.keep_original
            if let flag = args.original_in_combination {
                seg.originalParticipatesInCombination = flag
            }
        }
        context.safeSave()
        Self.notifyUIReload()
        return success(["updated": segments.count, "keep_original": args.keep_original])
    }

    struct DubParticipationArgs: Decodable {
        let project_id: String?
        let video_no: Int?
        let segment_nos: [Int]?
        let segment_ids: [String]?
        let variant_indexes: [Int]
        let participates: Bool
    }

    func setDubParticipation(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(DubParticipationArgs.self, from: data)
        let segments = try resolveSegments(SelectorArgs(
            project_id: args.project_id, video_no: args.video_no,
            segment_nos: args.segment_nos, segment_ids: args.segment_ids))
        var results: [[String: Any]] = []
        for seg in segments {
            let variants = seg.effectiveDubVariants
            var touched: [Int] = []
            var missing: [Int] = []
            for idx in args.variant_indexes {
                let matches = variants.filter { $0.textVariantIndex == idx }
                if matches.isEmpty { missing.append(idx) }
                else {
                    matches.forEach { $0.participatesInCombination = args.participates }
                    touched.append(idx)
                }
            }
            results.append([
                "segment_index": seg.segmentIndex,
                "updated_variants": touched,
                "missing_variants": missing,
            ])
        }
        context.safeSave()
        Self.notifyUIReload()
        return success(["results": results, "participates": args.participates])
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
