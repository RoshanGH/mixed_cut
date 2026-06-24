import Testing
@testable import MixCutCore

@Suite("ParaformerASR")
struct ParaformerASRTests {
    @Test("run-task JSON 含关键字段")
    func runTask() {
        let s = ParaformerASR.runTaskJSON(taskId: "tid", format: "pcm", sampleRate: 16000)
        #expect(s.contains("\"action\":\"run-task\"") || s.contains("\"action\": \"run-task\""))
        #expect(s.contains("paraformer-realtime-v2"))
        #expect(s.contains("\"task\":\"asr\"") || s.contains("\"task\": \"asr\""))
        #expect(s.contains("recognition"))
        #expect(s.contains("16000"))
        #expect(s.contains("tid"))
    }

    @Test("finish-task JSON 含 finish-task 与 task_id")
    func finishTask() {
        let s = ParaformerASR.finishTaskJSON(taskId: "tid")
        #expect(s.contains("finish-task"))
        #expect(s.contains("tid"))
    }

    @Test("只拼接 sentence_end 的最终句，忽略中间 partial")
    func accumulateFinalsOnly() {
        let evts = [
            ASRResultSentence(text: "你好", sentenceEnd: false),
            ASRResultSentence(text: "你好世界", sentenceEnd: true),
            ASRResultSentence(text: "下单", sentenceEnd: false),
            ASRResultSentence(text: "下单立减十元", sentenceEnd: true)
        ]
        #expect(ParaformerASR.accumulateTranscript(evts) == "你好世界下单立减十元")
    }

    @Test("无 final → 空串")
    func noFinals() {
        let evts = [ASRResultSentence(text: "半句", sentenceEnd: false)]
        #expect(ParaformerASR.accumulateTranscript(evts) == "")
    }
}

@Suite("ParaformerASR assembleResult")
struct ParaformerASRAssembleTests {
    @Test("按序展开所有 final 句的 words")
    func assemble() {
        let s1 = ASRFinalSentence(text: "你好世界", start: 0.1, end: 0.9, words: [
            ASRWordTimed(text: "你好", start: 0.1, end: 0.5),
            ASRWordTimed(text: "世界", start: 0.5, end: 0.9)])
        let s2 = ASRFinalSentence(text: "下单", start: 1.0, end: 1.4, words: [
            ASRWordTimed(text: "下单", start: 1.0, end: 1.4)])
        let r = ParaformerASR.assembleResult([s1, s2])
        #expect(r.words.map(\.text) == ["你好", "世界", "下单"])
        #expect(r.words.first?.start == 0.1)
        #expect(r.words.last?.end == 1.4)
        #expect(r.sentences.count == 2)
    }
    @Test("空输入 → 空结果")
    func empty() {
        let r = ParaformerASR.assembleResult([])
        #expect(r.words.isEmpty)
        #expect(r.sentences.isEmpty)
    }
}
