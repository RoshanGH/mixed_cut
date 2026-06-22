import Testing
@testable import MixCutCore

@Suite("DubStaleness 失效判定")
struct DubStalenessTests {

    // MARK: - 辅助

    private func makeSnapshot(start: Int = 10, end: Int = 50, hash: String = "abc123") -> DubSnapshot {
        DubSnapshot(recordedStartFrame: start, recordedEndFrame: end, recordedTextHash: hash)
    }

    // MARK: - 测试 1：未曾生成（recordedStartFrame == -1）→ stale

    @Test("未曾生成（recordedStartFrame=-1）→ stale")
    func neverGenerated() {
        let snap = DubSnapshot(recordedStartFrame: -1, recordedEndFrame: -1, recordedTextHash: "")
        let result = DubStaleness.check(snapshot: snap,
                                        currentStartFrame: 10,
                                        currentEndFrame: 50,
                                        currentTextHash: "abc")
        guard case .stale(let reasons) = result else {
            Issue.record("期望 stale，实际 fresh")
            return
        }
        #expect(!reasons.isEmpty)
    }

    // MARK: - 测试 2：三者均未变化 → fresh

    @Test("三者均未变化 → fresh")
    func allMatch() {
        let snap = makeSnapshot()
        let result = DubStaleness.check(snapshot: snap,
                                        currentStartFrame: 10,
                                        currentEndFrame: 50,
                                        currentTextHash: "abc123")
        #expect(result == .fresh)
    }

    // MARK: - 测试 3：仅 startFrame 变化 → stale，原因含 startFrameChanged

    @Test("仅 startFrame 变化 → stale + startFrameChanged")
    func startFrameChanged() {
        let snap = makeSnapshot(start: 10)
        let result = DubStaleness.check(snapshot: snap,
                                        currentStartFrame: 12,
                                        currentEndFrame: 50,
                                        currentTextHash: "abc123")
        guard case .stale(let reasons) = result else {
            Issue.record("期望 stale")
            return
        }
        let hasStartChanged = reasons.contains {
            if case .startFrameChanged(let cur, let rec) = $0 {
                return cur == 12 && rec == 10
            }
            return false
        }
        #expect(hasStartChanged)
    }

    // MARK: - 测试 4：仅 textHash 变化 → stale，原因含 textHashChanged

    @Test("仅 textHash 变化 → stale + textHashChanged")
    func textHashChanged() {
        let snap = makeSnapshot(hash: "old_hash")
        let result = DubStaleness.check(snapshot: snap,
                                        currentStartFrame: 10,
                                        currentEndFrame: 50,
                                        currentTextHash: "new_hash")
        guard case .stale(let reasons) = result else {
            Issue.record("期望 stale")
            return
        }
        let hasTextChanged = reasons.contains {
            if case .textHashChanged(let cur, let rec) = $0 {
                return cur == "new_hash" && rec == "old_hash"
            }
            return false
        }
        #expect(hasTextChanged)
    }

    // MARK: - 测试 5：多字段同时变化 → stale，原因包含多条

    @Test("多字段同时变化 → stale，reasons ≥ 2")
    func multipleFieldsChanged() {
        let snap = makeSnapshot(start: 10, end: 50, hash: "old")
        let result = DubStaleness.check(snapshot: snap,
                                        currentStartFrame: 15,
                                        currentEndFrame: 60,
                                        currentTextHash: "new")
        guard case .stale(let reasons) = result else {
            Issue.record("期望 stale")
            return
        }
        #expect(reasons.count >= 2)
    }
}
