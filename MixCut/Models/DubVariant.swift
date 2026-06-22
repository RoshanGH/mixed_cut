// MixCut/Models/DubVariant.swift
import Foundation
import SwiftData

/// 一个视频的「第 K 版配音」，作为整体管理单元（全局共享，挂在 Video 上）
@Model
final class DubVariant {
    @Attribute(.unique) var id: UUID
    var video: Video?
    var index: Int                       // 版本号 1..N
    var name: String                     // "版本A" 可改名
    var voiceId: String                  // TTS 音色 id
    var voiceProvider: String            // minimax / qwen
    var targetCharsPerSecond: Double = 5.0
    var statusRaw: String = "draft"      // DubVariantStatus.rawValue
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \SegmentDub.variant)
    var segmentDubs: [SegmentDub] = []

    var status: DubVariantStatus {
        get { DubVariantStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }

    init(video: Video?, index: Int, name: String, voiceId: String, voiceProvider: String) {
        self.id = UUID()
        self.video = video
        self.index = index
        self.name = name
        self.voiceId = voiceId
        self.voiceProvider = voiceProvider
        self.createdAt = Date()
    }
}
