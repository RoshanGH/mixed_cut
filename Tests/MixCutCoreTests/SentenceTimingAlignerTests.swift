import Testing
@testable import MixCutCore

@Suite("SentenceTimingAligner")
struct SentenceTimingAlignerTests {

    private func w(_ t: String, _ s: Double, _ e: Double) -> AlignWord { AlignWord(text: t, start: s, end: e) }

    @Test("按标点切句 + 比例分配（无 words 时用 audioDuration 等比）")
    func proportionalNoWords() {
        // 两句去标点：你好啊(3字) / 今天天气不错(6字) → 3:6 比例，跨度[0,10]
        let lines = SentenceTimingAligner.align(
            text: "你好啊。今天天气不错！", words: [], audioDuration: 10, segmentDuration: 12)
        #expect(lines.count == 2)
        #expect(lines[0].text.contains("你好"))
        #expect(abs(lines[0].start - 0) < 0.01)
        #expect(abs(lines[0].end - 10.0 * 3.0 / 9.0) < 0.01)   // ≈3.333
        #expect(abs(lines[1].end - 10.0) < 0.01)
        #expect(lines[0].end <= lines[1].start + 0.001)
    }

    @Test("有 words 时用整体语音跨度做比例基准")
    func proportionalWithSpan() {
        let words = [w("你好啊哈", 1.0, 5.0), w("今天不错", 5.0, 9.0)]
        let lines = SentenceTimingAligner.align(
            text: "你好啊哈。今天不错。", words: words, audioDuration: 10, segmentDuration: 12)
        #expect(lines.count == 2)
        #expect(lines[0].start >= 0.99 && lines[0].start <= 1.01)
        #expect(lines[1].end <= 9.01)
    }

    @Test("clamp 到 [0, segmentDuration]")
    func clamp() {
        let lines = SentenceTimingAligner.align(
            text: "唯一一句话。", words: [w("唯一一句话", 0, 100)], audioDuration: 100, segmentDuration: 8)
        #expect(lines.count == 1)
        #expect(lines[0].start >= 0)
        #expect(lines[0].end <= 8.0 + 0.001)
    }

    @Test("空文本 → 空结果，不崩")
    func emptyText() {
        #expect(SentenceTimingAligner.align(text: "  。！", words: [], audioDuration: 5, segmentDuration: 5).isEmpty)
    }

    @Test("每句填充逐字时间 chars（供编辑器按时间重分组）")
    func charsPopulated() {
        let lines = SentenceTimingAligner.align(
            text: "你好啊。今天天气不错！", words: [], audioDuration: 10, segmentDuration: 12)
        #expect(lines[0].chars.count == 3)
        #expect(lines[1].chars.count == 6)
        #expect(lines[0].chars.map(\.ch).joined() == "你好啊")
        #expect(lines[0].chars.last!.end <= lines[0].end + 0.001)
        // 字时间升序
        #expect(lines[1].chars[0].end < lines[1].chars[5].end)
    }

    @Test("中间句匹配失败时按锚点插值，绝不塌成零宽度")
    func failedMiddleInterpolated() {
        // 4 句：只有首尾能和 ASR 匹配（中间两句含数字/无对应词），中间句必须拿到可见时长
        // ASR 时间线只覆盖「你好」(0~2) 和「再见」(8~10)，中间空档 [2,8] 留给 s2/s3 插值
        let words = [w("你好", 0, 2), w("再见", 8, 10)]
        let lines = SentenceTimingAligner.align(
            text: "你好。中间第一句话。中间第二句更长一些。再见。",
            words: words, audioDuration: 10, segmentDuration: 11)
        #expect(lines.count == 4)
        for l in lines {
            #expect(l.end - l.start > 0.1)          // 无零宽度句
        }
        // 单调不重叠
        for k in 1..<lines.count { #expect(lines[k].start >= lines[k - 1].end - 0.001) }
        // 更长的 s3 分到的时间应比 s2 多（按字数插值）
        #expect((lines[2].end - lines[2].start) > (lines[1].end - lines[1].start))
    }

    @Test("阿拉伯数字折叠成中文单字后可与 ASR 匹配")
    func digitFoldingMatches() {
        // 台词「69」，ASR 念「六十九」→ 折叠后「六九」跳过「十」匹配成功
        let words = [w("六十九", 1.0, 3.0), w("很划算", 3.0, 5.0)]
        let lines = SentenceTimingAligner.align(
            text: "69。很划算。", words: words, audioDuration: 5, segmentDuration: 6)
        #expect(lines.count == 2)
        #expect(lines[0].start >= 0.99 && lines[0].start <= 1.01)   // 命中「六…九」起点
        #expect(lines[0].end <= 3.01)
    }

    @Test("多种句末标点 + 换行切句")
    func punctuation() {
        let lines = SentenceTimingAligner.align(
            text: "一句话？\n第二句！第三句。", words: [], audioDuration: 9, segmentDuration: 9)
        #expect(lines.count == 3)
    }
}
