import Testing
import Foundation
@testable import MixCutCore

@Suite("VariantSelector")
struct VariantSelectorTests {
    private func opt(_ v: String, _ t: Int) -> DubOption { DubOption(id: UUID(), voiceId: v, textVariantIndex: t) }

    @Test("锁定段 → nil")
    func lockedIsNil() {
        let slots = [SlotInput(isVoiceLocked: true, options: [opt("Cherry", 0)])]
        #expect(VariantSelector.assign(slots: slots, mode: .mixed, variationSeed: 0) == [nil])
    }

    @Test("无候选 → nil")
    func emptyOptionsIsNil() {
        let slots = [SlotInput(isVoiceLocked: false, options: [])]
        #expect(VariantSelector.assign(slots: slots, mode: .mixed, variationSeed: 0) == [nil])
    }

    @Test("unified 只选指定音色的候选")
    func unifiedFiltersVoice() {
        let cherry = opt("Cherry", 0), ethan = opt("Ethan", 0)
        let slots = [SlotInput(isVoiceLocked: false, options: [cherry, ethan])]
        let picked = VariantSelector.assign(slots: slots, mode: .unified(voiceId: "Ethan"), variationSeed: 0)
        #expect(picked == [ethan.id])
    }

    @Test("unified 指定音色无候选 → nil（回退原声）")
    func unifiedMissingVoiceIsNil() {
        let slots = [SlotInput(isVoiceLocked: false, options: [opt("Cherry", 0)])]
        let picked = VariantSelector.assign(slots: slots, mode: .unified(voiceId: "Moon"), variationSeed: 0)
        #expect(picked == [nil])
    }

    @Test("mixed 用 seed 确定性轮换")
    func mixedRotatesBySeed() {
        let a = opt("Cherry", 0), b = opt("Ethan", 1)
        let slots = [SlotInput(isVoiceLocked: false, options: [a, b])]
        #expect(VariantSelector.assign(slots: slots, mode: .mixed, variationSeed: 0) == [a.id])
        #expect(VariantSelector.assign(slots: slots, mode: .mixed, variationSeed: 1) == [b.id])
    }

    @Test("逐槽位移确定性")
    func perSlotOffset() {
        let a = opt("Cherry", 0), b = opt("Cherry", 1)
        let slots = [
            SlotInput(isVoiceLocked: false, options: [a, b]),
            SlotInput(isVoiceLocked: false, options: [a, b])
        ]
        let picked = VariantSelector.assign(slots: slots, mode: .mixed, variationSeed: 0)
        #expect(picked == [a.id, b.id])   // slot0:(0+0)%2=0→a; slot1:(0+1)%2=1→b
    }
}
