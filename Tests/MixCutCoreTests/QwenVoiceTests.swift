import Testing
@testable import MixCutCore

@Suite("QwenVoiceCatalog 音色目录")
struct QwenVoiceTests {
    @Test("目录非空且包含已验证可用的 Cherry")
    func containsCherry() {
        #expect(QwenVoiceCatalog.all.count >= 40)
        #expect(QwenVoiceCatalog.all.contains { $0.id == "Cherry" && $0.displayName == "芊悦" })
    }

    @Test("voice id 全局唯一")
    func uniqueIds() {
        let ids = QwenVoiceCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("方言音色带 dialect 标注（如四川-晴儿 Sunny）")
    func dialectTagged() {
        let sunny = QwenVoiceCatalog.all.first { $0.id == "Sunny" }
        #expect(sunny?.dialect == "四川话")
    }

    @Test("普通话音色 dialect 为 nil（如 Cherry）")
    func mandarinNoDialect() {
        let cherry = QwenVoiceCatalog.all.first { $0.id == "Cherry" }
        #expect(cherry?.dialect == nil)
    }
}
