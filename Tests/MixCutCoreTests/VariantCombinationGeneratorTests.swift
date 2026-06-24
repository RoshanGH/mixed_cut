import Testing
import Foundation
@testable import MixCutCore

@Suite("VariantCombinationGenerator")
struct VariantCombinationGeneratorTests {

    private func ids(_ n: Int) -> [UUID] { (0..<n).map { _ in UUID() } }

    @Test("两槽各2变体：feasible=4，limit=2 取2条且互不相同")
    func twoSlotsTwoVariants() {
        let a = ids(2), b = ids(2)
        let slots = [SlotOptions(isLocked: false, dubIds: a),
                     SlotOptions(isLocked: false, dubIds: b)]
        let r = VariantCombinationGenerator.generate(slots: slots, limit: 2)
        #expect(r.feasibleCount == 4)
        #expect(r.combinations.count == 2)
        #expect(r.truncated == true)
        #expect(r.combinations[0] != r.combinations[1])
        // 每条都覆盖两个槽
        #expect(r.combinations.allSatisfy { $0.count == 2 })
    }

    @Test("锁定槽恒为 nil")
    func lockedSlotAlwaysNil() {
        let a = ids(2)
        let slots = [SlotOptions(isLocked: true, dubIds: a),
                     SlotOptions(isLocked: false, dubIds: a)]
        let r = VariantCombinationGenerator.generate(slots: slots, limit: 10)
        #expect(r.feasibleCount == 2)            // 锁定槽只有1种(nil)，第二槽2种
        #expect(r.combinations.allSatisfy { $0[0] == nil })
    }

    @Test("无变体槽恒为 nil（原声）")
    func emptyOptionsSlotNil() {
        let b = ids(3)
        let slots = [SlotOptions(isLocked: false, dubIds: []),
                     SlotOptions(isLocked: false, dubIds: b)]
        let r = VariantCombinationGenerator.generate(slots: slots, limit: 10)
        #expect(r.feasibleCount == 3)
        #expect(r.combinations.allSatisfy { $0[0] == nil })
        #expect(r.combinations.count == 3)
    }

    @Test("全锁定：只1条全 nil")
    func allLocked() {
        let slots = [SlotOptions(isLocked: true, dubIds: ids(2)),
                     SlotOptions(isLocked: true, dubIds: ids(2))]
        let r = VariantCombinationGenerator.generate(slots: slots, limit: 10)
        #expect(r.feasibleCount == 1)
        #expect(r.combinations.count == 1)
        #expect(r.combinations[0] == [nil, nil])
        #expect(r.truncated == false)
    }

    @Test("limit 大于 feasible：只返回 feasible 条，不截断")
    func limitExceedsFeasible() {
        let a = ids(2)
        let slots = [SlotOptions(isLocked: false, dubIds: a)]
        let r = VariantCombinationGenerator.generate(slots: slots, limit: 99)
        #expect(r.feasibleCount == 2)
        #expect(r.combinations.count == 2)
        #expect(r.truncated == false)
    }

    @Test("全部组合互不相同（枚举完整笛卡尔积）")
    func allDistinct() {
        let a = ids(2), b = ids(3)
        let slots = [SlotOptions(isLocked: false, dubIds: a),
                     SlotOptions(isLocked: false, dubIds: b)]
        let r = VariantCombinationGenerator.generate(slots: slots, limit: 100)
        #expect(r.feasibleCount == 6)
        #expect(r.combinations.count == 6)
        let asStrings = r.combinations.map { combo in combo.map { $0?.uuidString ?? "nil" }.joined(separator: ",") }
        #expect(Set(asStrings).count == 6)   // 全互不相同
    }

    @Test("limit<=0 返回空")
    func zeroLimit() {
        let r = VariantCombinationGenerator.generate(slots: [SlotOptions(isLocked: false, dubIds: ids(2))], limit: 0)
        #expect(r.combinations.isEmpty)
    }

    @Test("includeOriginal: 每镜=原声+2变体=3选项，4镜→3^4=81 全排列")
    func includeOriginalFullProduct() {
        let slots = (0..<4).map { _ in SlotOptions(isLocked: false, dubIds: ids(2)) }
        let r = VariantCombinationGenerator.generate(slots: slots, limit: 1000, includeOriginal: true)
        #expect(r.feasibleCount == 81)      // 3^4
        #expect(r.combinations.count == 81)
        #expect(r.truncated == false)
        // 含一条「全原声」组合
        #expect(r.combinations.contains { $0.allSatisfy { $0 == nil } })
        // 全互不相同
        let keys = r.combinations.map { $0.map { $0?.uuidString ?? "o" }.joined(separator: ",") }
        #expect(Set(keys).count == 81)
    }

    @Test("includeOriginal 下锁定槽仍恒原声")
    func includeOriginalLockedStillNil() {
        let slots = [SlotOptions(isLocked: true, dubIds: ids(2)),
                     SlotOptions(isLocked: false, dubIds: ids(2))]
        let r = VariantCombinationGenerator.generate(slots: slots, limit: 100, includeOriginal: true)
        #expect(r.feasibleCount == 3)       // 锁定1 × 非锁定(原+2)=3
        #expect(r.combinations.allSatisfy { $0[0] == nil })
    }
}
