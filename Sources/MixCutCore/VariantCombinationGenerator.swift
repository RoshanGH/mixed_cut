import Foundation

/// 一个分镜槽的配音可选项（笛卡尔积输入）。
public struct SlotOptions: Equatable, Sendable {
    public let isLocked: Bool
    public let dubIds: [UUID]    // 该槽可选变体；空 = 只有原声
    public init(isLocked: Bool, dubIds: [UUID]) {
        self.isLocked = isLocked
        self.dubIds = dubIds
    }
}

/// 组合采样结果。
public struct CombinationResult: Equatable, Sendable {
    public let combinations: [[UUID?]]  // 每条 = 每槽选定 dubId(nil=原声)，长度 = slots.count
    public let feasibleCount: Int       // 理论可生成总数（笛卡尔积大小，已防溢出夹紧）
    public let truncated: Bool          // feasibleCount > limit（实际取的少于可生成）
    public init(combinations: [[UUID?]], feasibleCount: Int, truncated: Bool) {
        self.combinations = combinations
        self.feasibleCount = feasibleCount
        self.truncated = truncated
    }
}

/// 把「每槽的配音可选项」按笛卡尔积确定性采样成最多 limit 条互不相同的组合。
/// 锁定槽或无变体槽恒取原声（nil）。用混合进制计数枚举前 limit 个组合。
public enum VariantCombinationGenerator {

    /// 防止 feasibleCount 在槽多/选项多时整数溢出的上限（仅用于上报与遍历边界）。
    private static let feasibleCap = 1_000_000

    /// - Parameter includeOriginal: 为 true 时，每个非锁定槽把「原声(nil)」也作为一个可选项
    ///   （即 选项 = 原声 + 各变体）；用于三层方案把「原+改写A+改写B」全排列。
    ///   为 false 时非锁定槽只在各变体里选（无变体则原声）。
    public static func generate(slots: [SlotOptions], limit: Int,
                               includeOriginal: Bool = false) -> CombinationResult {
        // 每槽的实际可选集合（升序保证确定性）
        let choices: [[UUID?]] = slots.map { slot in
            if slot.isLocked { return [nil] }
            let variants = slot.dubIds.sorted { $0.uuidString < $1.uuidString }.map { Optional($0) }
            if includeOriginal { return [nil] + variants }          // 原声 + 各变体
            return variants.isEmpty ? [nil] : variants               // 仅变体（无则原声）
        }

        // 笛卡尔积大小（防溢出夹紧）
        var feasible = 1
        for c in choices {
            feasible = feasible * max(1, c.count)
            if feasible >= feasibleCap { feasible = feasibleCap; break }
        }

        guard limit > 0, !slots.isEmpty else {
            return CombinationResult(combinations: [], feasibleCount: feasible, truncated: feasible > max(0, limit))
        }

        let take = min(limit, feasible)
        var combinations: [[UUID?]] = []
        combinations.reserveCapacity(take)
        for n in 0..<take {
            var rem = n
            var combo: [UUID?] = []
            combo.reserveCapacity(choices.count)
            for c in choices {
                let count = max(1, c.count)
                let idx = rem % count
                rem /= count
                combo.append(c[idx])
            }
            combinations.append(combo)
        }
        return CombinationResult(combinations: combinations,
                                 feasibleCount: feasible,
                                 truncated: feasible > take)
    }
}
