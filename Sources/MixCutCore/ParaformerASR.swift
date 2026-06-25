import Foundation

/// paraformer 实时 ASR 的一条句子结果（来自 result-generated 的 output.sentence）。
public struct ASRResultSentence: Equatable, Sendable {
    public let text: String
    public let sentenceEnd: Bool
    public init(text: String, sentenceEnd: Bool) {
        self.text = text
        self.sentenceEnd = sentenceEnd
    }
}

/// paraformer-realtime-v2 WebSocket 协议的纯逻辑：消息构造 + 结果汇总。
public enum ParaformerASR {

    /// run-task 指令 JSON（开启识别会话）。
    public static func runTaskJSON(taskId: String, format: String, sampleRate: Int) -> String {
        """
        {"header":{"action":"run-task","task_id":"\(taskId)","streaming":"duplex"},\
        "payload":{"task_group":"audio","task":"asr","function":"recognition",\
        "model":"paraformer-realtime-v2",\
        "parameters":{"format":"\(format)","sample_rate":\(sampleRate)},"input":{}}}
        """
    }

    /// finish-task 指令 JSON（通知服务端音频发完）。
    public static func finishTaskJSON(taskId: String) -> String {
        """
        {"header":{"action":"finish-task","task_id":"\(taskId)","streaming":"duplex"},"payload":{"input":{}}}
        """
    }

    /// 汇总最终文本：只取 sentence_end 的最终句，按序拼接（中文无分隔符），去首尾空白。
    public static func accumulateTranscript(_ sentences: [ASRResultSentence]) -> String {
        sentences.filter { $0.sentenceEnd }
            .map { $0.text }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct ASRWordTimed: Equatable, Sendable {
    public let text: String; public let start: Double; public let end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}
public struct ASRFinalSentence: Equatable, Sendable {
    public let text: String; public let start: Double; public let end: Double; public let words: [ASRWordTimed]
    public init(text: String, start: Double, end: Double, words: [ASRWordTimed]) {
        self.text = text; self.start = start; self.end = end; self.words = words
    }
}
extension ParaformerASR {
    /// 把最终句列表展开成全局 words + 句子列表（时间已是秒，由解析方换算）。
    public static func assembleResult(_ finals: [ASRFinalSentence]) -> (words: [ASRWordTimed], sentences: [ASRFinalSentence]) {
        let words = finals.flatMap { $0.words }
        return (words, finals)
    }
}
