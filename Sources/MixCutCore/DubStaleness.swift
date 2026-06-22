import Foundation

/// 配音失效原因枚举。
/// 当分镜边界或改写台词在配音生成之后被修改，对应配音即视为「stale（过期）」。
public enum StalenessReason: Equatable, Sendable {
    /// 起始帧变化：当前与生成时不一致
    case startFrameChanged(current: Int, recorded: Int)
    /// 结束帧变化：当前与生成时不一致
    case endFrameChanged(current: Int, recorded: Int)
    /// 改写台词哈希变化：当前与生成时不一致
    case textHashChanged(current: String, recorded: String)
}

/// 配音失效判定的输入快照（供 `DubStaleness.check` 使用）。
public struct DubSnapshot: Equatable, Sendable {
    /// 生成配音时记录的分镜起始帧
    public let recordedStartFrame: Int
    /// 生成配音时记录的分镜结束帧
    public let recordedEndFrame: Int
    /// 生成配音时记录的改写台词哈希
    public let recordedTextHash: String

    public init(recordedStartFrame: Int, recordedEndFrame: Int, recordedTextHash: String) {
        self.recordedStartFrame = recordedStartFrame
        self.recordedEndFrame = recordedEndFrame
        self.recordedTextHash = recordedTextHash
    }
}

/// 配音失效判定结果。
public enum CheckResult: Equatable, Sendable {
    /// 配音与当前帧范围/台词一致，无需重生成
    case fresh
    /// 配音过期，附带所有失效原因（至少一条）
    case stale([StalenessReason])
}

/// 纯函数判定层：无副作用、无 SwiftData 依赖。
/// 判定规则：
///  - `recordedStartFrame == -1` 表示配音从未生成（初始默认值），直接报 stale
///  - 任一字段与当前值不一致 → stale，并收集所有失效原因（可多个同时发生）
public enum DubStaleness {

    /// 对配音快照 vs 当前分镜状态做失效检查。
    ///
    /// - Parameters:
    ///   - snapshot: 配音生成时保存的快照（来自 `SegmentDub` 的四个追踪字段）
    ///   - currentStartFrame: 当前分镜起始帧
    ///   - currentEndFrame:   当前分镜结束帧
    ///   - currentTextHash:   当前改写台词的哈希（可用 `textHash(of:)` 计算）
    /// - Returns: `.fresh` 或 `.stale([reasons])`
    public static func check(snapshot: DubSnapshot,
                             currentStartFrame: Int,
                             currentEndFrame: Int,
                             currentTextHash: String) -> CheckResult {
        // 未曾生成（初始默认值 -1）→ 直接 stale
        guard snapshot.recordedStartFrame != -1 else {
            return .stale([
                .startFrameChanged(current: currentStartFrame, recorded: -1)
            ])
        }

        var reasons: [StalenessReason] = []

        if currentStartFrame != snapshot.recordedStartFrame {
            reasons.append(.startFrameChanged(current: currentStartFrame,
                                              recorded: snapshot.recordedStartFrame))
        }
        if currentEndFrame != snapshot.recordedEndFrame {
            reasons.append(.endFrameChanged(current: currentEndFrame,
                                            recorded: snapshot.recordedEndFrame))
        }
        if currentTextHash != snapshot.recordedTextHash {
            reasons.append(.textHashChanged(current: currentTextHash,
                                            recorded: snapshot.recordedTextHash))
        }

        return reasons.isEmpty ? .fresh : .stale(reasons)
    }

    /// 计算改写台词的 DJB2 哈希（16 位十六进制），用于廉价比对台词是否变化。
    /// 非密码学用途，仅需"同输入同输出、不同输入大概率不同输出"。
    /// 空串返回固定 `""`，与 `SegmentDub.generatedForTextHash` 的默认值（未配置占位）保持一致。
    public static func textHash(of text: String) -> String {
        guard !text.isEmpty else { return "" }
        // 使用 DJB2 哈希：轻量、无依赖、满足"改写台词变化即哈希变化"的需求。
        var hash: UInt64 = 5381
        for byte in text.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return String(format: "%016llx", hash)
    }
}
