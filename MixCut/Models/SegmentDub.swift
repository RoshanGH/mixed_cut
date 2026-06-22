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
