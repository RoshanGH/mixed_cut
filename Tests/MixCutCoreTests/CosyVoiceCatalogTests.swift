import Testing
@testable import MixCutCore

@Suite("CosyVoiceCatalog 音色目录")
struct CosyVoiceCatalogTests {
    @Test("模型标识为 cosyvoice-v2")
    func modelId() {
        #expect(CosyVoiceCatalog.model == "cosyvoice-v2")
    }

    @Test("音色数量充足（≥ 40），且无重复 id")
    func countAndUnique() {
        let all = CosyVoiceCatalog.all
        #expect(all.count >= 40)
        let ids = all.map(\.id)
        #expect(Set(ids).count == ids.count) // 无重复
    }

    @Test("全部为普通话音色（dialect 为 nil）")
    func allMandarin() {
        #expect(CosyVoiceCatalog.all.allSatisfy { $0.dialect == nil })
    }

    @Test("前 10 为广告/带货人设，且第一个是带货女主播")
    func top10AdPersonas() {
        let top = VoiceCatalog.top(10)
        #expect(top.count == 10)
        #expect(top.first?.id == "longyingxiao")
        #expect(top.contains { $0.id == "longanchong" })  // 带货销售男
        #expect(top.contains { $0.id == "longanxuan" })   // 经典女主播
    }

    @Test("VoiceCatalog 查询：命中返回名，未命中回退 id")
    func lookup() {
        #expect(VoiceCatalog.voice(id: "longyingxiao")?.displayName == "龙樱晓")
        #expect(VoiceCatalog.displayName(id: "longyingxiao") == "龙樱晓")
        #expect(VoiceCatalog.displayName(id: "不存在的id") == "不存在的id")
        #expect(VoiceCatalog.voice(id: "不存在的id") == nil)
    }

    @Test("displayName / summary 均非空")
    func nonEmptyFields() {
        #expect(CosyVoiceCatalog.all.allSatisfy { !$0.displayName.isEmpty && !$0.summary.isEmpty })
    }
}
