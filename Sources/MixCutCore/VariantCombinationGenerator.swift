import Foundation

/// 一个分镜槽的配音可选项（笛卡尔积输入）。
public struct SlotOptions: Equatable, Sendable {
    public let isLocked: Bool
    public let includeOriginal: Bool   // 该槽是否把原声(nil)作为一个可选项（逐格控制）
    public let dubIds: [UUID]          // 该槽可选变体（已按"参与组合"过滤）
    public init(isLocked: Bool, includeOriginal: Bool, dubIds: [UUID]) {
        self.isLocked = isLocked
        self.includeOriginal = includeOriginal
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

    /// 每个非锁定槽的可选集合 = (includeOriginal ? [原声] : []) + 参与变体；空则兜底原声。
    /// 锁定槽恒原声。includeOriginal 现为**逐槽**控制（`SlotOptions.includeOriginal`）。
    public static func generate(slots: [SlotOptions], limit: Int) -> CombinationResult {
        // 每槽的实际可选集合（升序保证确定性）
        let choices: [[UUID?]] = slots.map { slot in
            if slot.isLocked { return [nil] }
            let variants = slot.dubIds.sorted { $0.uuidString < $1.uuidString }.map { Optional($0) }
            let withOriginal: [UUID?] = (slot.includeOriginal ? [nil] : []) + variants
            return withOriginal.isEmpty ? [nil] : withOriginal       // 空则兜底原声
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
