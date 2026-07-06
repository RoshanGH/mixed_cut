import Foundation
import Testing
@testable import MixCutCore

struct ShotEditRulesTests {
    @Test("时长在 [2,10] 才可编辑")
    func eligibility() {
        #expect(ShotEditRules.isEditable(durationSeconds: 2.0) == true)
        #expect(ShotEditRules.isEditable(durationSeconds: 10.0) == true)
        #expect(ShotEditRules.isEditable(durationSeconds: 1.99) == false)
        #expect(ShotEditRules.isEditable(durationSeconds: 10.1) == false)
    }

    @Test("不可编辑给出中文原因")
    func reason() {
        #expect(ShotEditRules.ineligibleReason(durationSeconds: 12.3)?.contains("10") == true)
        #expect(ShotEditRules.ineligibleReason(durationSeconds: 1.0)?.contains("2") == true)
        #expect(ShotEditRules.ineligibleReason(durationSeconds: 5.0) == nil)
    }

    @Test("占位选择：每坑必选且唯一、顺序完整 → 通过")
    func validSelection() {
        let sel = [1: SlotChoice.original, 2: SlotChoice.variant(UUID()), 3: SlotChoice.original]
        #expect(ShotEditRules.canCompose(slotCount: 3, selections: sel) == true)
    }

    @Test("有坑未选 → 不通过")
    func missingSlot() {
        let sel = [1: SlotChoice.original, 3: SlotChoice.original]
        #expect(ShotEditRules.canCompose(slotCount: 3, selections: sel) == false)
    }
}
