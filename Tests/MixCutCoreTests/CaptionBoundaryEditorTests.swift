import Testing
@testable import MixCutCore

@Suite("CaptionBoundaryEditor 联动分界")
struct CaptionBoundaryEditorTests {

    /// 造两句：左句 "你好"(0~1)、右句 "世界"(1~2)，逐字均匀。
    private func twoLines() -> [CaptionLine] {
        let l0 = CaptionLine(text: "你好", start: 0, end: 1, chars: [
            TimedChar(ch: "你", end: 0.5), TimedChar(ch: "好", end: 1.0),
        ])
        let l1 = CaptionLine(text: "世界", start: 1, end: 2, chars: [
            TimedChar(ch: "世", end: 1.5), TimedChar(ch: "界", end: 2.0),
        ])
        return [l0, l1]
    }

    @Test("止右推过下一句首字 → 该字迁入左句")
    func extendMergesOneChar() {
        // 分界推到 1.5：右句"世"(end=1.5)归左、"界"(end=2.0)留右
        let out = CaptionBoundaryEditor.moveBoundary(twoLines(), after: 0, to: 1.5)
        #expect(out.count == 2)
        #expect(out[0].text == "你好世")
        #expect(out[0].chars.count == 3)
        #expect(abs(out[0].end - 1.5) < 0.001)
        #expect(out[1].text == "界")
        #expect(abs(out[1].start - 1.5) < 0.001)
    }

    @Test("止推到右句末 → 右句被吃满，合并删除")
    func fullCoverDeletesRight() {
        let out = CaptionBoundaryEditor.moveBoundary(twoLines(), after: 0, to: 2.0)
        #expect(out.count == 1)
        #expect(out[0].text == "你好世界")
        #expect(out[0].chars.count == 4)
        #expect(abs(out[0].end - 2.0) < 0.001)
    }

    @Test("止回缩到左句内部 → 字迁回右句")
    func shrinkMovesCharsRight() {
        // 先合并成一句，再从合并句把分界拉回 0.5
        let merged = CaptionBoundaryEditor.moveBoundary(twoLines(), after: 0, to: 2.0) // 单句"你好世界"
        // 单句无法再 moveBoundary(after:0)（只有一句），换个基准：从原始两句把分界拉到 0.5
        let out = CaptionBoundaryEditor.moveBoundary(twoLines(), after: 0, to: 0.5)
        #expect(merged.count == 1)              // 合并有效
        #expect(out.count == 2)
        #expect(out[0].text == "你")            // "好"(end=1.0)>0.5 迁到右句
        #expect(out[1].text == "好世界")
        #expect(abs(out[0].end - 0.5) < 0.001)
    }

    @Test("不允许把左句掏空（分界压到首字之前 → 原样保留）")
    func neverEmptyLeft() {
        // t 远小于首字 end → 若归左的字为空，保持当前分区不动（绝不掏空左句）
        let out = CaptionBoundaryEditor.moveBoundary(twoLines(), after: 0, to: -5, minGap: 0.05)
        #expect(out.count == 2)
        #expect(!out[0].text.isEmpty)
        #expect(out[0].text == "你好")           // 左句原样，不被掏空
    }

    @Test("越界索引 → 原样返回")
    func outOfRangeNoop() {
        let src = twoLines()
        #expect(CaptionBoundaryEditor.moveBoundary(src, after: 1, to: 1.5) == src)   // 末句无下一句
        #expect(CaptionBoundaryEditor.moveBoundary(src, after: -1, to: 1.5) == src)
    }

    @Test("手动拆分：在第 k 字后一分为二，分界=该字时间")
    func splitAfterChar() {
        // 「你好世界」四字：你(0.5)好(1.0)世(1.5)界(2.0)，在第 1 字(好,k=1)后拆
        let one = [CaptionLine(text: "你好世界", start: 0, end: 2, chars: [
            TimedChar(ch: "你", end: 0.5), TimedChar(ch: "好", end: 1.0),
            TimedChar(ch: "世", end: 1.5), TimedChar(ch: "界", end: 2.0),
        ])]
        let out = CaptionBoundaryEditor.splitLine(one, at: 0, afterCharIndex: 1)
        #expect(out.count == 2)
        #expect(out[0].text == "你好")
        #expect(abs(out[0].start - 0.0) < 0.001)
        #expect(abs(out[0].end - 1.0) < 0.001)     // 分界=好.end
        #expect(out[1].text == "世界")
        #expect(abs(out[1].start - 1.0) < 0.001)
        #expect(abs(out[1].end - 2.0) < 0.001)
        #expect(out[0].chars.count == 2 && out[1].chars.count == 2)
    }

    @Test("拆分越界/不足两字 → 原样返回")
    func splitGuards() {
        let two = twoLines()
        #expect(CaptionBoundaryEditor.splitLine(two, at: 5, afterCharIndex: 0) == two)   // 句越界
        // 单字句拆不出两句
        let single = [CaptionLine(text: "好", start: 0, end: 1, chars: [TimedChar(ch: "好", end: 1)])]
        #expect(CaptionBoundaryEditor.splitLine(single, at: 0, afterCharIndex: 0) == single)
        // k 越界（最后一字后无法拆）
        #expect(CaptionBoundaryEditor.splitLine(two, at: 0, afterCharIndex: 1) == two)   // 句"你好"只有k∈{0}
    }

    @Test("拆分后可再合并回去（往返一致）")
    func splitThenMergeRoundTrip() {
        let one = [CaptionLine(text: "你好世界", start: 0, end: 2, chars: [
            TimedChar(ch: "你", end: 0.5), TimedChar(ch: "好", end: 1.0),
            TimedChar(ch: "世", end: 1.5), TimedChar(ch: "界", end: 2.0),
        ])]
        let split = CaptionBoundaryEditor.splitLine(one, at: 0, afterCharIndex: 1)   // 你好 | 世界
        // 把第 0 句止拉满 → 合并删除右句，恢复单句
        let merged = CaptionBoundaryEditor.moveBoundary(split, after: 0, to: 2.0)
        #expect(merged.count == 1)
        #expect(merged[0].text == "你好世界")
    }

    @Test("旧数据无 chars → 按整句均匀合成再重分")
    func legacyNoChars() {
        let l0 = CaptionLine(text: "你好", start: 0, end: 1)   // chars 空
        let l1 = CaptionLine(text: "世界", start: 1, end: 2)
        let out = CaptionBoundaryEditor.moveBoundary([l0, l1], after: 0, to: 1.5)
        #expect(out[0].text == "你好世")
        #expect(out[1].text == "界")
    }
}
