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

private func seg(_ id: String, _ tags: [String] = [], q: Double = 1, d: Double = 1) -> SegmentDescriptor {
    SegmentDescriptor(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(id)")!,
                      tags: tags, text: "t\(id)", duration: d, quality: q)
}

@Test func candidatePool_matchesUnionOfTags() {
    let segs = [
        seg("01", ["痛点"]),
        seg("02", ["产品方案"]),
        seg("03", ["痛点", "过渡"]),
        seg("04", ["行动号召"]),
    ]
    let slot = NarrativeSlot(order: 0, tags: ["痛点", "产品方案"])
    let pool = NarrativeStructureEngine.candidatePool(for: slot, in: segs)
    #expect(Set(pool.map(\.id)) == Set([seg("01").id, seg("02").id, seg("03").id]))
}

@Test func candidatePool_emptyWhenNoTagOverlap() {
    let segs = [seg("01", ["痛点"])]
    let slot = NarrativeSlot(order: 0, tags: ["行动号召"])
    #expect(NarrativeStructureEngine.candidatePool(for: slot, in: segs).isEmpty)
}

@Test func topCandidates_sortsByQualityThenDurationAndCaps() {
    let segs = [
        seg("01", ["x"], q: 0.5, d: 2),
        seg("02", ["x"], q: 0.9, d: 1),
        seg("03", ["x"], q: 0.9, d: 3),
        seg("04", ["x"], q: 0.7, d: 1),
    ]
    let top = NarrativeStructureEngine.topCandidates(segs, limit: 2)
    // 质量降序，质量相同按时长降序：03(0.9,3) > 02(0.9,1)
    #expect(top.map(\.id) == [seg("03").id, seg("02").id])
}

@Test func topCandidates_limitLargerThanCountReturnsAll() {
    let segs = [seg("01", ["x"]), seg("02", ["x"])]
    #expect(NarrativeStructureEngine.topCandidates(segs, limit: 10).count == 2)
}

@Test func feasibleVariantLimit_isProductCappedByRequested() {
    let pools = [[seg("01",["x"]), seg("02",["x"])], [seg("03",["y"])]] // 2 * 1 = 2
    #expect(NarrativeStructureEngine.feasibleVariantLimit(pools: pools, requested: 5) == 2)
    #expect(NarrativeStructureEngine.feasibleVariantLimit(pools: pools, requested: 1) == 1)
}

@Test func feasibleVariantLimit_zeroIfAnyPoolEmpty() {
    let pools = [[seg("01",["x"])], [SegmentDescriptor]()]
    #expect(NarrativeStructureEngine.feasibleVariantLimit(pools: pools, requested: 3) == 0)
}

@Test func isValidVariant_rejectsWrongCountDupOrOutOfPool() {
    let pools = [[seg("01",["x"]), seg("02",["x"])], [seg("03",["y"])]]
    // 合法：每段选 1 个、在各自池内、无重复
    #expect(NarrativeStructureEngine.isValidVariant([seg("01").id, seg("03").id], pools: pools))
    // 段数不符
    #expect(!NarrativeStructureEngine.isValidVariant([seg("01").id], pools: pools))
    // 第 2 段选了不在池里的 id
    #expect(!NarrativeStructureEngine.isValidVariant([seg("01").id, seg("99",["z"]).id], pools: pools))
    // 重复 id
    #expect(!NarrativeStructureEngine.isValidVariant([seg("01").id, seg("01").id], pools: pools))
}
