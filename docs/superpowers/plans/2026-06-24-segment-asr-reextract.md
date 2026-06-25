# 单分镜阿里 ASR 重提取台词 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development 或 superpowers:executing-plans 按任务实现。步骤用 `- [ ]` 勾选。

**Goal:** 在分镜素材库每个分镜原台词旁加「↻ 重提取台词」按钮，用阿里 paraformer-realtime ASR 对该分镜音频重识别，只更新 `segment.text`；本地 whisper 流程保留不动。

**Architecture:** 新增 `QwenASRClient`（paraformer-realtime-v2 WebSocket 流式，复用 CosyVoiceTTSClient 握手模式，不传视频/不落公网文件）；`FFmpegRunner` 加按分镜时间切 16k 单声道 PCM 的方法；`SegmentLibraryViewModel` 加 `reextractTranscript(_:context:)` 管 loading/Toast；分镜库台词旁加按钮。WS 的消息构造与文本汇总抽到 MixCutCore 做纯逻辑单测。

**Tech Stack:** Swift 6 / SwiftUI / SwiftData / MixCutCore(`swift test`) / 内置 FFmpeg / DashScope paraformer-realtime-v2。

## Global Constraints
- API Key 运行时经 `KeychainHelper.getAPIKey(for: .qwen)` 读，**禁硬编码**。
- 只走 WebSocket 实时流式（不传视频、不落公网文件）；只发音频。
- 重提取**只改 `segment.text`**，不动改写变体/配音。
- 失败/空结果用 `ToastCenter` 提示，**不静默吞错**；同分镜处理中按钮禁用。
- whisper（`ASRService`）原流程不改。
- 本期按钮**只放分镜素材库**（导入页台词是 ASR 句子非分镜，本期不放）。
- 不自动 git 提交/发版；新 MixCutCore 文件注册进 pbxproj（核心 4 处）。
- WS 端点 `wss://dashscope.aliyuncs.com/api-ws/v1/inference/`，header `Authorization: bearer <key>`、`X-DashScope-DataInspection: enable`（同 CosyVoiceTTSClient）。

---

### Task 1: ParaformerASR 纯逻辑（消息构造 + 文本汇总）+ 测试
**Files:** Create `Sources/MixCutCore/ParaformerASR.swift`; Test `Tests/MixCutCoreTests/ParaformerASRTests.swift`; 注册 pbxproj。

**Interfaces — Produces:**
- `struct ASRResultSentence: Equatable, Sendable { let text: String; let sentenceEnd: Bool }`
- `enum ParaformerASR { static func runTaskJSON(taskId:String, format:String, sampleRate:Int) -> String; static func finishTaskJSON(taskId:String) -> String; static func accumulateTranscript(_ sentences:[ASRResultSentence]) -> String }`
- `accumulateTranscript`：只取 `sentenceEnd == true` 的句子，按出现顺序拼接其 `text`（中文无分隔符），并去除首尾空白。

- [ ] **Step 1: 写失败测试**

创建 `Tests/MixCutCoreTests/ParaformerASRTests.swift`：
```swift
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
            ASRResultSentence(text: "你好", sentenceEnd: false),       // partial
            ASRResultSentence(text: "你好世界", sentenceEnd: true),     // final 句1
            ASRResultSentence(text: "下单", sentenceEnd: false),       // partial
            ASRResultSentence(text: "下单立减十元", sentenceEnd: true)  // final 句2
        ]
        #expect(ParaformerASR.accumulateTranscript(evts) == "你好世界下单立减十元")
    }

    @Test("无 final → 空串")
    func noFinals() {
        let evts = [ASRResultSentence(text: "半句", sentenceEnd: false)]
        #expect(ParaformerASR.accumulateTranscript(evts) == "")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter ParaformerASR`
Expected: 编译失败（找不到 ParaformerASR）。

- [ ] **Step 3: 写实现**

创建 `Sources/MixCutCore/ParaformerASR.swift`：
```swift
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
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter ParaformerASR`
Expected: 4 个测试 PASS。

- [ ] **Step 5: 注册 pbxproj（4 处，仿 SpeechRatePlanner.swift）**

Run: `grep -n "SpeechRatePlanner.swift" MixCut.xcodeproj/project.pbxproj`（得 4 行模板）。
用 `uuidgen | tr -dc 'A-F0-9' | cut -c1-24` 生成 buildFile/fileRef 两个 ID，仿照那 4 行加入 `ParaformerASR.swift`（`path = Sources/MixCutCore/ParaformerASR.swift`）。

- [ ] **Step 6: App 编译确认**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`。

---

### Task 2: QwenASRClient（paraformer-realtime WebSocket）
**Files:** Create `MixCut/Services/ASR/QwenASRClient.swift`; 注册 pbxproj（App 文件 3 处，仿 `BatchSegmentExportService.swift`）。

**Interfaces:**
- Consumes: `ParaformerASR`（Task 1）、`KeychainHelper.getAPIKey(for:)`。
- Produces: `actor QwenASRClient { func transcribe(pcmPath: String, sampleRate: Int = 16000) async throws -> String }`，以及 `enum ASRError: Error, LocalizedError { case missingAPIKey, connectionFailed, recognitionFailed }`（errorDescription 友好中文，仿 TTSError）。

- [ ] **Step 1: 写实现**（无单测，WS 网络）

创建 `MixCut/Services/ASR/QwenASRClient.swift`：
```swift
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

        // 1) run-task
        try await ws.send(.string(ParaformerASR.runTaskJSON(taskId: taskId, format: "pcm", sampleRate: sampleRate)))

        // 2) 等 task-started
        try await Self.waitFor(ws, event: "task-started", collect: &sentences)

        // 3) 分块发送二进制音频（100ms/块 = 16000*2/10 = 3200 字节）
        let chunk = 3200
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + chunk, pcm.count)
            try await ws.send(.data(pcm.subdata(in: offset..<end)))
            offset = end
        }

        // 4) finish-task
        try await ws.send(.string(ParaformerASR.finishTaskJSON(taskId: taskId)))

        // 5) 收到 task-finished 前持续累积 result-generated
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
}
```

- [ ] **Step 2: 注册 pbxproj（App 文件，仿 BatchSegmentExportService.swift 的登记行数）**

Run: `grep -n "BatchSegmentExportService.swift" MixCut.xcodeproj/project.pbxproj`，仿其 4 处用新 ID 加 `QwenASRClient.swift`（`path = QwenASRClient.swift`）。

- [ ] **Step 3: 编译确认**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`。

---

### Task 3: FFmpegRunner 切分镜音频为 16k 单声道 PCM
**Files:** Modify `MixCut/Services/FFmpegRunner.swift`（或 FFmpeg 封装所在文件；用 `grep -rn "actor FFmpegRunner\|class FFmpegRunner" MixCut` 定位）。

**Interfaces — Produces:** `func extractSegmentPCM(from videoPath: String, start: Double, end: Double, sampleRate: Int = 16000, to outPath: String) async throws`

- [ ] **Step 1: 实现**

在 FFmpegRunner 内新增（复用其现有 `run(arguments:)` 封装；参数名以该类实际方法为准）：
```swift
    /// 切出 [start,end) 秒的音频为 16k 单声道裸 PCM(s16le)，供阿里实时 ASR 流式发送。
    func extractSegmentPCM(from videoPath: String, start: Double, end: Double,
                           sampleRate: Int = 16000, to outPath: String) async throws {
        let args = ["-y",
                    "-ss", String(format: "%.3f", max(0, start)),
                    "-to", String(format: "%.3f", end),
                    "-i", videoPath,
                    "-vn", "-ac", "1", "-ar", String(sampleRate),
                    "-f", "s16le", "-acodec", "pcm_s16le", outPath]
        _ = try await run(arguments: args)
    }
```
> 注：若 FFmpegRunner 的执行方法不叫 `run(arguments:)`，改成该类实际的执行入口（参考其中已有的 `cutSegment`/`generateThumbnail` 怎么调）。

- [ ] **Step 2: 编译确认**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`。

---

### Task 4: SegmentLibraryViewModel 加重提取入口
**Files:** Modify `MixCut/ViewModels/SegmentLibraryViewModel.swift`

**Interfaces:**
- Consumes: `QwenASRClient`（Task 2）、`FFmpegRunner.extractSegmentPCM`（Task 3）、`FileHelper.tempDirectory`、`ToastCenter.shared`。
- Produces: `var busyASRSegmentIDs: Set<UUID>`（@Observable 自动追踪）；`func reextractTranscript(_ segment: Segment, context: ModelContext) async`。

- [ ] **Step 1: 加状态与方法**

在 `SegmentLibraryViewModel` 内加：
```swift
    /// 正在用阿里 ASR 重提取台词的分镜（控制按钮 loading / 禁用）。
    var busyASRSegmentIDs: Set<UUID> = []
    private let asrClient = QwenASRClient()
    private let asrFFmpeg = FFmpegRunner()

    /// 用阿里 paraformer 对单个分镜重识别，只更新 segment.text（whisper 流程不动）。
    func reextractTranscript(_ segment: Segment, context: ModelContext) async {
        guard let video = segment.video, !video.localPath.isEmpty,
              FileManager.default.fileExists(atPath: video.localPath) else {
            ToastCenter.shared.show("找不到原视频文件", icon: "exclamationmark.triangle.fill", style: .warning)
            return
        }
        guard !busyASRSegmentIDs.contains(segment.id) else { return }
        busyASRSegmentIDs.insert(segment.id)
        defer { busyASRSegmentIDs.remove(segment.id) }

        let fps = video.fps > 0 ? video.fps : 30
        let start = Double(segment.startFrame) / fps
        let end = Double(segment.endFrame) / fps
        let pcmURL = FileHelper.tempDirectory.appendingPathComponent("asr-\(UUID().uuidString).pcm")
        defer { try? FileManager.default.removeItem(at: pcmURL) }

        do {
            try await asrFFmpeg.extractSegmentPCM(from: video.localPath, start: start, end: end, to: pcmURL.path)
            let text = try await asrClient.transcribe(pcmPath: pcmURL.path)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                ToastCenter.shared.show("未识别到语音，保留原台词", icon: "waveform.slash", style: .warning)
                return
            }
            segment.text = trimmed
            try? context.save()
            ToastCenter.shared.show("已用阿里 ASR 重提取台词", icon: "checkmark.circle.fill", style: .success)
        } catch {
            ToastCenter.shared.show("重提取失败：\(error.localizedDescription)", icon: "exclamationmark.triangle.fill", style: .warning, duration: 3.5)
        }
    }
```

- [ ] **Step 2: 编译确认**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`。

---

### Task 5: 分镜素材库台词旁加「↻ 重提取」按钮
**Files:** Modify `MixCut/Views/SegmentLibrary/SegmentLibraryView.swift`

**Interfaces:** Consumes `viewModel.reextractTranscript`、`viewModel.busyASRSegmentIDs`、`@Environment(\.modelContext)`。

- [ ] **Step 1: 定位台词展示处**

Run: `grep -n "Text(segment.text)\|segment.text.isEmpty\|draftText = segment.text\|@Environment(\\.modelContext)" MixCut/Views/SegmentLibrary/SegmentLibraryView.swift`
找到分镜原台词显示/编辑所在的视图（约 766–793 行附近的 `Text(segment.text)` 与行内编辑区），确认该视图已有 `viewModel` 与 `modelContext`（无则补 `@Environment(\.modelContext) private var modelContext`）。

- [ ] **Step 2: 在台词旁加按钮**

在台词显示行（非编辑态）旁加一个小按钮（与「复制台词」等已有小按钮同排即可）：
```swift
            Button {
                Task { await viewModel.reextractTranscript(segment, context: modelContext) }
            } label: {
                if viewModel.busyASRSegmentIDs.contains(segment.id) {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise.circle")
                }
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.busyASRSegmentIDs.contains(segment.id))
            .help("用阿里云 ASR 重新识别这一分镜的台词（替换原台词，whisper 不变）")
```
> 放在台词文本同一行的尾部或操作按钮区；保持 9:16 卡片布局不被撑变形（按钮用 mini/borderless）。

- [ ] **Step 3: 编译 + 重启 + 自测**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3`（期望 SUCCEEDED）
然后：`pkill -x MixCut; sleep 1; open <DerivedData>/Build/Products/Debug/MixCut.app`，进分镜素材库，对一个分镜点「↻」：确认转圈→台词被替换/或弹「未识别到语音」/失败弹 Toast；whisper 原台词其它分镜不受影响；截图留档。

- [ ] **Step 4: 编译成功后按项目规则后台出 Release DMG 到 `~/Desktop/MixCut.dmg`。**

---

## 验收
- 分镜素材库每个分镜台词旁有「↻ 重提取」；点击用阿里 paraformer 重识别该分镜并替换原台词。
- 无 Key/网络失败/空结果均有 Toast，不崩不静默；处理中按钮禁用转圈。
- whisper 原导入流程、其它分镜台词不受影响；只改 `segment.text`，改写变体不动。
- `swift test` 绿（ParaformerASR 纯逻辑）。

## Self-Review
- **Spec 覆盖**：paraformer WS(不传视频)=T1+T2；切片=T3；只改 segment.text + loading/Toast=T4；分镜库按钮=T5；whisper 保留=全程不碰 ASRService；只放分镜素材库=T5（导入页本期不做，已与用户确认）。✓
- **占位符**：无 TBD；T3 注明若执行入口名不同按实际改（已给定位命令）。
- **类型一致**：`ASRResultSentence`/`ParaformerASR.*`(T1)↔QwenASRClient(T2)一致；`transcribe(pcmPath:)`↔T4 调用一致；`extractSegmentPCM`签名 T3↔T4 一致；`busyASRSegmentIDs`/`reextractTranscript` T4↔T5 一致。
- **范围外**：整片换引擎、自动重写变体、时间戳回填边界——均不在本计划。
