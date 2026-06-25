import Foundation

/// 一个可被组合引擎选中的配音变体候选。
public struct DubOption: Equatable, Sendable {
    public let id: UUID
    public let voiceId: String
    public let textVariantIndex: Int
    public init(id: UUID, voiceId: String, textVariantIndex: Int) {
        self.id = id; self.voiceId = voiceId; self.textVariantIndex = textVariantIndex
    }
}

/// 一个时间线槽位（对应一个 SchemeSegment）。
public struct SlotInput: Equatable, Sendable {
    public let isVoiceLocked: Bool
    public let options: [DubOption]
    public init(isVoiceLocked: Bool, options: [DubOption]) {
        self.isVoiceLocked = isVoiceLocked; self.options = options
    }
}

/// 音色分配模式。
public enum VariantSelectorMode: Equatable, Sendable {
    case unified(voiceId: String)
    case mixed
}

/// 组合引擎逐槽变体分配（纯函数）。
public enum VariantSelector {
    /// 为每个槽位选定一个变体 id（锁定段/无候选 → nil）。
    /// 用 variationSeed 做确定性轮换：同 seed 同结果、不同 seed 多样。
    public static func assign(slots: [SlotInput], mode: VariantSelectorMode, variationSeed: Int) -> [UUID?] {
        slots.enumerated().map { index, slot in
            guard !slot.isVoiceLocked else { return nil }
            let candidates: [DubOption]
            switch mode {
            case .unified(let voiceId):
                candidates = slot.options.filter { $0.voiceId == voiceId }
            case .mixed:
                candidates = slot.options
            }
            guard !candidates.isEmpty else { return nil }
            let pick = ((variationSeed + index) % candidates.count + candidates.count) % candidates.count
            return candidates[pick].id
        }
    }
}
