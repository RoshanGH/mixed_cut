import Foundation
import SwiftData

/// MCP 工具实现层：@MainActor 上读写 mainContext，返回 JSON 文本
@MainActor
final class MCPToolHandlers {
    struct Outcome: Sendable {
        let json: String
        let isError: Bool
    }

    struct ToolFailure: Error {
        let code: AgentToolErrorCode
        let message: String
    }

    let context: ModelContext
    let importVM: ImportViewModel
    let schemeVM: SchemeViewModel
    let jobs: AgentJobRegistry

    init(context: ModelContext, importVM: ImportViewModel, jobs: AgentJobRegistry) {
        self.context = context
        self.importVM = importVM
        self.jobs = jobs
        let schemeVM = SchemeViewModel()
        schemeVM.setModelContext(context)
        self.schemeVM = schemeVM
    }

    func call(name: String, argumentsData: Data) async -> Outcome {
        do {
            switch name {
            case "list_projects": return try listProjects()
            case "get_project": return try getProject(argumentsData)
            case "list_segments": return try listSegments(argumentsData)
            case "list_schemes": return try listSchemes(argumentsData)
            case "get_job": return try getJob(argumentsData)
            case "create_project": return try createProject(argumentsData)
            case "import_videos": return try importVideos(argumentsData)
            case "retry_analysis": return try retryPipeline(argumentsData, kind: .retryAnalysis)
            case "retry_asr": return try retryPipeline(argumentsData, kind: .retryASR)
            case "remove_video": return try removeVideo(argumentsData)
            case "generate_schemes": return try generateSchemes(argumentsData)
            case "export_scheme": return try exportScheme(argumentsData)
            case "delete_project": return try deleteProject(argumentsData)
            case "update_segment_tags": return try updateSegmentTags(argumentsData)
            case "set_subtitle_mode": return try setSubtitleMode(argumentsData)
            case "set_voice_keep_original": return try setVoiceKeepOriginal(argumentsData)
            case "set_dub_participation": return try setDubParticipation(argumentsData)
            default:
                return failure(.invalidArgument, "未知工具：\(name)")
            }
        } catch let toolFailure as ToolFailure {
            return failure(toolFailure.code, toolFailure.message)
        } catch is DecodingError {
            return failure(.invalidArgument, "参数解析失败：缺少必填字段或类型不符")
        } catch {
            return failure(.invalidArgument, FriendlyError.reason(for: error))
        }
    }

    // MARK: - 只读工具

    private func listProjects() throws -> Outcome {
        let descriptor = FetchDescriptor<Project>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        let projects = (try? context.fetch(descriptor)) ?? []
        let items: [[String: Any]] = projects.map { p in
            [
                "id": p.id.uuidString,
                "name": p.name,
                "status": p.status.rawValue,
                // 用非空视频数（与 videos 列表口径一致），不用 projectVideos.count（历史数据存在悬空关联）
                "video_count": p.videos.count,
                "segment_count": p.segmentCount,
                "scheme_count": p.schemeCount,
                "updated_at": Self.iso(p.updatedAt),
            ]
        }
        return success(["projects": items])
    }

    private struct GetProjectArgs: Decodable { let project_id: String }

    private func getProject(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(GetProjectArgs.self, from: data)
        let project = try fetchProject(args.project_id)
        return success([
            "id": project.id.uuidString,
            "name": project.name,
            "status": project.status.rawValue,
            "created_at": Self.iso(project.createdAt),
            "updated_at": Self.iso(project.updatedAt),
            "videos": Self.orderedVideos(of: project).enumerated().map { idx, video in
                var summary = Self.videoSummary(video)
                summary["video_no"] = idx + 1
                return summary
            },
        ])
    }

    private struct ListSegmentsArgs: Decodable {
        let project_id: String?
        let video_id: String?
        let semantic_type: String?
        let position_type: String?
    }

    private func listSegments(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(ListSegmentsArgs.self, from: data)
        let videos: [Video]
        switch (args.project_id, args.video_id) {
        case (.some, .some):
            throw ToolFailure(code: .invalidArgument, message: "project_id 与 video_id 只能提供一个")
        case (.some(let pid), .none):
            videos = try fetchProject(pid).videos
        case (.none, .some(let vid)):
            videos = [try fetchVideo(vid)]
        case (.none, .none):
            throw ToolFailure(code: .invalidArgument, message: "必须提供 project_id 或 video_id 之一")
        }
        var items: [[String: Any]] = []
        for video in videos {
            let sorted = Self.orderedSegments(of: video)
            for (idx, seg) in sorted.enumerated() {
                let types = seg.semanticTypes.map(\.rawValue)
                if let filter = args.semantic_type, !types.contains(filter) { continue }
                if let filter = args.position_type, seg.positionType.rawValue != filter { continue }
                items.append([
                    "id": seg.id.uuidString,
                    "segment_no": idx + 1,
                    "segment_index": seg.segmentIndex,
                    "video_id": video.id.uuidString,
                    "video_name": video.name,
                    "start_frame": seg.startFrame,
                    "end_frame": seg.endFrame,
                    "start_sec": seg.startTime,
                    "end_sec": seg.endTime,
                    "duration_sec": seg.duration,
                    "text": seg.text,
                    "semantic_types": types,
                    "position_type": seg.positionType.rawValue,
                    "confidence": seg.confidence,
                    "quality_score": seg.qualityScore,
                    "is_voice_locked": seg.isVoiceLocked,
                    "subtitle_mode": Self.subtitleModeName(of: seg),
                    "font_ratio": seg.subtitleFontRatio,
                    "voice_variant_count": seg.effectiveDubVariants.count,
                    "has_stale_dubs": Self.hasStaleDubs(seg),
                ])
            }
        }
        return success(["segments": items, "count": items.count])
    }

    private struct ListSchemesArgs: Decodable { let project_id: String }

    private func listSchemes(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(ListSchemesArgs.self, from: data)
        let project = try fetchProject(args.project_id)
        let items: [[String: Any]] = project.schemes
            .sorted { ($0.strategy?.name ?? "", $0.variationIndex) < ($1.strategy?.name ?? "", $1.variationIndex) }
            .map { scheme in
                [
                    "id": scheme.id.uuidString,
                    "name": scheme.name,
                    "style": scheme.style,
                    "strategy": scheme.strategy?.name ?? "未分组",
                    "variation_index": scheme.variationIndex,
                    "description": scheme.schemeDescription,
                    "target_audience": scheme.targetAudience,
                    "total_duration_sec": scheme.totalDuration,
                    "segment_count": scheme.segmentCount,
                    "segment_indexes": scheme.orderedSegments.compactMap { $0.segment?.segmentIndex },
                ]
            }
        return success(["schemes": items, "count": items.count])
    }

    private struct GetJobArgs: Decodable { let job_id: String }

    private func getJob(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(GetJobArgs.self, from: data)
        guard let jobID = UUID(uuidString: args.job_id) else {
            throw ToolFailure(code: .invalidArgument, message: "job_id 不是合法 UUID")
        }
        guard let job = jobs.job(jobID) else {
            throw ToolFailure(
                code: .jobNotFound,
                message: "找不到任务 \(args.job_id)（app 重启后任务会丢失，请改用 get_project 查看视频实时状态）")
        }
        var payload: [String: Any] = [
            "id": job.id.uuidString,
            "kind": job.kind.rawValue,
            "state": job.state.rawValue,
            "project_id": job.projectID.uuidString,
            "started_at": Self.iso(job.startedAt),
        ]
        if let finished = job.finishedAt { payload["finished_at"] = Self.iso(finished) }
        if let message = job.failureMessage { payload["failure_message"] = message }
        if let resultJSON = job.resultJSON,
           let result = try? JSONSerialization.jsonObject(with: Data(resultJSON.utf8)) {
            payload["result"] = result
        }
        if let report = job.report {
            payload["report"] = [
                "imported": report.importedNames,
                "linked_existing": report.linkedExistingNames,
                "skipped_duplicates": report.skippedDuplicateNames,
                "failed": report.failed.map { ["name": $0.name, "reason": $0.reason] },
                "abort_message": report.abortMessage ?? NSNull(),
            ] as [String: Any]
        }
        // 项目内所有视频的实时流水线状态（直接读 SwiftData，非缓存）
        if let project = try? fetchProject(job.projectID.uuidString) {
            payload["videos"] = project.videos.map(Self.videoSummary)
        }
        return success(payload)
    }

    // MARK: - 写工具

    private struct CreateProjectArgs: Decodable { let name: String }

    private func createProject(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(CreateProjectArgs.self, from: data)
        let trimmed = args.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolFailure(code: .invalidArgument, message: "项目名称不能为空")
        }
        let project = Project(name: trimmed)
        context.insert(project)
        // 与 UI 的 ProjectViewModel.createProject 保持一致：同步创建「自定义组合」策略容器
        let customGroup = MixStrategy(
            name: "自定义组合",
            style: "",
            description: "手动挑选分镜组合的方案",
            targetAudience: "",
            narrativeStructure: "",
            targetDuration: 0
        )
        customGroup.isCustomGroup = true
        customGroup.project = project
        project.strategies.append(customGroup)
        context.insert(customGroup)
        context.safeSave()
        Self.notifyUIReload()
        return success(["id": project.id.uuidString, "name": project.name])
    }

    private struct ImportVideosArgs: Decodable {
        let project_id: String
        let paths: [String]
    }

    private func importVideos(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(ImportVideosArgs.self, from: data)
        let project = try fetchProject(args.project_id)
        guard !args.paths.isEmpty else {
            throw ToolFailure(code: .invalidArgument, message: "paths 不能为空")
        }
        for path in args.paths {
            guard path.hasPrefix("/") else {
                throw ToolFailure(code: .invalidArgument, message: "必须是绝对路径：\(path)")
            }
            guard FileManager.default.isReadableFile(atPath: path) else {
                throw ToolFailure(code: .fileNotFound, message: "文件不存在或不可读：\(path)")
            }
        }
        try ensureNoActiveJob()
        let job = jobs.begin(kind: .importVideos, projectID: project.id)
        let urls = args.paths.map { URL(fileURLWithPath: $0) }
        let vm = importVM
        let registry = jobs
        Task { @MainActor in
            let report = await vm.importVideos(urls: urls, to: project)
            registry.finish(job.id, report: report)
            Self.notifyUIReload()
        }
        return success(["job_id": job.id.uuidString])
    }

    private struct RetryArgs: Decodable { let video_id: String }

    private func retryPipeline(_ data: Data, kind: AgentJob.Kind) throws -> Outcome {
        let args = try JSONDecoder().decode(RetryArgs.self, from: data)
        let video = try fetchVideo(args.video_id)
        guard let project = video.projectVideos.first?.project else {
            throw ToolFailure(code: .projectNotFound, message: "视频未关联任何项目，无法重试")
        }
        try ensureNoActiveJob()
        let job = jobs.begin(kind: kind, projectID: project.id)
        let vm = importVM
        let registry = jobs
        Task { @MainActor in
            if kind == .retryASR {
                await vm.retryASR(for: video, in: project)
            } else {
                await vm.retryAIAnalysis(for: video, in: project)
            }
            registry.finish(job.id, report: nil)
            Self.notifyUIReload()
        }
        return success(["job_id": job.id.uuidString])
    }

    private struct RemoveVideoArgs: Decodable {
        let project_id: String
        let video_id: String
    }

    private func removeVideo(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(RemoveVideoArgs.self, from: data)
        let project = try fetchProject(args.project_id)
        let video = try fetchVideo(args.video_id)
        guard project.videos.contains(where: { $0.id == video.id }) else {
            throw ToolFailure(code: .videoNotFound, message: "视频不在该项目中")
        }
        let deletedGlobally = importVM.removeVideoImmediately(video, from: project)
        Self.notifyUIReload()
        return success(["removed": true, "video_deleted_globally": deletedGlobally])
    }

    private struct GenerateSchemesArgs: Decodable {
        let project_id: String
        let target_count: Int?
        let custom_prompt: String?
    }

    private func generateSchemes(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(GenerateSchemesArgs.self, from: data)
        let project = try fetchProject(args.project_id)
        guard !project.videos.flatMap(\.segments).isEmpty else {
            throw ToolFailure(code: .invalidArgument, message: "项目没有可用分镜，请先导入并完成分析")
        }
        try ensureNoActiveJob()
        let job = jobs.begin(kind: .generateSchemes, projectID: project.id)
        let vm = schemeVM
        let registry = jobs
        let targetCount = args.target_count ?? 50
        let customPrompt = args.custom_prompt
        Task { @MainActor in
            await vm.generateSchemes(for: project, targetVideoCount: targetCount, customPrompt: customPrompt)
            if let error = vm.errorMessage {
                registry.fail(job.id, message: error)
            } else {
                let summary: [String: Any] = [
                    "scheme_count": project.schemes.count,
                    "failed_strategies": vm.failedStrategies.count,
                ]
                registry.finishWithResult(job.id, resultJSON: AgentJSON.encode(summary))
            }
            Self.notifyUIReload()
        }
        return success(["job_id": job.id.uuidString])
    }

    private struct ExportSchemeArgs: Decodable {
        let scheme_ids: [String]
        let output_dir: String
    }

    private func exportScheme(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(ExportSchemeArgs.self, from: data)
        guard !args.scheme_ids.isEmpty else {
            throw ToolFailure(code: .invalidArgument, message: "scheme_ids 不能为空")
        }
        let outputURL = URL(fileURLWithPath: args.output_dir)
        if let problem = ExportDestination.validate(directory: outputURL) {
            throw ToolFailure(code: .invalidArgument, message: problem)
        }
        // 先在 MainActor 上校验并提取全部导出任务（SwiftData 模型不能进后台）
        var tasks: [(input: ExportInput, outputPath: String, name: String)] = []
        var projectID: UUID?
        for idString in args.scheme_ids {
            let scheme = try fetchScheme(idString)
            projectID = scheme.project?.id ?? projectID
            guard let input = ExportInput.from(scheme: scheme) else {
                throw ToolFailure(code: .invalidArgument, message: "方案「\(scheme.name)」没有有效分镜，无法导出")
            }
            // 命名规则与 UI 批量导出一致：策略名_变体号_方案名.mp4
            let strategyName = scheme.strategy?.name ?? "未分组"
            let sanitized = Self.sanitizeFilename("\(strategyName)_\(scheme.variationIndex)_\(scheme.name)")
            tasks.append((input: input,
                          outputPath: outputURL.appendingPathComponent("\(sanitized).mp4").path,
                          name: scheme.name))
        }
        try ensureNoActiveJob()
        let job = jobs.begin(kind: .exportScheme, projectID: projectID ?? UUID())
        let registry = jobs
        let exportTasks = tasks
        Task { @MainActor in
            var exported: [String] = []
            var failures: [[String: String]] = []
            for task in exportTasks {
                do {
                    let service = ExportService()
                    try await service.export(input: task.input, outputPath: task.outputPath)
                    exported.append(task.outputPath)
                } catch {
                    failures.append(["scheme": task.name, "reason": FriendlyError.reason(for: error)])
                }
            }
            let summary: [String: Any] = ["exported": exported, "failed": failures]
            if exported.isEmpty && !failures.isEmpty {
                registry.fail(job.id, message: "全部导出失败：\(failures.first?["reason"] ?? "")")
            } else {
                registry.finishWithResult(job.id, resultJSON: AgentJSON.encode(summary))
            }
        }
        return success(["job_id": job.id.uuidString])
    }

    private struct DeleteProjectArgs: Decodable {
        let project_id: String
        let confirm: Bool?
    }

    private func deleteProject(_ data: Data) throws -> Outcome {
        let args = try JSONDecoder().decode(DeleteProjectArgs.self, from: data)
        let project = try fetchProject(args.project_id)
        let projectName = project.name
        let referencedVideos = project.videos
        // 二次确认：未显式 confirm=true 时只返回影响预览，不执行（行业标准的破坏性操作防护）
        guard args.confirm == true else {
            let wouldDeleteGlobally = referencedVideos
                .filter { $0.projectVideos.count <= 1 }
                .map(\.name)
            return success([
                "requires_confirmation": true,
                "project": projectName,
                "video_count": referencedVideos.count,
                "scheme_count": project.schemes.count,
                "videos_that_would_be_deleted_globally": wouldDeleteGlobally,
                "message": "未执行删除。确认无误后，带 confirm=true 重新调用才会真正删除（无撤销）。",
            ])
        }
        // 与 ProjectViewModel.deleteProject 的 commit 逻辑一致，但立即执行、无撤销
        context.delete(project)
        context.safeSave()
        var deletedVideoNames: [String] = []
        for video in referencedVideos where video.projectVideos.isEmpty {
            let segmentSnapshot = Array(video.segments)
            for segment in segmentSnapshot { context.delete(segment) }
            context.delete(video)
            deletedVideoNames.append(video.name)
        }
        context.safeSave()
        Self.notifyUIReload()
        return success([
            "deleted": true,
            "name": projectName,
            "videos_deleted_globally": deletedVideoNames,
        ])
    }

    // MARK: - 公共辅助

    /// Agent 绕过 UI 流程写库后，广播全量重载通知（复用撤销后的刷新机制），
    /// 让侧边栏/概览等非 SwiftData 观察驱动的列表立即反映变化
    static func notifyUIReload() {
        NotificationCenter.default.post(name: .mixCutDataDidUndo, object: nil)
    }

    func ensureNoActiveJob() throws {
        if let active = jobs.activeJob {
            throw ToolFailure(
                code: .jobAlreadyRunning,
                message: "已有任务在运行（job_id: \(active.id.uuidString)），请等它完成后再发起")
        }
    }

    func fetchProject(_ idString: String) throws -> Project {
        guard let uuid = UUID(uuidString: idString) else {
            throw ToolFailure(code: .invalidArgument, message: "project_id 不是合法 UUID：\(idString)")
        }
        let descriptor = FetchDescriptor<Project>(predicate: #Predicate { $0.id == uuid })
        guard let project = try? context.fetch(descriptor).first else {
            throw ToolFailure(code: .projectNotFound, message: "找不到项目 \(idString)")
        }
        return project
    }

    func fetchVideo(_ idString: String) throws -> Video {
        guard let uuid = UUID(uuidString: idString) else {
            throw ToolFailure(code: .invalidArgument, message: "video_id 不是合法 UUID：\(idString)")
        }
        let descriptor = FetchDescriptor<Video>(predicate: #Predicate { $0.id == uuid })
        guard let video = try? context.fetch(descriptor).first else {
            throw ToolFailure(code: .videoNotFound, message: "找不到视频 \(idString)")
        }
        return video
    }

    private func fetchScheme(_ idString: String) throws -> MixScheme {
        guard let uuid = UUID(uuidString: idString) else {
            throw ToolFailure(code: .invalidArgument, message: "scheme_id 不是合法 UUID：\(idString)")
        }
        let descriptor = FetchDescriptor<MixScheme>(predicate: #Predicate { $0.id == uuid })
        guard let scheme = try? context.fetch(descriptor).first else {
            throw ToolFailure(code: .invalidArgument, message: "找不到方案 \(idString)")
        }
        return scheme
    }

    /// 与 ExportView.sanitizeFilename 一致
    private static func sanitizeFilename(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: illegal).joined(separator: "_")
    }

    static func videoSummary(_ video: Video) -> [String: Any] {
        [
            "id": video.id.uuidString,
            "name": video.name,
            "status": video.status.rawValue,
            "duration_sec": video.duration,
            "error_message": video.errorMessage ?? NSNull(),
            "segment_count": video.segments.count,
        ] as [String: Any]
    }

    func success(_ object: [String: Any]) -> Outcome {
        Outcome(json: AgentJSON.encode(object), isError: false)
    }

    func failure(_ code: AgentToolErrorCode, _ message: String) -> Outcome {
        Outcome(json: AgentJSON.error(code: code, message: message), isError: true)
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
