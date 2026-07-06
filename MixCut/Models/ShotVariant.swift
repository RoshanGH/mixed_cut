import Foundation
import SwiftData

/// 分镜头 AI 编辑变体的状态
enum ShotVariantStatus: String, Codable, CaseIterable {
    case pending      // 刚创建，尚未提交
    case uploading    // 正在准备/上传输入
    case generating   // DashScope 任务生成中
    case completed     // 生成完成，结果已落地
    case failed       // 失败
}

/// 一个分镜头的一次 AI 提示词编辑产物（可多条）。
/// 对标现有配音变体 `SegmentDub` 的范式：可空父引用 + statusRaw 桥接 + 失败原因透出。
@Model
final class ShotVariant {
    @Attribute(.unique) var id: UUID
    /// 反向引用（cascade 规则声明在 PhysicalShot.variants 上）
    var shot: PhysicalShot?

    /// 用户输入的提示词（纯文字指令，必填）
    var prompt: String = ""

    var statusRaw: String = ShotVariantStatus.pending.rawValue
    var status: ShotVariantStatus {
        get { ShotVariantStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    /// DashScope 异步任务 id
    var taskId: String?
    /// 下载落地的结果视频路径
    var resultVideoPath: String?
    /// 变体首帧缩略图路径（供选择时预览）
    var thumbnailPath: String?
    /// 失败时透出的真实原因（翻译 DashScope 错误码 + 附原文）
    var friendlyError: String?

    var createdAt: Date

    init(id: UUID = UUID(), prompt: String, createdAt: Date = .now) {
        self.id = id
        self.prompt = prompt
        self.createdAt = createdAt
    }
}
