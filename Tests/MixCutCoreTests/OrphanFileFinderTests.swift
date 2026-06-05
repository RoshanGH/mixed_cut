import Testing
@testable import MixCutCore

@Test func orphan_returnsFilesNotReferenced() {
    let onDisk = ["/v/a.mp4", "/v/b.mp4", "/t/x.jpg"]
    let referenced: Set<String> = ["/v/a.mp4", "/t/x.jpg"]
    #expect(OrphanFileFinder.orphanFiles(onDisk: onDisk, referenced: referenced) == ["/v/b.mp4"])
}

@Test func orphan_emptyWhenAllReferenced() {
    let onDisk = ["/v/a.mp4"]
    #expect(OrphanFileFinder.orphanFiles(onDisk: onDisk, referenced: ["/v/a.mp4"]).isEmpty)
}

@Test func orphan_normalizesTrailingSlashAndCase() {
    // 末尾斜杠 + 大小写差异应视为同一路径（macOS 默认大小写不敏感）
    let onDisk = ["/V/A.mp4/"]
    let referenced: Set<String> = ["/v/a.mp4"]
    #expect(OrphanFileFinder.orphanFiles(onDisk: onDisk, referenced: referenced).isEmpty)
}

@Test func orphan_allUnreferencedReturnedInInputOrder() {
    let onDisk = ["/v/b.mp4", "/v/a.mp4"]
    #expect(OrphanFileFinder.orphanFiles(onDisk: onDisk, referenced: []) == ["/v/b.mp4", "/v/a.mp4"])
}
