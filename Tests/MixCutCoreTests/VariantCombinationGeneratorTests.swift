import Testing
import Foundation
@testable import MixCutCore

@Suite("VariantCombinationGenerator")
struct VariantCombinationGeneratorTests {

    private func ids(_ n: Int) -> [UUID] { (0..<n).map { _ in UUID() } }
    private func slot(_ locked: Bool, _ orig: Bool, _ dubs: [UUID]) -> SlotOptions {
        SlotOptions(isLocked: locked, includeOriginal: orig, dubIds: dubs)
    }

    @Test("仅变体（不含原版）：两槽各2变体 feasible=4")
    func twoSlotsTwoVariantsNoOriginal() {
        let r = VariantCombinationGenerator.generate(
            slots: [slot(false, false, ids(2)), slot(false, false, ids(2))], limit: 2)
        #expect(r.feasibleCount == 4)
        #expect(r.combinations.count == 2)
        #expect(r.truncated == true)
        #expect(r.combinations[0] != r.combinations[1])
    }

    @Test("锁定槽恒为 nil（忽略 includeOriginal/变体）")
    func lockedSlotAlwaysNil() {
        let r = VariantCombinationGenerator.generate(
            slots: [slot(true, true, ids(2)), slot(false, false, ids(2))], limit: 10)
        #expect(r.feasibleCount == 2)
        #expect(r.combinations.allSatisfy { $0[0] == nil })
    }

    @Test("原版参与+2变体=3档；仅变体不含原版=2档；混合笛卡尔积=3×2=6")
    func perSlotOriginalMix() {
        let r = VariantCombinationGenerator.generate(
            slots: [slot(false, true, ids(2)), slot(false, false, ids(2))], limit: 100)
        #expect(r.feasibleCount == 6)
        #expect(r.combinations.count == 6)
        #expect(r.combinations.contains { $0[0] == nil })
        #expect(r.combinations.allSatisfy { $0[1] != nil })
    }

    @Test("兜底：不含原版且无变体 → 该槽恒原声(nil)，×1")
    func fallbackEmptyToOriginal() {
        let r = VariantCombinationGenerator.generate(
            slots: [slot(false, false, []), slot(false, true, ids(2))], limit: 10)
        #expect(r.feasibleCount == 3)
        #expect(r.combinations.allSatisfy { $0[0] == nil })
    }

    @Test("原版参与：每镜=原+2变体=3选项，4镜→3^4=81 且含全原声一条")
    func includeOriginalFullProduct() {
        let slots = (0..<4).map { _ in slot(false, true, ids(2)) }
        let r = VariantCombinationGenerator.generate(slots: slots, limit: 1000)
        #expect(r.feasibleCount == 81)
        #expect(r.combinations.count == 81)
        #expect(r.combinations.contains { $0.allSatisfy { $0 == nil } })
        let keys = r.combinations.map { $0.map { $0?.uuidString ?? "o" }.joined(separator: ",") }
        #expect(Set(keys).count == 81)
    }

    @Test("全锁定：只1条全 nil")
    func allLocked() {
        let r = VariantCombinationGenerator.generate(
            slots: [slot(true, true, ids(2)), slot(true, true, ids(2))], limit: 10)
        #expect(r.feasibleCount == 1)
        #expect(r.combinations == [[nil, nil]])
        #expect(r.truncated == false)
    }

    @Test("limit 大于 feasible 不截断")
    func limitExceedsFeasible() {
        let r = VariantCombinationGenerator.generate(slots: [slot(false, false, ids(2))], limit: 99)
        #expect(r.feasibleCount == 2)
        #expect(r.combinations.count == 2)
        #expect(r.truncated == false)
    }

    @Test("limit<=0 返回空")
    func zeroLimit() {
        let r = VariantCombinationGenerator.generate(slots: [slot(false, true, ids(2))], limit: 0)
        #expect(r.combinations.isEmpty)
    }
}
