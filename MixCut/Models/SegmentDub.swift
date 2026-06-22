// MixCut/Models/SegmentDub.swift
import Foundation
import SwiftData

/// 某分镜在某版配音里的产物：改写台词 + 生成音频 + 对齐参数
@Model
final class SegmentDub {
    @Attribute(.unique) var id: UUID
    var variant: DubVariant?
    var segment: Segment?
    var rewrittenText: String = ""
    var audioFilePath: String?           // 未生成时 nil
    var audioDuration: Double = 0
    var atempoFactor: Double = 1.0       // 对齐变速系数（1.0=不变速）
    var freezePadFrames: Int = 0         // 末尾定格补帧数
    var trailingSilence: Double = 0      // 末尾静音秒数（AlignmentPlan 落库）

    // MARK: - 失效追踪字段（生成那一刻快照，供 DubStaleness 判定）
    var generatedForStartFrame: Int = -1  // -1 表示从未生成
    var generatedForEndFrame: Int = -1
    var generatedForTextHash: String = ""

    var statusRaw: String = "pending"    // SegmentDubStatus.rawValue

    var status: SegmentDubStatus {
        get { SegmentDubStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    init(variant: DubVariant?, segment: Segment?, rewrittenText: String = "") {
        self.id = UUID()
        self.variant = variant
        self.segment = segment
        self.rewrittenText = rewrittenText
    }
}
