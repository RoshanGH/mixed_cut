// MixCut/Models/SegmentDub.swift
import Foundation
import SwiftData

/// 某分镜的一个配音变体（= 分镜 × 改写版 × 音色）。一个 Segment 挂多个 = 变体池。
@Model
final class SegmentDub {
    @Attribute(.unique) var id: UUID
    var segment: Segment?
    var voiceId: String = ""
    var voiceProvider: String = "qwen"
    var textVariantIndex: Int = 0          // 第几个改写版（0..K-1）
    var rewrittenText: String = ""         // 同 textVariantIndex 的各音色行共享同文本
    var audioFilePath: String?             // 按需生成；初始 nil
    var audioDuration: Double = 0
    var atempoFactor: Double = 1.0
    var freezePadFrames: Int = 0
    var trailingSilence: Double = 0

    // 失效追踪（DubStaleness 生成那一刻快照）
    var generatedForStartFrame: Int = -1
    var generatedForEndFrame: Int = -1
    var generatedForTextHash: String = ""

    var statusRaw: String = "pending"      // SegmentDubStatus.rawValue

    /// 是否参与导出组合（默认不参与，opt-in；勾选后才进方案笛卡尔积/单批量导出）
    var participatesInCombination: Bool = false

    /// 逐句字幕行（含每句相对分镜起点的时间窗）。配音(重)生成后由 whisper 对齐自动写入；nil/空=尚未对齐。
    var captionLinesData: Data?

    var status: SegmentDubStatus {
        get { SegmentDubStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    /// [CaptionLine] 读写（Data?+JSON，与 keywords/asrWords 同款；CaptionLine 为 MixCutCore 同模块类型，无需 import）
    var captionLines: [CaptionLine] {
        get {
            guard let d = captionLinesData else { return [] }
            return (try? JSONDecoder().decode([CaptionLine].self, from: d)) ?? []
        }
        set { captionLinesData = try? JSONEncoder().encode(newValue) }
    }

    init(segment: Segment?, voiceId: String, voiceProvider: String = "qwen",
         textVariantIndex: Int, rewrittenText: String = "") {
        self.id = UUID()
        self.segment = segment
        self.voiceId = voiceId
        self.voiceProvider = voiceProvider
        self.textVariantIndex = textVariantIndex
        self.rewrittenText = rewrittenText
    }
}

extension Segment {
    /// 导出/组合用的有效配音变体：仅取已生成音频者，并按 textVariantIndex 去重
    /// （同一改写版若有多个音色，优先保留本视频「克隆原声」那条）。clone-only 下每版唯一。
    /// 升序返回，供 _A/_B… 命名与笛卡尔积组合使用。
    var effectiveDubVariants: [SegmentDub] {
        let cloned = video?.clonedVoiceId
        var byIndex: [Int: SegmentDub] = [:]
        for d in segmentDubs where d.audioFilePath != nil {
            if let existing = byIndex[d.textVariantIndex] {
                if d.voiceId == cloned && existing.voiceId != cloned {
                    byIndex[d.textVariantIndex] = d
                }
            } else {
                byIndex[d.textVariantIndex] = d
            }
        }
        return byIndex.values.sorted { $0.textVariantIndex < $1.textVariantIndex }
    }

    /// 参与导出组合的变体（= effectiveDubVariants 里勾选了"参与"的）。所有导出路径的单一真源。
    var combinationDubVariants: [SegmentDub] {
        effectiveDubVariants.filter { $0.participatesInCombination }
    }

    /// 该分镜参与组合的"档数"（含锁定/兜底语义）。用于组合计数展示与笛卡尔积基数。
    var combinationSlotCount: Int {
        if isVoiceLocked { return 1 }
        let base = originalParticipatesInCombination ? 1 : 0
        return max(1, base + combinationDubVariants.count)   // 兜底 ≥1（回退仅原版）
    }
}
