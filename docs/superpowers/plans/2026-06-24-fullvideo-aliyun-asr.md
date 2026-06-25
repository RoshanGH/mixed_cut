# 整片阿里 ASR + 旧视频整片重识别 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development 或 executing-plans。步骤用 `- [ ]`。

**Goal:** 把整片 ASR 从 whisper 换成阿里 paraformer（产出带时间戳的完整 `TranscriptionResult`），下游分镜文字沿用现有"按时间切片"自动变准；并给旧视频加「阿里重识别整片」按钮（重切现有分镜文字、不动边界）。

**Architecture:** 复用已建的 `QwenASRClient`(paraformer WS) 与 `ParaformerASR`(MixCutCore)。新增整片返回 `TranscriptionResult` 的能力 → `ASRService.transcribe` 路由到阿里 → 导入流水线其余不变（已按 `asrWords` 切片）。旧视频重识别在 `ImportViewModel` 加方法，对**现有分镜**用现有 `extractTextFromASR` 重切文字。

**Tech Stack:** Swift6/SwiftUI/SwiftData/MixCutCore(`swift test`)/内置 FFmpeg/DashScope paraformer-realtime-v2。

## Global Constraints
- 整片**只走阿里**；whisper 代码与内置二进制**保留不删**（仅不再调用）。
- API Key 运行时经 `KeychainHelper.getAPIKey(for: .qwen)`，禁硬编码；只走 WS 流式、不传视频/不落公网文件。
- 旧视频重识别**只重切现有分镜文字、不动分镜边界**。
- 失败不静默（Toast）、不崩；ASR 失败时分镜回退现有 AI 文本逻辑（`finalText = extractedText.isEmpty ? aiSeg.text`）。
- 纯逻辑先写 Swift Testing 测试且 `swift test` 绿；新 core 文件/类型在已注册的 `ParaformerASR.swift` 内扩展（无需新增 pbxproj 条目）。
- 不自动 git 提交/发版。
- **T3 spike 是 T6 的前置门**：paraformer 整片字级时间戳精度不达标则暂缓 T6（导入引擎换），只上 T1–T5（重识别按钮+单分镜↻，二者不依赖边界精度）。

---

### Task 1: ParaformerASR.assembleResult（MixCutCore 纯逻辑 + 测试）
**Files:** Modify `Sources/MixCutCore/ParaformerASR.swift`; Test `Tests/MixCutCoreTests/ParaformerASRTests.swift`（追加）。

**Interfaces — Produces:**
- `struct ASRWordTimed: Equatable, Sendable { let text:String; let start:Double; let end:Double }`
- `struct ASRFinalSentence: Equatable, Sendable { let text:String; let start:Double; let end:Double; let words:[ASRWordTimed] }`
- `static func assembleResult(_ finals:[ASRFinalSentence]) -> (words:[ASRWordTimed], sentences:[ASRFinalSentence])`：按序展开所有 final 句的 words 为全局 words 列表；sentences 即入参（已是 final）。时间单位由调用方在解析时统一为**秒**（本函数不做 ms 换算，只做展开/排序）。

- [ ] **Step 1: 追加失败测试**到 `Tests/MixCutCoreTests/ParaformerASRTests.swift`：
```swift
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
```

- [ ] **Step 2: 跑测试确认失败**
Run: `swift test --filter "ParaformerASR assembleResult"` → 编译失败（类型未定义）。

- [ ] **Step 3: 实现**（在 `ParaformerASR.swift` 末尾、`enum ParaformerASR` 内或其后追加）：
```swift
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
```

- [ ] **Step 4: 跑测试确认通过**
Run: `swift test --filter "ParaformerASR assembleResult"` → 2 PASS。

- [ ] **Step 5: App 编译**
Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3` → `** BUILD SUCCEEDED **`。

---

### Task 2: QwenASRClient.transcribeFull + FFmpegRunner 整片 PCM
**Files:** Modify `MixCut/Services/ASR/QwenASRClient.swift`、`MixCut/Services/VideoProcessing/FFmpegRunner.swift`。

**Interfaces:**
- Consumes: `ParaformerASR.assembleResult`、`ASRWordTimed/ASRFinalSentence`（T1）；`TranscriptionResult{words:[ASRWord], rawSentences:[ASRSentence], language}`、`ASRWord{word,start,end}`、`ASRSentence{text,start,end}`（已存在于 ASRService/Video）。
- Produces:
  - `FFmpegRunner.extractAudioPCM(from videoPath:String, sampleRate:Int=16000, to outPath:String) async throws`（整片 16k 单声道裸 PCM）。
  - `QwenASRClient.transcribeFull(pcmPath:String, sampleRate:Int=16000) async throws -> TranscriptionResult`。

- [ ] **Step 1: FFmpegRunner 加整片 PCM**（仿 `extractSegmentPCM`，去掉 -ss/-to）：
```swift
    /// 整片音频转 16k 单声道裸 PCM(s16le)，供阿里整片 ASR 流式发送。
    func extractAudioPCM(from videoPath: String, sampleRate: Int = 16000, to outPath: String) async throws {
        let args = ["-y", "-i", videoPath, "-vn", "-ac", "1", "-ar", String(sampleRate),
                    "-f", "s16le", "-acodec", "pcm_s16le", outPath]
        _ = try await run(arguments: args)
    }
```

- [ ] **Step 2: QwenASRClient 加 transcribeFull**

在 `QwenASRClient` 内新增（与现有 `transcribe(pcmPath:)` 并存；可把现有 `waitFor` 复用，但需把"句子"信息升级为带 words）。新增一个内部收集器，把每条 result-generated 的最终句(含 words、ms→秒)累积，最后用 `ParaformerASR.assembleResult` 组装并映射成 `TranscriptionResult`：
```swift
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
        while off < pcm.count { let e = min(off + chunk, pcm.count); try await ws.send(.data(pcm.subdata(in: off..<e))); off = e }

        try await ws.send(.string(ParaformerASR.finishTaskJSON(taskId: taskId)))
        try await Self.waitForFinals(ws, event: "task-finished", collect: &finals)

        let assembled = ParaformerASR.assembleResult(finals)
        let words = assembled.words.map { ASRWord(word: $0.text, start: $0.start, end: $0.end) }
        let sentences = assembled.sentences.map { ASRSentence(text: $0.text, start: $0.start, end: $0.end) }
        return TranscriptionResult(words: words, rawSentences: sentences, language: "zh")
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
```
> 注：`TranscriptionResult` / `ASRWord` / `ASRSentence` 的初始化参数名以其在 `ASRService.swift`/`Video.swift` 的真实定义为准（`ASRWord(word:start:end:)`、`ASRSentence(text:start:end:)`、`TranscriptionResult(words:rawSentences:language:)`）——实现时 `grep` 确认参数标签，不符则按真实签名调整。

- [ ] **Step 3: 编译**
Run: `xcodebuild ... build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head` → SUCCEEDED。

---

### Task 3: SPIKE — 验证 paraformer 整片字级时间戳（T6 前置门）
**Files:** Modify `MixCut/App/DebugSelfTest.swift`（扩展现有 `runASR`/新增 `runASRFull`）。

- [ ] **Step 1: 加 DEBUG 自检模式 `MIXCUT_SELFTEST_ASRFULL=1`**：选一个带分镜的真实视频，抽整片 PCM → `QwenASRClient.transcribeFull` → 报告：words 数量、前 10 个 word 的 `text/start/end`、句子数、首尾时间戳、是否单调递增、与 `video.duration` 是否吻合。写到报告文件。
- [ ] **Step 2: 实跑**（带 env 启动 app）：`MIXCUT_SELFTEST_ASRFULL=1 MIXCUT_SELFTEST_OUT=<file> nohup <app binary> &`，轮询报告。
- [ ] **Step 3: 判定**：words 时间戳单调递增、覆盖到接近 video.duration、数量合理(≥句子数)、文字准 → **spike 通过，T6 可做**；否则在报告记录问题，**T6 暂缓**（只交付 T4/T5），并把结论同步给控制者。

---

### Task 4: ImportViewModel.reidentifyWholeVideo（旧视频重识别，重切现有分镜文字）
**Files:** Modify `MixCut/ViewModels/ImportViewModel.swift`。

**Interfaces:**
- Consumes: `QwenASRClient.transcribeFull`（T2）、`FFmpegRunner.extractAudioPCM`（T2）、私有 `Self.extractTextFromASR(words:startTime:endTime:)`（已存在，第 719 行）、`FileHelper.tempDirectory`、`ToastCenter`。
- Produces: `var reidentifyingVideoIDs: Set<UUID>`；`func reidentifyWholeVideo(_ video: Video, context: ModelContext) async`。

- [ ] **Step 1: 实现**
```swift
    /// 用阿里整片重识别该视频，写回 ASR 并按【现有分镜边界】重切各分镜台词（不动边界）。
    var reidentifyingVideoIDs: Set<UUID> = []
    private let asrAliyun = QwenASRClient()

    func reidentifyWholeVideo(_ video: Video, context: ModelContext) async {
        guard !video.localPath.isEmpty, FileManager.default.fileExists(atPath: video.localPath) else {
            ToastCenter.shared.show("找不到原视频文件", icon: "exclamationmark.triangle.fill", style: .warning); return
        }
        guard !reidentifyingVideoIDs.contains(video.id) else { return }
        reidentifyingVideoIDs.insert(video.id)
        defer { reidentifyingVideoIDs.remove(video.id) }

        let pcm = FileHelper.tempDirectory.appendingPathComponent("asrfull-\(UUID().uuidString).pcm")
        defer { try? FileManager.default.removeItem(at: pcm) }
        do {
            try await ffmpeg.extractAudioPCM(from: video.localPath, to: pcm.path)
            let result = try await asrAliyun.transcribeFull(pcmPath: pcm.path)
            guard !result.words.isEmpty else {
                ToastCenter.shared.show("未识别到语音，保留原文字", icon: "waveform.slash", style: .warning); return
            }
            video.asrWords = result.words
            video.asrSentences = result.rawSentences
            video.transcript = result.words.map(\.word).joined()
            // 按现有分镜边界重切文字（不动边界）
            for seg in video.segments {
                let t = Self.extractTextFromASR(words: result.words, startTime: seg.startTime, endTime: seg.endTime)
                if !t.isEmpty { seg.text = t }
            }
            try? context.save()
            ToastCenter.shared.show("已用阿里重识别整片并刷新各分镜台词", icon: "checkmark.circle.fill", style: .success)
        } catch {
            ToastCenter.shared.show("整片重识别失败：\(error.localizedDescription)", icon: "exclamationmark.triangle.fill", style: .warning, duration: 3.5)
        }
    }
```
> 注：`ffmpeg` 是 ImportViewModel 已有的 `FFmpegRunner` 实例（`grep -n "private let ffmpeg\|let asrService" MixCut/ViewModels/ImportViewModel.swift` 确认实例名；若没有现成实例，用 `private let ffmpeg = FFmpegRunner()`）。`Self.extractTextFromASR` 已是私有静态，可直接调。

- [ ] **Step 2: 编译** → SUCCEEDED。

---

### Task 5: 「阿里重识别整片」按钮（ImportedVideoCard + ImportView 接线）
**Files:** Modify `MixCut/Views/Import/ImportView.swift`。

**Interfaces:** Consumes `ImportViewModel.reidentifyWholeVideo`、`reidentifyingVideoIDs`。

- [ ] **Step 1: 给 `ImportedVideoCard` 加两个 prop**（仿现有 `onDelete`/`onRetryASR` 回调风格）：
```swift
    var onReidentify: (() -> Void)?
    var isReidentifying: Bool = false
```
- [ ] **Step 2: 在卡片操作区加按钮**（与现有重试 ASR 按钮同处；busy 转圈、禁用）：
```swift
            if let onReidentify {
                Button(action: onReidentify) {
                    if isReidentifying { ProgressView().controlSize(.small) }
                    else { Label("阿里重识别", systemImage: "waveform.badge.magnifyingglass") }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(isReidentifying)
                .help("用阿里云 ASR 重新识别整片并刷新各分镜台词（不改分镜边界）")
            }
```
- [ ] **Step 3: 父视图接线**（`ImportView` 第 181 行附近的 `ImportedVideoCard(video:...)`，父视图已有 `importVM` 与 `@Environment(\.modelContext)`；无 context 则补 `@Environment(\.modelContext) private var modelContext`）：
```swift
                    ImportedVideoCard(
                        video: video,
                        onDelete: { importVM.deleteVideo(video, from: project) },
                        onReidentify: { Task { await importVM.reidentifyWholeVideo(video, context: modelContext) } },
                        isReidentifying: importVM.reidentifyingVideoIDs.contains(video.id)
                        // ...其余已有回调参数保持不变
                    )
```
> 注：保留 `ImportedVideoCard` 其它已有实参（onRetryAI/onRetryASR 等）不动；只新增这两个。

- [ ] **Step 4: 编译 + 重启 + 自测**：build SUCCEEDED → 重启 app → 素材导入页对一个旧视频点「阿里重识别」→ 确认转圈→各分镜台词刷新/或 Toast 提示;失败有 Toast;分镜边界与数量不变;截图留档。

---

### Task 6: ASRService 整片路由到阿里（**gated on Task 3 spike 通过**）
**Files:** Modify `MixCut/Services/ASR/ASRService.swift`。

- [ ] **Step 1（仅当 T3 spike 通过）: 把 `transcribe(videoPath:language:onProgress:)` 路由到阿里**：抽整片 PCM（`FFmpegRunner.extractAudioPCM`，或现有 extractAudio 后转）→ `QwenASRClient().transcribeFull(pcmPath:)` → 返回。保留原 whisper 私有方法不删（仅不再调用）。
```swift
    func transcribe(videoPath: String, language: String = "zh",
                    onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> TranscriptionResult {
        onProgress?(0.1)
        let pcm = FileHelper.tempDirectory.appendingPathComponent("asr_\(UUID().uuidString).pcm").path
        defer { try? FileManager.default.removeItem(atPath: pcm) }
        try await ffmpeg.extractAudioPCM(from: videoPath, to: pcm)
        onProgress?(0.4)
        let result = try await QwenASRClient().transcribeFull(pcmPath: pcm)
        onProgress?(1.0)
        return result
    }
```
（`ffmpeg` 为 ASRService 现有实例名，`grep` 确认。）

- [ ] **Step 2: 编译 + 实跑**：新导入一条短视频，确认整片走阿里、分镜台词准、边界优化未崩。若 spike 未过，**跳过本任务**，在交付说明里标注"导入引擎暂保留 whisper，旧视频用重识别按钮 + 单分镜↻"。

---

## 验收
- `swift test` 绿（含 assembleResult）。
- 旧视频「阿里重识别」按钮：重切现有分镜文字、边界/数量不变、有 loading/Toast。
- （spike 通过则）新导入整片走阿里，分镜台词显著变准。
- whisper 代码与二进制仍在（未删），仅不再被调用。

## Self-Review
- **Spec 覆盖**：assembleResult=T1；transcribeFull+整片PCM=T2;时间戳精度风险=T3 spike(门);旧视频重识别(重切文字不动边界)=T4+T5;导入引擎换阿里=T6(gated);whisper不删=全程不动其代码/二进制;失败回退=T4/T6沿用现有逻辑。✓
- **占位符**：无 TBD；T2/T4/T6 对真实签名/实例名给了 grep 确认指引(参数标签可能微调)。
- **类型一致**：`ASRWordTimed/ASRFinalSentence/assembleResult`(T1)↔T2 使用一致；`transcribeFull->TranscriptionResult`(T2)↔T4/T6 一致；`extractAudioPCM`(T2)↔T4/T6 一致;`reidentifyWholeVideo/reidentifyingVideoIDs`(T4)↔T5 一致。
- **范围外**：删 whisper 二进制、重识别重切边界、引擎切换 UI——均不在本计划。
