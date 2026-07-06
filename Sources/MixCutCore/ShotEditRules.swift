import Foundation

/// 占位式选择：原版或某个变体版本（由 UUID 标识）
public enum SlotChoice: Sendable, Equatable {
    case original
    case variant(UUID)
}

/// 分镜头级编辑的可编辑性规则 + 占位式选择校验（纯算法）
public enum ShotEditRules {
    /// 最小可编辑时长（秒）
    public static let minSeconds = 2.0

    /// 最大可编辑时长（秒）
    public static let maxSeconds = 10.0

    /// 判断分镜头是否可编辑（时长必须在 [2s, 10s]）
    public static func isEditable(durationSeconds d: Double) -> Bool {
        d >= minSeconds && d <= maxSeconds
    }

    /// 如果不可编辑，返回中文原因；否则返回 nil
    public static func ineligibleReason(durationSeconds d: Double) -> String? {
        if d > maxSeconds {
            return "该分镜头 \(String(format: "%.1f", d))s 超过 \(Int(maxSeconds))s 上限，请用帧级调整拆短后再替换"
        }
        if d < minSeconds {
            return "该分镜头 \(String(format: "%.1f", d))s 不足 \(Int(minSeconds))s 下限，无法替换"
        }
        return nil
    }

    /// 占位式选择完整性校验：1...slotCount 每个坑都必须有且仅一个选择
    public static func canCompose(slotCount: Int, selections: [Int: SlotChoice]) -> Bool {
        guard slotCount > 0 else { return false }
        for slot in 1...slotCount where selections[slot] == nil {
            return false
        }
        return true
    }
}
