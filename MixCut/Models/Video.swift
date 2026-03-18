import Foundation
import SwiftData

/// 视频处理状态
enum VideoStatus: String, Codable, CaseIterable {
    case imported = "imported"                  // 已导入
    case detectingScenes = "detecting_scenes"   // 镜头检测中
    case transcribing = "transcribing"          // ASR 识别中
    case analyzing = "analyzing"                // AI 语义分析中
    case completed = "completed"                // 处理完成
    case failed = "failed"                      // 处理失败
}

/// ASR 字级时间戳
struct ASRWord: Codable, Hashable {
    let word: String
    let start: Double
    let end: Double
}

/// ASR 原生句子（Whisper segment 级）
struct ASRSentence: Codable, Hashable {
    var text: String
    let start: Double
    let end: Double
}

@Model
final class Video: Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    var localPath: String
    var duration: Double
    var width: Int
    var height: Int
    var fps: Double
    var status: VideoStatus
    var errorMessage: String?

    /// ASR 识别结果
    var transcript: String?
    var asrWordsData: Data?      // [ASRWord] 编码存储
    var asrSentencesData: Data?  // [ASRSentence] Whisper 原生句子

    /// 文件内容哈希（SHA-256），用于全局去重
    var contentHash: String?

    /// 缩略图路径
    var thumbnailPath: String?

    /// 安全书签数据（用于沙盒访问）
    var bookmarkData: Data?

    @Relationship(deleteRule: .cascade, inverse: \ProjectVideo.video)
    var projectVideos: [ProjectVideo] = []

    @Relationship(deleteRule: .cascade, inverse: \Segment.video)
    var segments: [Segment] = []

    var createdAt: Date

    init(name: String, localPath: String) {
        self.id = UUID()
        self.name = name
        self.localPath = localPath
        self.duration = 0
        self.width = 0
        self.height = 0
        self.fps = 0
        self.status = .imported
        self.createdAt = Date()
    }

    /// 关联的项目列表
    var projects: [Project] {
        projectVideos.compactMap(\.project)
    }

    /// 被多少个项目引用
    var referenceCount: Int { projectVideos.count }

    /// 解码 ASR 字级时间戳
    var asrWords: [ASRWord] {
        get {
            guard let data = asrWordsData else { return [] }
            return (try? JSONDecoder().decode([ASRWord].self, from: data)) ?? []
        }
        set {
            asrWordsData = try? JSONEncoder().encode(newValue)
        }
    }

    /// 解码 Whisper 原生句子
    var asrSentences: [ASRSentence] {
        get {
            guard let data = asrSentencesData else { return [] }
            return (try? JSONDecoder().decode([ASRSentence].self, from: data)) ?? []
        }
        set {
            asrSentencesData = try? JSONEncoder().encode(newValue)
        }
    }

    /// 分辨率描述
    var resolution: String {
        "\(width)×\(height)"
    }
}
