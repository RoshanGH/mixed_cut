import Foundation
import SwiftData

/// 视频处理状态
enum VideoStatus: String, Codable, CaseIterable {
    case imported = "imported"                  // 已导入
    case queued = "queued"                      // 等待分析槽位（已排队但未轮到）
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

    /// 配音选定音色 id（≤3），JSON 编码
    var selectedVoiceIdsData: Data?

    // MARK: 解码缓存（不持久化，见 Segment.swift 末尾 `DecodedCache` 说明）
    @Transient private var asrWordsCache = DecodedCache<[ASRWord]>()
    @Transient private var asrSentencesCache = DecodedCache<[ASRSentence]>()
    @Transient private var selectedVoiceIdsCache = DecodedCache<[String]>()

    /// 配音全局语速（CosyVoice rate，基准 1.0，范围 0.7~1.3）。SwiftData 加字段，默认 1.0。
    var dubSpeechRate: Double = 1.0

    /// 原声克隆音色 id（qwen3-tts-vc）。nil = 尚未克隆。SwiftData 加字段。
    var clonedVoiceId: String?

    /// 文件内容哈希（SHA-256），用于全局去重
    var contentHash: String?

    /// true = 用户自建分镜的载体视频（分镜库「自建分镜」分类）。SwiftData 加字段，默认 false，旧数据自动为普通视频。
    var isUserUploaded: Bool = false

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
    ///
    /// ⚠️ 性能：ASR blob 可达 20KB+，逐句字幕 / 边界对齐等路径会反复访问；做惰性解码缓存。
    var asrWords: [ASRWord] {
        get {
            if let cached = asrWordsCache.value { return cached }
            guard let data = asrWordsData else {
                asrWordsCache.value = []
                return []
            }
            let decoded = (try? JSONCoding.decoder.decode([ASRWord].self, from: data)) ?? []
            asrWordsCache.value = decoded
            return decoded
        }
        set {
            asrWordsData = try? JSONCoding.encoder.encode(newValue)
            asrWordsCache.value = newValue
        }
    }

    /// 解码 Whisper 原生句子
    var asrSentences: [ASRSentence] {
        get {
            if let cached = asrSentencesCache.value { return cached }
            guard let data = asrSentencesData else {
                asrSentencesCache.value = []
                return []
            }
            let decoded = (try? JSONCoding.decoder.decode([ASRSentence].self, from: data)) ?? []
            asrSentencesCache.value = decoded
            return decoded
        }
        set {
            asrSentencesData = try? JSONCoding.encoder.encode(newValue)
            asrSentencesCache.value = newValue
        }
    }

    /// 选定的 TTS 音色 id（≤3）
    var selectedVoiceIds: [String] {
        get {
            if let cached = selectedVoiceIdsCache.value { return cached }
            guard let data = selectedVoiceIdsData else {
                selectedVoiceIdsCache.value = []
                return []
            }
            let decoded = (try? JSONCoding.decoder.decode([String].self, from: data)) ?? []
            selectedVoiceIdsCache.value = decoded
            return decoded
        }
        set {
            selectedVoiceIdsData = try? JSONCoding.encoder.encode(newValue)
            selectedVoiceIdsCache.value = newValue
        }
    }

    /// 分辨率描述
    var resolution: String {
        "\(width)×\(height)"
    }
}
