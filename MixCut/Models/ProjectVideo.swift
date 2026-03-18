import Foundation
import SwiftData

/// Project 与 Video 的多对多关联（视频全局共享，不再从属单一项目）
@Model
final class ProjectVideo: Identifiable {
    @Attribute(.unique) var id: UUID
    var addedAt: Date

    var project: Project?
    var video: Video?

    init(project: Project, video: Video) {
        self.id = UUID()
        self.addedAt = Date()
        self.project = project
        self.video = video
    }
}
