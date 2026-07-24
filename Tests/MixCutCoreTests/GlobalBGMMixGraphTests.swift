import Testing
@testable import MixCutCore

@Suite("整片 BGM 铺底滤镜图")
struct GlobalBGMMixGraphTests {

    @Test("BGM 截断到成片时长并按音量淡出")
    func basicGraph() {
        let g = GlobalBGMMixGraphBuilder.filterComplex(pieceDuration: 30, bgmVolume: 0.6)
        #expect(g.contains("[1:a]atrim=0:30.000"))
        #expect(g.contains("volume=0.60"))
        #expect(g.contains("afade=t=out:st=29.000:d=1.000"))
        #expect(g.contains("[0:a][bgm]amix=inputs=2:duration=first:normalize=0[aout]"))
    }

    @Test("音量夹取到 0…1")
    func volumeClamped() {
        #expect(GlobalBGMMixGraphBuilder.filterComplex(pieceDuration: 10, bgmVolume: 1.5).contains("volume=1.00"))
        #expect(GlobalBGMMixGraphBuilder.filterComplex(pieceDuration: 10, bgmVolume: -1).contains("volume=0.00"))
    }

    @Test("成片短于淡出时长时淡出从 0 开始且不超片长")
    func shortPiece() {
        let g = GlobalBGMMixGraphBuilder.filterComplex(pieceDuration: 0.5, bgmVolume: 0.6)
        #expect(g.contains("afade=t=out:st=0.000:d=0.500"))
    }
}
