import Testing
@testable import MixCutCore

@Suite("BGM 上传重名去重")
struct UniqueFileNamerTests {
    @Test("无冲突原样返回")
    func noConflict() {
        #expect(UniqueFileNamer.uniqueName(for: "歌.mp3", existing: []) == "歌.mp3")
    }

    @Test("冲突时从 2 递增")
    func conflictAppendsCounter() {
        #expect(UniqueFileNamer.uniqueName(for: "歌.mp3", existing: ["歌.mp3"]) == "歌 2.mp3")
        #expect(UniqueFileNamer.uniqueName(for: "歌.mp3", existing: ["歌.mp3", "歌 2.mp3"]) == "歌 3.mp3")
    }

    @Test("无扩展名文件也正确加后缀")
    func noExtension() {
        #expect(UniqueFileNamer.uniqueName(for: "bgm", existing: ["bgm"]) == "bgm 2")
    }
}
