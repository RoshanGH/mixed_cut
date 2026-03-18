import Foundation
import SwiftData

/// 项目状态
enum ProjectStatus: String, Codable, CaseIterable {
    case created = "created"          // 刚创建
    case importing = "importing"      // 导入素材中
    case analyzing = "analyzing"      // AI 分析中
    case ready = "ready"              // 分析完成，可生成方案
    case generating = "generating"    // 生成方案中
    case completed = "completed"      // 已完成
    case archived = "archived"        // 已归档
}

@Model
final class Project: Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    var status: ProjectStatus
    var customPrompt: String?
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ProjectVideo.project)
    var projectVideos: [ProjectVideo] = []

    @Relationship(deleteRule: .cascade, inverse: \MixStrategy.project)
    var strategies: [MixStrategy] = []

    @Relationship(deleteRule: .cascade, inverse: \MixScheme.project)
    var schemes: [MixScheme] = []

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.status = .created
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// 关联的视频列表（从 projectVideos 中提取，保持 UI 兼容）
    var videos: [Video] {
        projectVideos.compactMap(\.video)
    }

    /// 视频总数
    var videoCount: Int { projectVideos.count }

    /// 分镜总数
    var segmentCount: Int {
        videos.reduce(0) { $0 + $1.segments.count }
    }

    /// 方案总数
    var schemeCount: Int { schemes.count }
}
