import Testing
import Foundation
@testable import MixCutCore

@Test func structureName_joinsTagsByDotAndSlash() {
    let slots = [
        NarrativeSlot(order: 0, tags: ["痛点"]),
        NarrativeSlot(order: 1, tags: ["产品方案"]),
        NarrativeSlot(order: 2, tags: ["效果展示", "信任背书"]),
        NarrativeSlot(order: 3, tags: ["行动号召"]),
    ]
    #expect(NarrativeStructureEngine.structureName(for: slots)
        == "痛点 · 产品方案 · 效果展示/信任背书 · 行动号召")
}

@Test func structureName_sortsByOrder() {
    let slots = [
        NarrativeSlot(order: 2, tags: ["C"]),
        NarrativeSlot(order: 0, tags: ["A"]),
        NarrativeSlot(order: 1, tags: ["B"]),
    ]
    #expect(NarrativeStructureEngine.structureName(for: slots) == "A · B · C")
}
