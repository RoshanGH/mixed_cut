import Foundation
import SwiftData
import SwiftUI

/// 项目列表 ViewModel
@MainActor
@Observable
final class ProjectViewModel {
    var projects: [Project] = []
    var selectedProject: Project?
    var isCreatingProject = false
    var newProjectName = ""
    var errorMessage: String?

    private var modelContext: ModelContext?

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
        fetchProjects()
    }

    /// 获取所有项目
    func fetchProjects() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<Project>(
            sortBy: [SortDescriptor(\Project.updatedAt, order: .reverse)]
        )
        projects = (try? context.fetch(descriptor)) ?? []
    }

    /// 创建新项目
    func createProject() {
        guard let context = modelContext else { return }
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let project = Project(name: name)
        context.insert(project)
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
                // 无引用，真正删除视频 + 分镜 + 磁盘文件
                let localPath = video.localPath
                let thumbnailPath = video.thumbnailPath
                let segThumbPaths = video.segments.compactMap(\.thumbnailPath)

                for segment in video.segments {
                    for ss in segment.schemeSegments {
                        context.delete(ss)
                    }
                    context.delete(segment)
                }
                context.delete(video)

                FileHelper.deleteGlobalVideoFiles(localPath: localPath, thumbnailPath: thumbnailPath)
                for path in segThumbPaths {
                    try? FileManager.default.removeItem(atPath: path)
                }
                MixLog.info(" 视频无引用，已删除: \(video.name)")
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
