import Foundation

/// Agent 发起的异步任务（导入/重试）。内存态，app 重启即失效（启动自愈由
/// MixCutApp.resetStaleAnalyzingStatus 兜底，Agent 改查 get_project 即可）。
struct AgentJob: Sendable {
    enum Kind: String, Sendable {
        case importVideos = "import_videos"
        case retryAnalysis = "retry_analysis"
        case retryASR = "retry_asr"
        case generateSchemes = "generate_schemes"
        case exportScheme = "export_scheme"
    }

    enum State: String, Sendable {
        case running
        case completed
        case failed
    }

    let id: UUID
    let kind: Kind
    let projectID: UUID
    let startedAt: Date
    var finishedAt: Date?
    var state: State
    var report: ImportReport?
    var failureMessage: String?
    /// 非导入类 job 的结构化结果（JSON 文本，get_job 时解码回对象）
    var resultJSON: String?
}

/// Agent 任务注册表：同一时间只允许一个任务运行（与 UI 串行导入行为一致，
/// 规避共享 mainContext 的并发踩踏）
@MainActor
final class AgentJobRegistry {
    private(set) var jobs: [UUID: AgentJob] = [:]

    var activeJob: AgentJob? {
        jobs.values.first { $0.state == .running }
    }

    func begin(kind: AgentJob.Kind, projectID: UUID) -> AgentJob {
        let job = AgentJob(
            id: UUID(), kind: kind, projectID: projectID,
            startedAt: Date(), finishedAt: nil, state: .running,
            report: nil, failureMessage: nil, resultJSON: nil)
        jobs[job.id] = job
        return job
    }

    func finish(_ id: UUID, report: ImportReport?) {
        guard var job = jobs[id] else { return }
        job.state = .completed
        job.finishedAt = Date()
        job.report = report
        jobs[id] = job
    }

    /// 非导入类 job 的收尾：携带结构化结果 JSON
    func finishWithResult(_ id: UUID, resultJSON: String) {
        guard var job = jobs[id] else { return }
        job.state = .completed
        job.finishedAt = Date()
        job.resultJSON = resultJSON
        jobs[id] = job
    }

    func fail(_ id: UUID, message: String) {
        guard var job = jobs[id] else { return }
        job.state = .failed
        job.finishedAt = Date()
        job.failureMessage = message
        jobs[id] = job
    }

    func job(_ id: UUID) -> AgentJob? { jobs[id] }
}
