import Foundation

/// 一个已生成音频的配音变体引用（纯值类型）。
public struct VariantRef: Equatable, Sendable {
    public let dubKey: String
    public let textVariantIndex: Int
    public init(dubKey: String, textVariantIndex: Int) {
        self.dubKey = dubKey
        self.textVariantIndex = textVariantIndex
    }
}

/// 一个选中分镜的导出来源描述（纯值类型，App 层从 Segment 构造）。
public struct SegmentExportSource: Equatable, Sendable {
    public let segmentKey: String
    public let sequenceNumber: Int
    public let videoName: String      // 不含扩展名
    public let isVoiceLocked: Bool
    public let variants: [VariantRef] // 仅含已生成音频的变体
    public init(segmentKey: String, sequenceNumber: Int, videoName: String,
                isVoiceLocked: Bool, variants: [VariantRef]) {
        self.segmentKey = segmentKey
        self.sequenceNumber = sequenceNumber
        self.videoName = videoName
        self.isVoiceLocked = isVoiceLocked
        self.variants = variants
    }
}

/// 展开后的单个导出任务（dubKey == nil 表示原版）。
public struct SegmentExportPlanItem: Equatable, Sendable {
    public let segmentKey: String
    public let dubKey: String?
    public let fileName: String
    public init(segmentKey: String, dubKey: String?, fileName: String) {
        self.segmentKey = segmentKey
        self.dubKey = dubKey
        self.fileName = fileName
    }
}

/// 把选中分镜展开成「1 原版 + N 变体」的导出任务列表并命名。
public enum SegmentExportExpander {

    public static func expand(_ sources: [SegmentExportSource]) -> [SegmentExportPlanItem] {
        var out: [SegmentExportPlanItem] = []
        for s in sources {
            out.append(SegmentExportPlanItem(
                segmentKey: s.segmentKey, dubKey: nil,
                fileName: "\(s.sequenceNumber)_\(s.videoName).mp4"))
            guard !s.isVoiceLocked else { continue }
            for v in s.variants.sorted(by: { $0.textVariantIndex < $1.textVariantIndex }) {
                let letter = letter(for: v.textVariantIndex)
                out.append(SegmentExportPlanItem(
                    segmentKey: s.segmentKey, dubKey: v.dubKey,
                    fileName: "\(s.sequenceNumber)_\(s.videoName)_\(letter).mp4"))
            }
        }
        return out
    }

    /// textVariantIndex → 字母（0→A）；越界回退 "V{index}"。
    public static func letter(for index: Int) -> String {
        guard index >= 0, index < 26,
              let scalar = UnicodeScalar(UnicodeScalar("A").value + UInt32(index)) else {
            return "V\(index)"
        }
        return String(scalar)
    }
}
