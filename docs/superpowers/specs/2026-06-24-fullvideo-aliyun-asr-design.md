# 整片 ASR 改用阿里 paraformer + 旧视频整片重识别 设计

**日期**：2026-06-24
**状态**：已批准，待落实现计划
**承接**：`2026-06-24-segment-asr-reextract-design.md`（单分镜 ↻ 已实现，保留为微调补丁）

## 目标

本地 whisper 识别不准是配音变体的根本瓶颈。把**导入流水线的整片 ASR 步骤从 whisper 换成阿里 paraformer-realtime**，产出**带时间戳的完整 `TranscriptionResult`（words + sentences）**；下游分镜文字沿用现有"按分镜时间从 asrWords 切片"的逻辑（`ImportViewModel.extractTextFromASR`，第 522 行）自动变准，无需逐分镜单独识别。并给**已导入的旧视频**加「整片重识别」按钮一键修复。

## 决策（已确认）

- **整片只用阿里**：导入与重识别都走阿里 paraformer。whisper 的**代码与内置二进制暂保留不删**（删二进制涉及打包体积、不可逆，待稳定后另行清理），但正常流程不再调用 whisper。
- **旧视频加「整片重识别」按钮**：对已导入视频重跑整片阿里 ASR，并把新 ASR 按**现有分镜边界**重新切出各分镜台词（**不改分镜边界**，避免打乱用户已有分镜）。
- 单分镜 ↻（已实现）保留为"个别微调"。

## 现状对接点（已核对，确认"切一下就行"）

- `ASRService.transcribe(videoPath:) -> TranscriptionResult { words:[ASRWord{word,start,end}], rawSentences:[ASRSentence{text,start,end}], language }`（当前 whisper）。
- 导入流水线：整片 `asr.words` → 每分镜 `extractTextFromASR(words:startTime:endTime:)` 按时间切片得 `segment.text`（`ImportViewModel` 第 522 行）；边界优化用 `asr.sentences`（`BoundaryOptimizerService`）。
- 已有 `QwenASRClient`（paraformer WS，目前只返回纯文本 String）、`ParaformerASR`（消息构造 + 文本汇总，MixCutCore，有单测）、`FFmpegRunner.extractSegmentPCM`。
- API Key：`KeychainHelper.getAPIKey(for: .qwen)`。

## 架构与组件

```
导入/重识别
   │ 抽整片音频(16k 单声道 PCM)  FFmpegRunner
   ▼
QwenASRClient.transcribeFull(pcmPath) → TranscriptionResult{words,sentences}
   │   (paraformer 整片流式;result-generated 的 output.sentence.words[] 累积;ms→秒)
   ▼
导入: 原流水线不变(边界优化 + extractTextFromASR 按时间切片)
重识别: 写回 video.asrWords/asrSentences/transcript + 对每个【现有分镜】按时间重切 segment.text(边界不动)
```

### 1. `ParaformerASR` 扩展（MixCutCore，纯逻辑 + 单测）
- 现有 `accumulateTranscript` 保留。
- 新增结果类型 + 汇总函数，从"最终句(含 words)"列表产出 words/sentences（ms→秒）：
  - `struct ASRWordTimed { text:String; start:Double; end:Double }`、`struct ASRFinalSentence { text:String; start:Double; end:Double; words:[ASRWordTimed] }`
  - `static func assembleResult(finals:[ASRFinalSentence]) -> (words:[ASRWordTimed], sentences:[(text:String,start:Double,end:Double)])`：按序展开所有 final 句的 words 为全局 words 列表 + 句子列表。
  - 纯逻辑可测（输入 ms 已转秒由调用方在解析时做，或在此函数内统一除 1000——实现时定，单测覆盖时间戳换算与展开顺序）。

### 2. `QwenASRClient.transcribeFull`（App）
- `func transcribeFull(pcmPath: String, sampleRate: Int = 16000) async throws -> TranscriptionResult`
- 复用现有 WS 流程；解析 result-generated 的 `payload.output.sentence`（text、begin_time/end_time、words[]{text,begin_time,end_time,sentence_end}），只收 `sentence_end==true` 的最终句 → 调 `ParaformerASR.assembleResult` → 映射成 `TranscriptionResult`（ms→秒）。
- 整片音频可能数分钟：分块流式发送（沿用 3200B/块），WS 会话持续到 task-finished。

### 3. `ASRService` 路由到阿里（App）
- `transcribe(videoPath:)` 改为：抽整片音频(16k 单声道 PCM, 临时文件)→ `QwenASRClient.transcribeFull` → 返回 `TranscriptionResult`。whisper 方法保留但不在此路径调用。
- 失败处理：抛错由现有导入流水线的逐步容错接住（ASR 失败不阻塞；`segment.text` 回退 AI 文本——现有逻辑 `finalText = extractedText.isEmpty ? aiSeg.text`）。

### 4. 「整片重识别」按钮（App，旧视频用）
- 位置：素材导入页视频卡片（`ImportedVideoCard`）一个「↻ 阿里重识别整片」按钮。
- 行为：抽整片音频 → `transcribeFull` → 写回 `video.asrWords/asrSentences/transcript` → 对该视频**每个现有分镜**按 `extractTextFromASR(newWords, seg.startTime, seg.endTime)` 重切 `segment.text`（**边界不变**）→ save。loading（卡片转圈）+ Toast；失败不静默、保留原数据。
- 放在 ViewModel（`ImportViewModel`）一个方法 `reidentifyWholeVideo(_ video:context:)`，复用 `extractTextFromASR`（需可被复用，必要时提取为可见静态方法）。

### 5. 单分镜 ↻（已有，保留）
- 不变，作为整片重识别后个别分镜的微调。

## 关键风险与验证

- **paraformer 字级时间戳精度**（最大风险）：新导入的**边界优化**(句子吸附/场景对齐/静音/I 帧) 依赖 asrWords/asrSentences 时间戳。上全量前先做 **spike**：对一条真实视频跑整片 paraformer，检查 words 数量、时间戳单调递增且与音频对齐、句子边界合理；与 whisper 对比。spike 不过则先只保「重识别按钮 + 单分镜 ↻」(它们不重切边界、只切文字，对时间戳精度不敏感)，整片导入边界暂缓换。
- **旧视频重识别只重切文字、不重切边界** → 对时间戳精度不敏感，安全。
- 整片音频上云（比单条多）；已接受云端 ASR。无 Key/断网 → 导入 ASR 失败但不崩，分镜回退 AI 文本。

## 测试

- MixCutCore：`ParaformerASR.assembleResult` 纯逻辑单测（ms→秒换算、words 展开顺序、只取 final）。
- App：编译 + DEBUG 自检入口 `MIXCUT_SELFTEST_ASR`（已用于单分镜）扩展/复用，对真实整片跑 `transcribeFull` 验证 words/sentences/时间戳；旧视频重识别对比 whisper 文字。

## 不在本次范围
- 删除 whisper 代码与内置二进制（待稳定后另清）。
- 重识别时**重新切分分镜边界**（只重切现有分镜的文字，不动边界）。
- 引擎切换 UI 开关（决策为"只用阿里"，不提供切换）。
