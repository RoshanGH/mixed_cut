import Foundation

enum ASRError: Error, LocalizedError {
    case missingAPIKey, connectionFailed, recognitionFailed
    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "尚未配置千问 API Key，请在设置中填写后重试"
        case .connectionFailed: return "无法连接阿里云语音识别服务，请检查网络"
        case .recognitionFailed: return "语音识别失败，请重试"
        }
    }
}

/// 用 DashScope paraformer-realtime-v2 对一段本地 PCM 音频做识别（WebSocket 流式，不传文件 URL）。
actor QwenASRClient {
    private static let endpoint = URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference/")!

    func transcribe(pcmPath: String, sampleRate: Int = 16000) async throws -> String {
        guard let key = KeychainHelper.getAPIKey(for: .qwen), !key.isEmpty else {
            throw ASRError.missingAPIKey
        }
        guard let pcm = FileManager.default.contents(atPath: pcmPath), !pcm.isEmpty else {
            throw ASRError.recognitionFailed
        }

        var request = URLRequest(url: Self.endpoint)
        request.setValue("bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-DataInspection")
        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: request)
        ws.resume()
        defer { ws.cancel(with: .goingAway, reason: nil) }

        let taskId = UUID().uuidString
        var sentences: [ASRResultSentence] = []

        try await ws.send(.string(ParaformerASR.runTaskJSON(taskId: taskId, format: "pcm", sampleRate: sampleRate)))
        try await Self.waitFor(ws, event: "task-started", collect: &sentences)

        let chunk = 3200
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + chunk, pcm.count)
            try await ws.send(.data(pcm.subdata(in: offset..<end)))
            offset = end
        }

        try await ws.send(.string(ParaformerASR.finishTaskJSON(taskId: taskId)))
        try await Self.waitFor(ws, event: "task-finished", collect: &sentences)

        return ParaformerASR.accumulateTranscript(sentences)
    }

    /// 持续读消息直到收到目标 event；把 result-generated 的句子累积进 sentences。
    private static func waitFor(_ ws: URLSessionWebSocketTask, event target: String,
                               collect sentences: inout [ASRResultSentence]) async throws {
        while true {
            let msg = try await ws.receive()
            guard case let .string(text) = msg,
                  let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let header = obj["header"] as? [String: Any],
                  let ev = header["event"] as? String else { continue }
            if ev == "result-generated",
               let payload = obj["payload"] as? [String: Any],
               let output = payload["output"] as? [String: Any],
               let sentence = output["sentence"] as? [String: Any],
               let t = sentence["text"] as? String {
                let endFlag = (sentence["sentence_end"] as? Bool) ?? false
                sentences.append(ASRResultSentence(text: t, sentenceEnd: endFlag))
            }
            if ev == "task-failed" { throw ASRError.recognitionFailed }
            if ev == target { return }
        }
    }

    // MARK: - 整片识别（带时间戳）

    /// 整片 PCM 识别，返回完整 TranscriptionResult（含 words + 句子 + 时间戳）。
    /// 时间单位：服务端返回 ms，内部统一换算为秒。
    func transcribeFull(pcmPath: String, sampleRate: Int = 16000) async throws -> TranscriptionResult {
        guard let key = KeychainHelper.getAPIKey(for: .qwen), !key.isEmpty else { throw ASRError.missingAPIKey }
        guard let pcm = FileManager.default.contents(atPath: pcmPath), !pcm.isEmpty else { throw ASRError.recognitionFailed }

        var request = URLRequest(url: Self.endpoint)
        request.setValue("bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-DataInspection")
        let ws = URLSession(configuration: .default).webSocketTask(with: request)
        ws.resume()
        defer { ws.cancel(with: .goingAway, reason: nil) }

        let taskId = UUID().uuidString
        var finals: [ASRFinalSentence] = []

        try await ws.send(.string(ParaformerASR.runTaskJSON(taskId: taskId, format: "pcm", sampleRate: sampleRate)))
        try await Self.waitForFinals(ws, event: "task-started", collect: &finals)

        let chunk = 3200; var off = 0
        while off < pcm.count {
            let e = min(off + chunk, pcm.count)
            try await ws.send(.data(pcm.subdata(in: off..<e)))
            off = e
        }

        try await ws.send(.string(ParaformerASR.finishTaskJSON(taskId: taskId)))
        try await Self.waitForFinals(ws, event: "task-finished", collect: &finals)

        let assembled = ParaformerASR.assembleResult(finals)
        let words = assembled.words.map { ASRWord(word: $0.text, start: $0.start, end: $0.end) }
        let sentences = assembled.sentences.map { ASRSentence(text: $0.text, start: $0.start, end: $0.end) }
        let fullText = assembled.words.map(\.text).joined()
        let dur = assembled.words.last?.end ?? assembled.sentences.last?.end ?? 0
        return TranscriptionResult(text: fullText, words: words, rawSentences: sentences, language: "zh", duration: dur)
    }

    /// 读到目标 event 前，累积 result-generated 的【最终句(sentence_end)】(含 words，ms→秒)。
    private static func waitForFinals(_ ws: URLSessionWebSocketTask, event target: String,
                                     collect finals: inout [ASRFinalSentence]) async throws {
        func sec(_ any: Any?) -> Double { ((any as? Double) ?? Double((any as? Int) ?? 0)) / 1000.0 }
        while true {
            let msg = try await ws.receive()
            guard case let .string(text) = msg, let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let header = obj["header"] as? [String: Any], let ev = header["event"] as? String else { continue }
            if ev == "result-generated",
               let payload = obj["payload"] as? [String: Any],
               let output = payload["output"] as? [String: Any],
               let sentence = output["sentence"] as? [String: Any],
               (sentence["sentence_end"] as? Bool) == true,
               let t = sentence["text"] as? String {
                let ws0 = (sentence["words"] as? [[String: Any]]) ?? []
                let words = ws0.compactMap { w -> ASRWordTimed? in
                    guard let wt = w["text"] as? String else { return nil }
                    return ASRWordTimed(text: wt, start: sec(w["begin_time"]), end: sec(w["end_time"]))
                }
                finals.append(ASRFinalSentence(text: t, start: sec(sentence["begin_time"]),
                                               end: sec(sentence["end_time"]), words: words))
            }
            if ev == "task-failed" { throw ASRError.recognitionFailed }
            if ev == target { return }
        }
    }
}
