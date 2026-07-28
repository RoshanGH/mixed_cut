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

    // MARK: - 边界调整

    struct BoundaryArgs: Decodable {
        let project_id: String?
        let video_no: Int?
        let segment_nos: [Int]?
        let segment_ids: [String]?
        let start_delta_frames: Int?
        let end_delta_frames: Int?
        let start_frame: Int?
        let end_frame: Int?
    }

    func adjustSegmentBoundary(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(BoundaryArgs.self, from: data)
        let segments = try resolveSegments(SelectorArgs(
            project_id: args.project_id, video_no: args.video_no,
            segment_nos: args.segment_nos, segment_ids: args.segment_ids))
        let hasDelta = args.start_delta_frames != nil || args.end_delta_frames != nil
        let hasAbsolute = args.start_frame != nil || args.end_frame != nil
        guard hasDelta || hasAbsolute else {
            throw ToolFailure(code: .invalidArgument, message: "必须提供 delta（start/end_delta_frames）或绝对值（start/end_frame）")
        }
        guard !(hasDelta && hasAbsolute) else {
            throw ToolFailure(code: .invalidArgument, message: "delta 与绝对值不能混用")
        }
        if hasAbsolute && segments.count > 1 {
            throw ToolFailure(code: .invalidArgument, message: "绝对帧值只支持单个分镜，批量请用 delta")
        }
        var results: [[String: Any]] = []
        var staleDubs: [[String: Any]] = []
        for seg in segments {
            guard let video = seg.video, video.fps > 0 else {
                results.append(["segment_index": seg.segmentIndex, "note": "跳过：视频帧率缺失"])
                continue
            }
            let fps = video.fps
            let maxFrame = FrameTime.frame(seconds: video.duration, fps: fps)
            var targetStart = args.start_frame ?? (seg.startFrame + (args.start_delta_frames ?? 0))
            var targetEnd = args.end_frame ?? (seg.endFrame + (args.end_delta_frames ?? 0))
            // 与 UI 相同的钳制：0 ≤ start，end ≤ 视频总帧，最短 2 帧
            targetEnd = min(maxFrame, targetEnd)
            targetStart = max(0, targetStart)
            if targetEnd < targetStart + 2 { targetEnd = min(maxFrame, targetStart + 2) }
            if targetStart > targetEnd - 2 { targetStart = max(0, targetEnd - 2) }
            let oldStart = seg.startFrame
            let oldEnd = seg.endFrame
            // 走 UI 同一路径（clamp/重配台词/save/起点缩略图重生都在里面）
            if targetStart != oldStart { segmentLibVM.setStartFrame(for: seg, to: targetStart) }
            if targetEnd != oldEnd { segmentLibVM.setEndFrame(for: seg, to: targetEnd) }
            results.append([
                "segment_index": seg.segmentIndex,
                "start_frame": ["old": oldStart, "new": seg.startFrame],
                "end_frame": ["old": oldEnd, "new": seg.endFrame],
                "duration_sec": seg.duration,
                "text": seg.text,
            ])
            // 配音过期提醒：只对已生成音频的变体；没有变体的分镜不出现在提醒里
            for dub in seg.effectiveDubVariants {
                if case .stale = Self.staleCheck(dub, segment: seg) {
                    let oldDur = Double(dub.generatedForEndFrame - dub.generatedForStartFrame) / fps
                    staleDubs.append([
                        "segment_index": seg.segmentIndex,
                        "variant_index": dub.textVariantIndex,
                        "dub_duration_sec": (oldDur * 100).rounded() / 100,
                        "segment_duration_sec": (seg.duration * 100).rounded() / 100,
                    ])
                }
            }
        }
        Self.notifyUIReload()
        var payload: [String: Any] = ["results": results]
        if !staleDubs.isEmpty {
            payload["stale_dubs"] = staleDubs
            payload["stale_warning"] = "以上分镜已生成的配音是按旧时长合成的，与新时长不匹配，导出会静默使用旧音频。请把此情况告知用户，由用户决定是否用 generate_voice_variants 重新生成；不要自作主张重跑。"
        }
        return success(payload)
    }

    // MARK: - 删除分镜

    func deleteSegments(_ data: Data) throws -> Outcome {
        let sel = try JSONDecoder().decode(SelectorArgs.self, from: data)
        let segments = try resolveSegments(sel)
        var affectedSchemes = Set<String>()
        for seg in segments {
            // 与 UI 删除的 commit 闭包同语义：先删方案槽位记录，再删分镜（配音/物理镜头级联）
            for ss in Array(seg.schemeSegments) {
                if let name = ss.scheme?.name { affectedSchemes.insert(name) }
                context.delete(ss)
            }
            context.delete(seg)
        }
        context.safeSave()
        Self.notifyUIReload()
        return success([
            "deleted": segments.count,
            "affected_schemes": Array(affectedSchemes).sorted(),
            "note": affectedSchemes.isEmpty
                ? "无方案受影响"
                : "以上方案因分镜被删而缺少槽位，导出前请检查",
        ])
    }

    // MARK: - 自选组合

    struct CustomSchemeArgs: Decodable {
        struct Entry: Decodable {
            let video_no: Int?
            let segment_no: Int?
            let segment_id: String?
        }
        let project_id: String
        let name: String?
        let segments: [Entry]
    }

    func createCustomSchemeTool(_ data: Data) async throws -> Outcome {
        let args = try JSONDecoder().decode(CustomSchemeArgs.self, from: data)
        let project = try fetchProject(args.project_id)
        guard !args.segments.isEmpty else {
            throw ToolFailure(code: .invalidArgument, message: "segments 不能为空")
        }
        var ordered: [Segment] = []
        for (i, entry) in args.segments.enumerated() {
            if let sid = entry.segment_id {
                ordered.append(contentsOf: try resolveSegments(SelectorArgs(
                    project_id: nil, video_no: nil, segment_nos: nil, segment_ids: [sid])))
            } else if let vno = entry.video_no, let sno = entry.segment_no {
                ordered.append(contentsOf: try resolveSegments(SelectorArgs(
                    project_id: args.project_id, video_no: vno, segment_nos: [sno], segment_ids: nil)))
            } else {
                throw ToolFailure(code: .invalidArgument, message: "第 \(i + 1) 项必须提供 segment_id 或 video_no+segment_no")
            }
        }
        guard let scheme = await schemeVM.createCustomScheme(from: ordered, in: project) else {
            throw ToolFailure(code: .invalidArgument, message: schemeVM.errorMessage ?? "自定义组合创建失败")
        }
        if let name = args.name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            scheme.name = name
        }
        context.safeSave()
        Self.notifyUIReload()
        return success([
            "scheme_id": scheme.id.uuidString,
            "name": scheme.name,
            "segment_count": scheme.segmentCount,
            "total_duration_sec": scheme.totalDuration,
        ])
    }

    // MARK: - 分镜片段导出

    struct ExportSegmentsArgs: Decodable {
        let project_id: String?
        let video_no: Int?
        let segment_nos: [Int]?
        let segment_ids: [String]?
        let output_dir: String
    }

    func exportSegments(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(ExportSegmentsArgs.self, from: data)
        let segments = try resolveSegments(SelectorArgs(
            project_id: args.project_id, video_no: args.video_no,
            segment_nos: args.segment_nos, segment_ids: args.segment_ids))
        let outputURL = URL(fileURLWithPath: args.output_dir)
        if let problem = ExportDestination.validate(directory: outputURL) {
            throw ToolFailure(code: .invalidArgument, message: problem)
        }
        var items: [BatchExportItem] = []
        for seg in segments {
            guard let video = seg.video else {
                throw ToolFailure(code: .videoNotFound, message: "分镜 \(seg.segmentIndex) 缺少所属视频")
            }
            let sequence = Self.orderedSegments(of: video).firstIndex { $0.id == seg.id }.map { $0 + 1 } ?? 0
            items.append(BatchExportItem(
                id: seg.id,
                sourcePath: video.localPath,
                sourceVideoName: (video.name as NSString).deletingPathExtension,
                startTime: seg.startTime,
                endTime: seg.endTime,
                sequenceNumber: sequence,
                fps: video.fps))
        }
        try ensureNoActiveJob()
        let projectID: UUID = segments.first?.video?.projectVideos.first?.project?.id ?? UUID()
        let job = jobs.begin(kind: .exportSegments, projectID: projectID)
        let registry = jobs
        let exportItems = items
        Task { @MainActor in
            let service = BatchSegmentExportService()
            let (succeeded, failed) = await service.exportAll(
                items: exportItems, outputDirectory: outputURL, onProgress: { _ in })
            let summary: [String: Any] = [
                "succeeded": succeeded,
                "output_dir": outputURL.path,
                "failed": failed.map { ["name": "\($0.0.sourceVideoName)_\($0.0.sequenceNumber)", "reason": $0.1] },
            ]
            registry.finishWithResult(job.id, resultJSON: AgentJSON.encode(summary))
        }
        return success(["job_id": job.id.uuidString])
    }

    // MARK: - 声音变体生成

    func generateVoiceVariants(_ data: Data) throws -> Outcome {
        let sel = try JSONDecoder().decode(SelectorArgs.self, from: data)
        let segments = try resolveSegments(sel)
        let eligible = segments.filter { !$0.isVoiceLocked && !$0.text.isEmpty }
        let skipped = segments
            .filter { $0.isVoiceLocked || $0.text.isEmpty }
            .map { ["segment_index": $0.segmentIndex,
                    "reason": $0.isVoiceLocked ? "保留原声" : "台词为空"] }
        guard !eligible.isEmpty else {
            throw ToolFailure(code: .invalidArgument, message: "所选分镜均无法生成变体（保留原声或台词为空）")
        }
        try ensureNoActiveJob()
        let projectID: UUID = eligible.first?.video?.projectVideos.first?.project?.id ?? UUID()
        let job = jobs.begin(kind: .generateVoiceVariants, projectID: projectID)
        let vm = dubbingVM
        let ctx = context
        let registry = jobs
        Task { @MainActor in
            var perSegment: [[String: Any]] = []
            let byVideo = Dictionary(grouping: eligible, by: { $0.video?.id ?? UUID() })
            for (_, group) in byVideo {
                guard let video = group.first?.video else { continue }
                vm.errorMessage = nil
                let cloneOK = await vm.ensureClonedVoice(for: video, context: ctx)
                guard cloneOK else {
                    let reason = vm.errorMessage ?? "克隆原声失败"
                    for seg in group {
                        perSegment.append(["segment_index": seg.segmentIndex, "ok": false, "reason": reason])
                    }
                    continue
                }
                for seg in group {
                    vm.errorMessage = nil
                    await vm.rewriteSegment(seg, context: ctx)
                    if let err = vm.errorMessage {
                        perSegment.append(["segment_index": seg.segmentIndex, "ok": false, "reason": err])
                    } else {
                        perSegment.append(["segment_index": seg.segmentIndex, "ok": true,
                                           "variant_count": seg.effectiveDubVariants.count])
                    }
                }
            }
            var summary: [String: Any] = ["results": perSegment]
            if !skipped.isEmpty { summary["skipped"] = skipped }
            registry.finishWithResult(job.id, resultJSON: AgentJSON.encode(summary))
            Self.notifyUIReload()
        }
        return success([
            "job_id": job.id.uuidString,
            "note": "生成中：克隆原声→AI 改写→合成→字幕对齐，用 get_job 轮询",
        ])
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
