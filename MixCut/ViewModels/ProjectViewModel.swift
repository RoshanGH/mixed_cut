import Foundation
import SwiftData
import SwiftUI

/// 项目列表 ViewModel
@MainActor
@Observable
final class ProjectViewModel {
    var projects: [Project] = []
    var selectedProject: Project? {
        didSet {
            // 记忆最后访问的项目，下次启动自动选中
            if let id = selectedProject?.id {
                UserDefaults.standard.set(id.uuidString, forKey: "lastSelectedProjectID")
            }
        }
    }
    var isCreatingProject = false
    var newProjectName = ""
    var errorMessage: String?

    private var modelContext: ModelContext?

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
        fetchProjects()
        // 启动时恢复上次选中的项目
        if selectedProject == nil,
           let idString = UserDefaults.standard.string(forKey: "lastSelectedProjectID"),
           let id = UUID(uuidString: idString),
           let proj = projects.first(where: { $0.id == id }) {
            selectedProject = proj
        }
    }

    /// 获取所有项目
    func fetchProjects() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<Project>(
            sortBy: [SortDescriptor(\Project.updatedAt, order: .reverse)]
        )
        projects = (try? context.fetch(descriptor)) ?? []
    }

    /// 创建新项目（同步创建"自定义组合"策略容器）
    func createProject() {
        guard let context = modelContext else { return }
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let project = Project(name: name)
        context.insert(project)

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

        newProjectName = ""
        isCreatingProject = false
        fetchProjects()
        selectedProject = project
    }

    /// 删除项目
    /// ProjectVideo 会级联删除，但 Video 仅在无其他引用时才删除
    func deleteProject(_ project: Project) {
        guard let context = modelContext else { return }
        let projectID = project.id
        if selectedProject?.id == projectID {
            selectedProject = nil
        }

        // 收集该项目引用的视频（在删除关联前）
        let referencedVideos = project.videos

        // 删除项目（级联删除 ProjectVideo、MixStrategy、MixScheme、SchemeSegment）
        context.delete(project)
        context.safeSave()

        // 检查每个视频是否还被其他项目引用
        for video in referencedVideos {
            if video.projectVideos.isEmpty {
                // 无引用，删除视频 + 分镜「记录」；磁盘文件交给启动时孤儿 GC 回收（为撤销可恢复铺路）
                // PV-02：必须先 Array(...) 快照再迭代 delete，否则迭代中改集合行为未定义
                // 内层 SchemeSegment 不需手动删 —— Segment.schemeSegments 已设 @Relationship(.cascade)
                let segmentSnapshot = Array(video.segments)

                for segment in segmentSnapshot {
                    context.delete(segment)
                }
                context.delete(video)

                MixLog.info(" 视频无引用，已删除记录: \(video.name)")
            }
        }

        // 清理旧版项目目录（如果存在）
        FileHelper.deleteProjectDirectory(for: projectID)
        context.safeSave()
        fetchProjects()
    }

    /// 归档项目
    func archiveProject(_ project: Project) {
        project.status = .archived
        project.updatedAt = Date()
        modelContext?.safeSave()
        fetchProjects()
    }

    /// 重命名项目
    func renameProject(_ project: Project, to newName: String) {
        project.name = newName
        project.updatedAt = Date()
        modelContext?.safeSave()
        fetchProjects()
    }
}
