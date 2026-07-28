import Foundation
import SwiftData

/// MCP 工具实现层：@MainActor 上读写 mainContext，返回 JSON 文本
@MainActor
final class MCPToolHandlers {
    struct Outcome: Sendable {
        let json: String
        let isError: Bool
    }

    private struct ToolFailure: Error {
        let code: AgentToolErrorCode
        let message: String
    }

    private let context: ModelContext
    private let importVM: ImportViewModel
    private let jobs: AgentJobRegistry

    init(context: ModelContext, importVM: ImportViewModel, jobs: AgentJobRegistry) {
        self.context = context
        self.importVM = importVM
        self.jobs = jobs
    }

    func call(name: String, argumentsData: Data) async -> Outcome {
        do {
            switch name {
            case "list_projects": return try listProjects()
            case "get_project": return try getProject(argumentsData)
            case "list_segments": return try listSegments(argumentsData)
            case "get_job": return try getJob(argumentsData)
            case "create_project": return try createProject(argumentsData)
            case "import_videos": return try importVideos(argumentsData)
            case "retry_analysis": return try retryPipeline(argumentsData, kind: .retryAnalysis)
            case "retry_asr": return try retryPipeline(argumentsData, kind: .retryASR)
            case "remove_video": return try removeVideo(argumentsData)
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
                "video_count": p.videoCount,
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
            "videos": project.videos.map(Self.videoSummary),
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
            let sorted = video.segments.sorted { $0.startFrame < $1.startFrame }
            for seg in sorted {
                let types = seg.semanticTypes.map(\.rawValue)
                if let filter = args.semantic_type, !types.contains(filter) { continue }
                if let filter = args.position_type, seg.positionType.rawValue != filter { continue }
                items.append([
                    "id": seg.id.uuidString,
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
                ])
            }
        }
        return success(["segments": items, "count": items.count])
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
        context.safeSave()
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
        return success(["removed": true, "video_deleted_globally": deletedGlobally])
    }

    // MARK: - 公共辅助

    private func ensureNoActiveJob() throws {
        if let active = jobs.activeJob {
            throw ToolFailure(
                code: .jobAlreadyRunning,
                message: "已有任务在运行（job_id: \(active.id.uuidString)），请等它完成后再发起")
        }
    }

    private func fetchProject(_ idString: String) throws -> Project {
        guard let uuid = UUID(uuidString: idString) else {
            throw ToolFailure(code: .invalidArgument, message: "project_id 不是合法 UUID：\(idString)")
        }
        let descriptor = FetchDescriptor<Project>(predicate: #Predicate { $0.id == uuid })
        guard let project = try? context.fetch(descriptor).first else {
            throw ToolFailure(code: .projectNotFound, message: "找不到项目 \(idString)")
        }
        return project
    }

    private func fetchVideo(_ idString: String) throws -> Video {
        guard let uuid = UUID(uuidString: idString) else {
            throw ToolFailure(code: .invalidArgument, message: "video_id 不是合法 UUID：\(idString)")
        }
        let descriptor = FetchDescriptor<Video>(predicate: #Predicate { $0.id == uuid })
        guard let video = try? context.fetch(descriptor).first else {
            throw ToolFailure(code: .videoNotFound, message: "找不到视频 \(idString)")
        }
        return video
    }

    private static func videoSummary(_ video: Video) -> [String: Any] {
        [
            "id": video.id.uuidString,
            "name": video.name,
            "status": video.status.rawValue,
            "duration_sec": video.duration,
            "error_message": video.errorMessage ?? NSNull(),
            "segment_count": video.segments.count,
        ] as [String: Any]
    }

    private func success(_ object: [String: Any]) -> Outcome {
        Outcome(json: AgentJSON.encode(object), isError: false)
    }

    private func failure(_ code: AgentToolErrorCode, _ message: String) -> Outcome {
        Outcome(json: AgentJSON.error(code: code, message: message), isError: true)
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
