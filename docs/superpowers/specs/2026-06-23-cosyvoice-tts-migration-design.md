# CosyVoice TTS 迁移设计

**日期**: 2026-06-23
**目标**: 把分镜配音的 TTS 从 `qwen3-tts-flash`(简单 REST,无数值语速)换成 DashScope `cosyvoice-v2`(WebSocket 流式,原生 `rate` 语速),并加全局语速旋钮。

## 背景与动机
- 用户需要可调 TTS 语速。qwen3-tts-flash 无数值语速参数,只能靠"字数贴近原文 + ffmpeg atempo ±10%"间接控速。
- CosyVoice-v2 有 `rate` 语速参数(基准 1.0,约 0.5–2.0)、119 个音色(83 普通话),含大量信息流广告人设(带货女 longyingxiao、销售男 longanchong、女主播 longanxuan/longanping 等)。

## 关键决策
1. **模型**: `cosyvoice-v2`(普通话音色最全)。
2. **语速**: 在「配音设置」栏加全局语速滑块(0.7–1.3,默认 1.0),直接作为 CosyVoice `rate`;atempo 仅做最后残差精对齐。
3. **音色展示**: 顶部优先展示广告/带货人设前 10;完整 83 普通话音色后续可扩展为搜索/全列表(本期只做前 10 curated)。

## 架构(尽量不动上层)
沿用现有 `TTSClient` 协议,只换实现:

### 协议变更
`TTSClient.synthesize` 增加 `rate: Double = 1.0` 形参。`QwenTTSClient` 保留但忽略 rate(保留为备用/回退,不删)。

### 新增 `CosyVoiceTTSClient`(app 层 actor，用系统 `URLSessionWebSocketTask`，无三方依赖)
- 端点 `wss://dashscope.aliyuncs.com/api-ws/v1/inference/`
- 头: `Authorization: bearer <key>`(复用 `KeychainHelper.getAPIKey(for: .qwen)` 同一把)+ `X-DashScope-DataInspection: enable`
- 消息序列(JSON 文本帧):
  1. `run-task`: header{action,task_id(uuid),streaming:"duplex"}, payload{task_group:"audio",task:"tts",function:"SpeechSynthesizer",model:"cosyvoice-v2",parameters{text_type:"PlainText",voice,format:"mp3",sample_rate:24000,rate},input:{}}
  2. 收到 `task-started` 事件后发 `continue-task`(payload.input.text = 整段台词)
  3. 发 `finish-task`
  4. 收集服务端**二进制帧**(mp3 音频)拼接 → 写本地文件 → ffprobe 测时长 → 返回 `TTSResult`
  5. 收到 `task-finished` 关闭;`task-failed`/超时抛 `TTSError.badResponse`
- 错误: 无 key → `TTSError.missingAPIKey`;空文本 → `emptyText`;无音频 → `noAudioURL`。

### 音色目录
- `Sources/MixCutCore/QwenVoice.swift` 的 `QwenVoice` 结构体改名 `TTSVoice`(字段不变),保留 `typealias QwenVoice = TTSVoice` 不破坏旧引用。
- 新增 `CosyVoiceCatalog.all: [TTSVoice]`(83 普通话音色,广告/带货人设排前)。
- 新增统一入口 `VoiceCatalog`:`static var active: [TTSVoice] { CosyVoiceCatalog.all }`、`static func voice(id:) -> TTSVoice?`。
- 所有视图/VM 的 `QwenVoiceCatalog.all` / `QwenVoiceCatalog.all.first{...}` 改用 `VoiceCatalog.active` / `VoiceCatalog.voice(id:)`。

### 数据模型
- `Video` 加 `var dubSpeechRate: Double = 1.0`(SwiftData 加字段,带默认值,向后兼容)。

### 上层改动
- `DubbingViewModel`: TTS 客户端换 `CosyVoiceTTSClient`;`topVoices`/试听用 `VoiceCatalog`;`generateAudio`/`audition` 传 `video.dubSpeechRate` 作为 rate。
- `DubSettingsBar`: 加语速滑块绑定 `video.dubSpeechRate`;音色名查 `VoiceCatalog`。
- `SegmentVariantInspector` / `SchemeListView` / `SchemeDetailView`: 音色查询改 `VoiceCatalog`。
- `DubAudioFinalizer`: 输入音频路径(mp3),ffmpeg 自动识别格式,基本不改(字段沿用 wavPath 作通用音频路径)。

## 迁移影响
- 旧的 qwen 音色选择(`Video.selectedVoiceIds` 存的 Cherry/Serena/Ethan)与 cosyvoice ID 对不上 → 顶部不再勾选 → 用户**重选音色 + 重跑一键改写**。
- 旧 72 个变体(qwen voiceId)与新选择不匹配,变体池按新音色重建;旧音频文件成孤儿(无害,后续可清)。
- 不做自动数据迁移(用户已知晓并接受作废)。

## 测试
- `CosyVoiceCatalog`(Core,swift test):普通话音色数=83、前 10 含广告/带货人设、无重复 id。
- `TTSVoice` 改名后旧测试仍绿(typealias)。
- WebSocket 客户端: 无法离线单测(依赖真实服务+key),由用户「试听」端到端验证;实现内做严格状态机与超时。

## 非目标(本期不做)
- 全部 83 音色的搜索/全列表 UI(只做前 10)。
- 声音克隆(自定义音色)。
- 删除 QwenTTSClient/QwenVoiceCatalog(保留为回退)。
