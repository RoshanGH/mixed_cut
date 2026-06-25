# 单分镜阿里 ASR 重提取台词 设计

**日期**：2026-06-24
**状态**：已批准，待落实现计划

## 目标

本地 whisper ASR 对部分素材识别不准，而配音变体（改写台词→克隆配音）的前提是原台词准确。新增「用阿里云 ASR 对**单个分镜**重新提取原台词」的能力，让用户逐条修正不准的台词。本地 whisper 原流程**完全保留**，这是额外的「单条重提取」入口。

## 范围（本期只做单分镜重提取）

- **做**：每个分镜的原台词旁加「↻ 重提取台词」按钮 → 切该分镜音频 → 阿里 paraformer ASR → 只更新 `segment.text`。按钮放在**分镜素材库**与**素材导入页**两处。
- **不做（本期范围外）**：整片 ASR 引擎替换（whisper→阿里）、重提取后自动重生改写变体+配音、整片时间戳回填边界优化。这些留待后续按需另立 spec。

## 为什么这么选（关键决策）

- **用阿里 ASR API（paraformer-realtime-v2）而非大模型**：paraformer 是阿里中文专用 ASR，忠实还原原话；大模型（qwen-audio）可能润色/改写，不适合"还原原台词"。
- **用 WebSocket 实时流式而非录音文件 RESTful**：文件识别需把音频传到公网 URL（自备 OSS），对 To-C 不友好；WS 实时流式只把**音频帧**推给阿里（与现有 CosyVoice TTS 同一通道），**不传视频、不落公网文件**，To-C 可行。
- **重提取只改 `segment.text`**：旧改写变体不动；用户确认台词后再手动点该分镜「重新改写」闭环，最可控、不擅自花云端。

## 现状对接点（已核对）

- ASR 数据结构：`ASRWord{word,start,end}`、`ASRSentence{text,start,end}`（`MixCut/Models/Video.swift`）。本期单分镜只需**文字**，不依赖时间戳。
- 现有 ASR：`ASRService.transcribe(videoPath:) -> TranscriptionResult`（whisper，本地），不改。
- 分镜原台词字段：`Segment.text`；分镜帧范围 `startFrame/endFrame` + `video.fps`。
- 音频提取：现有 `FFmpegRunner`（whisper 流程也用它抽音轨）。
- API Key：`KeychainHelper.getAPIKey(for: .qwen)`（UserDefaults），运行时读，禁硬编码。

## 架构与组件

```
[↻ 重提取按钮] (分镜素材库卡片/变体面板 + 素材导入页台词行)
        │ 调用
        ▼
reextract(segment)  —— 共享入口，管理 loading/Toast
        │ 1) 切分镜音频(16k 单声道 PCM)
        ▼  FFmpegRunner.extractSegmentPCM(videoPath,start,end → wav/pcm)
        │ 2) 流式识别
        ▼  QwenASRClient.transcribe(audioPath) → String（paraformer WS）
        │ 3) 写回
        ▼  segment.text = 识别文字; context.save()
```

### 1. `QwenASRClient`（新增 actor，`MixCut/Services/ASR/QwenASRClient.swift`）
- `func transcribe(audioPath: String, sampleRate: Int = 16000) async throws -> String`
- WebSocket：`wss://dashscope.aliyuncs.com/api-ws/v1/inference/`，header `Authorization: bearer <key>`、`X-DashScope-DataInspection: enable`（与 CosyVoiceTTSClient 同款握手）。
- 交互：发 `run-task`（model=`paraformer-realtime-v2`，input 音频参数 format=`pcm`/`wav`、sample_rate=16000）→ 收 `task-started` → 分块发送二进制音频帧 → 发 `finish-task` → 累积 `result-generated` 的句子文本 → 收 `task-finished` 后返回拼接全文。具体 run-task JSON 字段以 paraformer 实时 WS API 文档为准（实现时核对）。
- 错误：鉴权失败/无 Key → 抛 `ASRError`，文案友好（复用现有 TTSError 友好化风格）；识别为空 → 返回空串，由调用方提示"未识别到语音"。

### 2. `FFmpegRunner` 加切片方法
- `func extractSegmentPCM(from videoPath: String, start: Double, end: Double, sampleRate: Int = 16000, to outPath: String) async throws`
- ffmpeg：`-ss start -to end -i video -ac 1 -ar 16000 -c:a pcm_s16le out.wav`（或按 WS 要求的裸 PCM）。复用现有 Process 封装。

### 3. 共享重提取入口
- 放在一个两页都能调的位置：新增 `@MainActor @Observable` 轻量 `SegmentASRViewModel`（或在现有 VM 上加方法 + 共享 `QwenASRClient`）。
- 状态：`busyReextractIDs: Set<UUID>`（哪个分镜正在转圈）、错误经 `ToastCenter` 弹出。
- 方法：`func reextract(_ segment: Segment, context: ModelContext) async`：置 busy → 切片(临时文件，用完删) → `QwenASRClient.transcribe` → 非空则 `segment.text = 文字; try? context.save()`，空则 Toast"未识别到语音" → 清 busy；失败 Toast 友好提示，不静默。

### 4. UI 按钮（两处）
- **分镜素材库**：分镜原台词展示处旁加「↻」小按钮（busy 时转圈）。落地前先核对原台词 `segment.text` 在该页的具体展示位置（卡片/行/变体面板）。
- **素材导入页**：分镜台词行旁加同款按钮。落地前先核对导入页台词行是否按分镜（segment）渲染；若导入页是按视频级 ASR 句子渲染、并非逐分镜，则该处按钮改挂在最接近"分镜台词"的位置或暂缓，仅以分镜素材库为准（实现时确认）。

## 错误处理与边界
- 无 Key / 鉴权失败：Toast「尚未配置千问 API Key…」。
- 网络失败/超时：Toast 友好提示，保留原台词不变。
- 识别为空（极短/无语音片段）：Toast「未识别到语音，保留原台词」。
- 切片失败（源文件缺失）：Toast 提示，不崩。
- 并发：同一分镜 busy 时按钮禁用，避免重复请求。

## 测试
- MixCutCore 纯逻辑：把 paraformer WS 的**消息构造**与**结果汇总**抽成可测纯函数（如 `ParaformerMessage.runTask(...)` 生成 JSON、`accumulateText(events:)` 从多条 result-generated 拼最终文本、去重 partial/final），写 Swift Testing 测试，`swift test` 绿。
- 切片/WebSocket/网络：编译 + 真机实跑（自检入口或手点按钮）验证；对一个真实分镜重提取，对比 whisper 与阿里文字。

## 不在本次范围
- 整片 ASR 引擎切换（whisper↔阿里）与引擎选择设置。
- 重提取后自动重写变体/配音。
- 整片字级时间戳回填边界优化（paraformer 流式时间戳精度需另验证）。
