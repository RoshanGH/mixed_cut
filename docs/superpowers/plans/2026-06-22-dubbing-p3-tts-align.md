# 分镜级配音 P3：千问 TTS 配音 + 时长对齐 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 P2 改写好的台词，用千问 TTS（DashScope `qwen3-tts-flash`）按选定音色合成语音，并按「字数预算 + atempo 变速 + 末尾定格/留静音」对齐阶梯把音频塞进每个分镜的固定时长，产物存为 .m4a；同时为 `SegmentDub` 加失效追踪字段（改边界只标该分镜 stale）。

**Architecture:** 对齐阶梯决策（纯数学）和音色目录（纯数据）沉到 `MixCutCore`，用 `swift test` 全覆盖；`QwenTTSClient`（app actor）做真实 HTTP 合成 + 下载 wav；`DubAudioFinalizer`（app）复用既有 `FFmpegRunner` 做 atempo + 转 m4a。网络/IO 任务无单测，由控制者用真实 key 跑冒烟。

**Tech Stack:** Swift 5.10+ / SwiftData / 既有 `FFmpegRunner`(actor, 内置 ffmpeg/ffprobe) / `KeychainHelper`(读千问 key) / Swift Testing / xcodebuild(app) + `swift test`(MixCutCore)。无第三方依赖。

## Global Constraints

- **千问 TTS 接口（已实测）**：端点 `https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation`（标准端点，无需 WorkspaceId）；鉴权 `Authorization: Bearer <千问key>`（复用现有千问 DashScope key，不另设字段）；模型 `qwen3-tts-flash`；请求 `{"model":...,"input":{"text","voice","language_type":"Chinese"}}`；响应 `output.audio.url`（.wav，24h 有效）；音频 wav/pcm_s16le/24000Hz/单声道。
- **无数字语速参数**：`qwen3-tts-flash` 不支持 speed 数值 → 对齐只能靠 atempo（ffmpeg）+ 定格 + 留静音。
- **对齐阶梯参数**：`|D'-D| ≤ 0.15s` 视为直接命中（atempo=1.0）；否则 atempo = clamp(D'/D, **0.9, 1.1**)；atempo 后仍比画面长 → 末尾定格补帧；比画面短 → 末尾留静音。
- **音频存储**：`AppSupport/MixCut/Dubs/{videoHash}/v{index}/{segmentId}.m4a`（编码 AAC）。
- **音色选择**：Settings 列全部音色、每个可试听、客户最多选 3 个；生成时一音色一版。**本期 P3 只做服务层 + 音色目录数据**；Settings UI / 试听按钮 / 选择存储归 P5。
- **MixCutCore 双构建注册**：`Sources/MixCutCore/` 新 .swift 文件必须在 `MixCut.xcodeproj/project.pbxproj` 注册 4 类条目（PBXBuildFile/PBXFileReference/PBXGroup MixCutCore/Sources Build Phase），镜像已有 `CharBudget.swift`。app 层新文件同理注册（镜像 `AIAnalysisService.swift`）。不要 `import MixCutCore`（同模块编译）。
- **Schema 变更先备份**：Task 6 改 `SegmentDub` 模型前，必须先 `cp ~/Library/Application\ Support/MixCut/MixCut.store{,.bak}`（路径以 `FileHelper.mixCutStoreURL` 为准）。新增带默认值字段是加性安全的。
- **不要 git commit**：⚠️ 用户硬性规则——所有改动留工作区，统一最后由用户验收提交。各任务 brief 里的 `git add/commit` 步骤一律跳过。
- **本期不做（归 P4/P5）**：字幕烧制、遮挡滤镜、两阶段导出（P4）；DubbingView/Settings 音色 UI/N 版编排/写 DubVariant 调度（P5）。

---

## 文件结构

| 文件 | 职责 | 新建/修改 |
|---|---|---|
| `Sources/MixCutCore/AlignmentPlan.swift` | 对齐方案值类型 + AudioAligner 纯决策 | 新建 |
| `Sources/MixCutCore/QwenVoice.swift` | 音色值类型 + 48 音色目录 | 新建 |
| `Sources/MixCutCore/DubStaleness.swift` | 失效判定纯逻辑（帧范围+台词指纹比对） | 新建 |
| `MixCut/Services/TTS/TTSClient.swift` | TTSClient 协议 + TTSResult + 千问响应 DTO | 新建 |
| `MixCut/Services/TTS/QwenTTSClient.swift` | 千问真实 HTTP 合成 + 下载 wav + 探测时长 | 新建 |
| `MixCut/Services/TTS/DubAudioFinalizer.swift` | 按 AlignmentPlan 做 atempo + 转 m4a 落库 | 新建 |
| `MixCut/Models/SegmentDub.swift` | 加失效追踪 + trailingSilence 字段 | 修改 |
| `MixCut/Utilities/FileHelper.swift` | 加 Dubs 目录助手 | 修改 |
| `Tests/MixCutCoreTests/AlignmentPlanTests.swift` | 对齐阶梯单测 | 新建 |
| `Tests/MixCutCoreTests/QwenVoiceTests.swift` | 音色目录单测 | 新建 |
| `Tests/MixCutCoreTests/DubStalenessTests.swift` | 失效判定单测 | 新建 |
| `MixCut.xcodeproj/project.pbxproj` | 注册新文件 | 修改 |

---

### Task 1: 对齐阶梯 `AudioAligner` + `AlignmentPlan`

**Files:**
- Create: `Sources/MixCutCore/AlignmentPlan.swift`
- Test: `Tests/MixCutCoreTests/AlignmentPlanTests.swift`
- Modify: `MixCut.xcodeproj/project.pbxproj`（注册 `AlignmentPlan.swift`，4 处）

**Interfaces:**
- Produces:
  - `struct AlignmentPlan: Equatable, Sendable { let atempoFactor: Double; let freezePadFrames: Int; let trailingSilence: Double }`
  - `enum AudioAligner { static func plan(targetDuration: Double, audioDuration: Double, fps: Double) -> AlignmentPlan }`

- [ ] **Step 1: 写失败测试**

`Tests/MixCutCoreTests/AlignmentPlanTests.swift`:
```swift
import Testing
@testable import MixCutCore

@Suite("AudioAligner 对齐阶梯")
struct AlignmentPlanTests {
    private func approx(_ a: Double, _ b: Double, _ tol: Double = 0.02) -> Bool { abs(a - b) < tol }

    @Test("完全相等 → 不变速、不补帧、不留静音")
    func exact() {
        let p = AudioAligner.plan(targetDuration: 3.5, audioDuration: 3.5, fps: 30)
        #expect(p.atempoFactor == 1.0)
        #expect(p.freezePadFrames == 0)
        #expect(p.trailingSilence == 0)
    }

    @Test("微长(≤0.15s) → 不变速，末尾定格补帧")
    func slightlyLonger() {
        let p = AudioAligner.plan(targetDuration: 3.5, audioDuration: 3.6, fps: 30)
        #expect(p.atempoFactor == 1.0)
        #expect(p.freezePadFrames == 3) // round(0.1×30)
        #expect(p.trailingSilence == 0)
    }

    @Test("微短(≤0.15s) → 不变速，末尾留静音")
    func slightlyShorter() {
        let p = AudioAligner.plan(targetDuration: 3.5, audioDuration: 3.4, fps: 30)
        #expect(p.atempoFactor == 1.0)
        #expect(p.freezePadFrames == 0)
        #expect(approx(p.trailingSilence, 0.1))
    }

    @Test("中等偏长，atempo 区间内吸收 → 变速到位，无补帧无静音")
    func atempoAbsorbs() {
        let p = AudioAligner.plan(targetDuration: 3.5, audioDuration: 3.76, fps: 30)
        // raw = 3.76/3.5 = 1.074 ∈ [0.9,1.1]
        #expect(approx(p.atempoFactor, 1.074))
        #expect(p.freezePadFrames == 0)
        #expect(approx(p.trailingSilence, 0))
    }

    @Test("过长，atempo 封顶 1.1 仍超 → 定格补帧兜底")
    func tooLongFreezePad() {
        let p = AudioAligner.plan(targetDuration: 3.5, audioDuration: 5.0, fps: 30)
        #expect(p.atempoFactor == 1.1)
        // 变速后 5.0/1.1=4.545，残差 1.045 → round(1.045×30)=31 帧
        #expect(p.freezePadFrames == 31)
        #expect(p.trailingSilence == 0)
    }

    @Test("过短，atempo 封底 0.9 仍短 → 末尾留静音")
    func tooShortSilence() {
        let p = AudioAligner.plan(targetDuration: 5.0, audioDuration: 3.0, fps: 30)
        #expect(p.atempoFactor == 0.9)
        // 变速后 3.0/0.9=3.333，残差 -1.667 → 留静音 1.667
        #expect(p.freezePadFrames == 0)
        #expect(approx(p.trailingSilence, 1.667))
    }

    @Test("非法输入 → 安全默认")
    func guards() {
        let p = AudioAligner.plan(targetDuration: 0, audioDuration: 3, fps: 30)
        #expect(p == AlignmentPlan(atempoFactor: 1.0, freezePadFrames: 0, trailingSilence: 0))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter AlignmentPlanTests`
Expected: FAIL（`cannot find 'AudioAligner'`）

- [ ] **Step 3: 写最小实现**

`Sources/MixCutCore/AlignmentPlan.swift`:
```swift
import Foundation

/// 把一段配音音频塞进固定画面时长的对齐方案（导出时照此拼）。
public struct AlignmentPlan: Equatable, Sendable {
    /// atempo 变速系数（>1 加速，<1 减速，1.0 不变速）
    public let atempoFactor: Double
    /// 变速后音频仍比画面长时，末尾定格补的帧数
    public let freezePadFrames: Int
    /// 变速后音频比画面短时，末尾补的静音秒数
    public let trailingSilence: Double

    public init(atempoFactor: Double, freezePadFrames: Int, trailingSilence: Double) {
        self.atempoFactor = atempoFactor
        self.freezePadFrames = freezePadFrames
        self.trailingSilence = trailingSilence
    }
}

/// 对齐阶梯纯决策：字数预算已让多数情况落在直接命中/atempo 区间，定格/静音仅兜残差。
public enum AudioAligner {
    /// 直接命中阈值（秒）：差异在此内不变速，保留自然音色
    private static let directThreshold = 0.15
    /// atempo 允许区间（±10% 几乎听不出）
    private static let atempoMin = 0.9
    private static let atempoMax = 1.1

    /// - Parameters:
    ///   - targetDuration: 画面（分镜）时长 D
    ///   - audioDuration: TTS 原始音频时长 D'
    ///   - fps: 视频帧率（算定格补帧用）
    public static func plan(targetDuration: Double, audioDuration: Double, fps: Double) -> AlignmentPlan {
        guard targetDuration > 0, audioDuration > 0, fps > 0 else {
            return AlignmentPlan(atempoFactor: 1.0, freezePadFrames: 0, trailingSilence: 0)
        }

        let diff = audioDuration - targetDuration
        let atempo: Double
        if abs(diff) <= directThreshold {
            atempo = 1.0
        } else {
            atempo = min(max(audioDuration / targetDuration, atempoMin), atempoMax)
        }

        let outDuration = audioDuration / atempo
        let residual = outDuration - targetDuration   // >0 仍偏长；<0 偏短

        if residual > 0.001 {
            return AlignmentPlan(atempoFactor: atempo,
                                 freezePadFrames: Int((residual * fps).rounded()),
                                 trailingSilence: 0)
        } else if residual < -0.001 {
            return AlignmentPlan(atempoFactor: atempo,
                                 freezePadFrames: 0,
                                 trailingSilence: -residual)
        } else {
            return AlignmentPlan(atempoFactor: atempo, freezePadFrames: 0, trailingSilence: 0)
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter AlignmentPlanTests`
Expected: PASS（7 测试全过）

- [ ] **Step 5: 注册 xcodeproj 并验证 app 编译**

为 `AlignmentPlan.swift` 在 pbxproj 加 4 处条目（镜像 `CharBudget.swift`）。
Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**（⚠️ 用户策略：跳过，不 commit，改动留工作区）

---

### Task 2: 音色目录 `QwenVoice`

**Files:**
- Create: `Sources/MixCutCore/QwenVoice.swift`
- Test: `Tests/MixCutCoreTests/QwenVoiceTests.swift`
- Modify: `MixCut.xcodeproj/project.pbxproj`（注册 `QwenVoice.swift`，4 处）

**Interfaces:**
- Produces:
  - `struct QwenVoice: Equatable, Sendable, Identifiable { let id: String; let displayName: String; let summary: String; let dialect: String? }`
  - `enum QwenVoiceCatalog { static let all: [QwenVoice] }`

- [ ] **Step 1: 写失败测试**

`Tests/MixCutCoreTests/QwenVoiceTests.swift`:
```swift
import Testing
@testable import MixCutCore

@Suite("QwenVoiceCatalog 音色目录")
struct QwenVoiceTests {
    @Test("目录非空且包含已验证可用的 Cherry")
    func containsCherry() {
        #expect(QwenVoiceCatalog.all.count >= 40)
        #expect(QwenVoiceCatalog.all.contains { $0.id == "Cherry" && $0.displayName == "芊悦" })
    }

    @Test("voice id 全局唯一")
    func uniqueIds() {
        let ids = QwenVoiceCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("方言音色带 dialect 标注（如四川-晴儿 Sunny）")
    func dialectTagged() {
        let sunny = QwenVoiceCatalog.all.first { $0.id == "Sunny" }
        #expect(sunny?.dialect == "四川话")
    }

    @Test("普通话音色 dialect 为 nil（如 Cherry）")
    func mandarinNoDialect() {
        let cherry = QwenVoiceCatalog.all.first { $0.id == "Cherry" }
        #expect(cherry?.dialect == nil)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter QwenVoiceTests`
Expected: FAIL（`cannot find 'QwenVoiceCatalog'`）

- [ ] **Step 3: 写实现**

`Sources/MixCutCore/QwenVoice.swift`（音色数据来自官方 https://help.aliyun.com/zh/model-studio/qwen-tts-voice-list ，2026-06-22 版）:
```swift
import Foundation

/// 千问 qwen3-tts-flash 系统音色。
public struct QwenVoice: Equatable, Sendable, Identifiable {
    public let id: String          // voice 参数值，如 "Cherry"
    public let displayName: String // 中文名，如 "芊悦"
    public let summary: String     // 音色特点
    public let dialect: String?    // 方言（普通话音色为 nil）

    public init(id: String, displayName: String, summary: String, dialect: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.dialect = dialect
    }
}

/// 全部系统音色目录（供 Settings 列表 + 试听 + 最多选 3）。
public enum QwenVoiceCatalog {
    public static let all: [QwenVoice] = [
        QwenVoice(id: "Cherry", displayName: "芊悦", summary: "阳光积极、亲切自然小姐姐"),
        QwenVoice(id: "Serena", displayName: "苏瑶", summary: "温柔小姐姐"),
        QwenVoice(id: "Ethan", displayName: "晨煦", summary: "标准普通话带部分北方口音，阳光温暖有活力"),
        QwenVoice(id: "Chelsie", displayName: "千雪", summary: "二次元虚拟女友"),
        QwenVoice(id: "Momo", displayName: "茉兔", summary: "撒娇搞怪，逗你开心"),
        QwenVoice(id: "Vivian", displayName: "十三", summary: "拽拽的、可爱的小暴躁"),
        QwenVoice(id: "Moon", displayName: "月白", summary: "率性帅气的月白"),
        QwenVoice(id: "Maia", displayName: "四月", summary: "知性与温柔的碰撞"),
        QwenVoice(id: "Kai", displayName: "凯", summary: "耳朵的一场SPA"),
        QwenVoice(id: "Nofish", displayName: "不吃鱼", summary: "不会翘舌音的设计师"),
        QwenVoice(id: "Bella", displayName: "萌宝", summary: "喝酒不打醉拳的小萝莉"),
        QwenVoice(id: "Jennifer", displayName: "詹妮弗", summary: "品牌级、电影质感般美语女声"),
        QwenVoice(id: "Ryan", displayName: "甜茶", summary: "节奏拉满，戏感炸裂"),
        QwenVoice(id: "Katerina", displayName: "卡捷琳娜", summary: "御姐音色，韵律回味十足"),
        QwenVoice(id: "Aiden", displayName: "艾登", summary: "精通厨艺的美语大男孩"),
        QwenVoice(id: "Eldric Sage", displayName: "沧明子", summary: "沉稳睿智的老者"),
        QwenVoice(id: "Mia", displayName: "乖小妹", summary: "温顺如春水，乖巧如初雪"),
        QwenVoice(id: "Mochi", displayName: "沙小弥", summary: "聪明伶俐的小大人"),
        QwenVoice(id: "Bellona", displayName: "燕铮莺", summary: "声音洪亮，吐字清晰"),
        QwenVoice(id: "Vincent", displayName: "田叔", summary: "沙哑烟嗓，江湖豪情"),
        QwenVoice(id: "Bunny", displayName: "萌小姬", summary: "萌属性爆棚的小萝莉"),
        QwenVoice(id: "Neil", displayName: "阿闻", summary: "字正腔圆的专业新闻主持人"),
        QwenVoice(id: "Elias", displayName: "墨讲师", summary: "把复杂知识讲清楚的讲师"),
        QwenVoice(id: "Arthur", displayName: "徐大爷", summary: "被岁月浸泡过的质朴嗓音"),
        QwenVoice(id: "Nini", displayName: "邻家妹妹", summary: "又软又黏的甜嗓"),
        QwenVoice(id: "Seren", displayName: "小婉", summary: "温和舒缓助眠声线"),
        QwenVoice(id: "Pip", displayName: "顽屁小孩", summary: "调皮捣蛋充满童真"),
        QwenVoice(id: "Stella", displayName: "少女阿月", summary: "甜到发腻的迷糊少女音"),
        QwenVoice(id: "Bodega", displayName: "博德加", summary: "热情的西班牙大叔"),
        QwenVoice(id: "Sonrisa", displayName: "索尼莎", summary: "热情开朗的拉美大姐"),
        QwenVoice(id: "Alek", displayName: "阿列克", summary: "战斗民族的冷与暖"),
        QwenVoice(id: "Dolce", displayName: "多尔切", summary: "慵懒的意大利大叔"),
        QwenVoice(id: "Sohee", displayName: "素熙", summary: "温柔开朗的韩国欧尼"),
        QwenVoice(id: "Ono Anna", displayName: "小野杏", summary: "鬼灵精怪的青梅竹马"),
        QwenVoice(id: "Lenn", displayName: "莱恩", summary: "理性底色叛逆细节的德国青年"),
        QwenVoice(id: "Emilien", displayName: "埃米尔安", summary: "浪漫的法国大哥哥"),
        QwenVoice(id: "Andre", displayName: "安德雷", summary: "声音磁性、沉稳男生"),
        QwenVoice(id: "Radio Gol", displayName: "拉迪奥·戈尔", summary: "用名字解说足球的足球诗人"),
        QwenVoice(id: "Jada", displayName: "上海-阿珍", summary: "风风火火的沪上阿姐", dialect: "上海话"),
        QwenVoice(id: "Dylan", displayName: "北京-晓东", summary: "北京胡同里长大的少年", dialect: "北京话"),
        QwenVoice(id: "Li", displayName: "南京-老李", summary: "耐心的瑜伽老师", dialect: "南京话"),
        QwenVoice(id: "Marcus", displayName: "陕西-秦川", summary: "面宽话短、心实声沉的老陕味道", dialect: "陕西话"),
        QwenVoice(id: "Roy", displayName: "闽南-阿杰", summary: "诙谐直爽的台湾哥仔", dialect: "闽南语"),
        QwenVoice(id: "Peter", displayName: "天津-李彼得", summary: "天津相声专业捧哏", dialect: "天津话"),
        QwenVoice(id: "Sunny", displayName: "四川-晴儿", summary: "甜到心里的川妹子", dialect: "四川话"),
        QwenVoice(id: "Eric", displayName: "四川-程川", summary: "跳脱市井的成都男子", dialect: "四川话"),
        QwenVoice(id: "Rocky", displayName: "粤语-阿强", summary: "幽默风趣的阿强", dialect: "粤语"),
        QwenVoice(id: "Kiki", displayName: "粤语-阿清", summary: "甜美的港妹闺蜜", dialect: "粤语"),
    ]
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter QwenVoiceTests`
Expected: PASS（4 测试全过）

- [ ] **Step 5: 注册 xcodeproj 并验证编译**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**（⚠️ 跳过，不 commit）

---

### Task 3: TTS 协议 + 结果类型 + 千问响应 DTO

**Files:**
- Create: `MixCut/Services/TTS/TTSClient.swift`
- Modify: `MixCut.xcodeproj/project.pbxproj`（注册 `TTSClient.swift`，4 处，挂 app 的 group/Sources）

**Interfaces:**
- Produces:
  - `struct TTSResult: Sendable { let wavPath: String; let rawDuration: Double }`
  - `protocol TTSClient: Sendable { func synthesize(text: String, voiceId: String, languageType: String) async throws -> TTSResult }`
  - `struct QwenTTSResponse: Decodable { struct Output: Decodable { struct Audio: Decodable { let url: String? }; let audio: Audio? }; let output: Output? }`
  - `enum TTSError: Error { case emptyText, noAudioURL, badResponse(String), missingAPIKey }`

- [ ] **Step 1: 写实现**

`MixCut/Services/TTS/TTSClient.swift`:
```swift
import Foundation

/// TTS 合成结果：本地 wav 文件路径 + 原始时长（秒，由 ffprobe 探得）。
struct TTSResult: Sendable {
    let wavPath: String
    let rawDuration: Double
}

/// 文本转语音客户端协议（千问/MiniMax 各自实现，与 AIProvider 平行）。
protocol TTSClient: Sendable {
    /// - Returns: 下载到本地的 wav + 其时长；调用方负责后续对齐/转码/清理。
    func synthesize(text: String, voiceId: String, languageType: String) async throws -> TTSResult
}

/// 千问 DashScope TTS 响应（非流式：output.audio.url 指向 .wav）。
struct QwenTTSResponse: Decodable {
    struct Output: Decodable {
        struct Audio: Decodable { let url: String? }
        let audio: Audio?
    }
    let output: Output?
}

enum TTSError: Error, Equatable {
    case emptyText
    case noAudioURL
    case badResponse(String)
    case missingAPIKey
}
```

- [ ] **Step 2: 注册 xcodeproj 并编译**

为 `TTSClient.swift` 加 4 处条目（镜像 `AIAnalysisService.swift`）。
Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**（⚠️ 跳过，不 commit）

---

### Task 4: 千问 TTS 客户端 `QwenTTSClient`

**Files:**
- Create: `MixCut/Services/TTS/QwenTTSClient.swift`
- Modify: `MixCut.xcodeproj/project.pbxproj`（注册，4 处）

**Interfaces:**
- Consumes: `TTSClient`/`TTSResult`/`QwenTTSResponse`/`TTSError`(Task 3)；现有 `KeychainHelper.getAPIKey(for:)`、`AIProviderType`、`FFmpegRunner.runProbe`、`FileHelper.tempDirectory`
- Produces: `actor QwenTTSClient: TTSClient`，`init(apiKeyProvider: @Sendable () -> String? = { KeychainHelper.getAPIKey(for: .qwen) })`

- [ ] **Step 1: 写实现**

`MixCut/Services/TTS/QwenTTSClient.swift`:
```swift
import Foundation

/// 千问 DashScope qwen3-tts-flash 文本转语音客户端（真实 HTTP）。
/// 复用现有千问 DashScope key（与文本同一把）。
actor QwenTTSClient: TTSClient {
    private static let endpoint = URL(string: "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")!
    private static let model = "qwen3-tts-flash"

    private let apiKeyProvider: @Sendable () -> String?

    init(apiKeyProvider: @escaping @Sendable () -> String? = { KeychainHelper.getAPIKey(for: .qwen) }) {
        self.apiKeyProvider = apiKeyProvider
    }

    func synthesize(text: String, voiceId: String, languageType: String = "Chinese") async throws -> TTSResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TTSError.emptyText }
        guard let key = apiKeyProvider(), !key.isEmpty else { throw TTSError.missingAPIKey }

        // 1) 请求合成
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": Self.model,
            "input": ["text": trimmed, "voice": voiceId, "language_type": languageType]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            throw TTSError.badResponse("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1): \(snippet)")
        }
        let decoded = try JSONDecoder().decode(QwenTTSResponse.self, from: data)
        guard let urlStr = decoded.output?.audio?.url, let audioURL = URL(string: urlStr) else {
            throw TTSError.noAudioURL
        }

        // 2) 下载 wav 到临时目录
        let (tmpFile, _) = try await URLSession.shared.download(from: audioURL)
        let dest = FileHelper.tempDirectory.appendingPathComponent("tts-\(UUID().uuidString).wav")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmpFile, to: dest)

        // 3) 探测时长
        let probe = FFmpegRunner()
        let out = try await probe.runProbe(arguments: [
            "-v", "error", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", dest.path
        ])
        let duration = Double(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        return TTSResult(wavPath: dest.path, rawDuration: duration)
    }
}
```

- [ ] **Step 2: 注册 xcodeproj 并编译**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 冒烟测试（由控制者执行，需真实千问 key）**

> 本任务无单测（真实网络）。实现者在报告里写明「待控制者冒烟」。控制者用临时 key 跑：合成一句 → 确认返回 wavPath 存在、rawDuration > 0。

- [ ] **Step 4: Commit**（⚠️ 跳过，不 commit）

---

### Task 5: 音频对齐落库 `DubAudioFinalizer` + Dubs 目录助手

**Files:**
- Create: `MixCut/Services/TTS/DubAudioFinalizer.swift`
- Modify: `MixCut/Utilities/FileHelper.swift`（加 Dubs 目录助手）
- Modify: `MixCut.xcodeproj/project.pbxproj`（注册 `DubAudioFinalizer.swift`，4 处）

**Interfaces:**
- Consumes: `AlignmentPlan`/`AudioAligner`(Task 1)、`TTSResult`(Task 3)、现有 `FFmpegRunner.run`、`FileHelper.appSupportDirectory`
- Produces:
  - `static func FileHelper.dubAudioURL(videoHash: String, variantIndex: Int, segmentId: UUID) -> URL`
  - `struct FinalizedDub: Sendable { let m4aPath: String; let plan: AlignmentPlan }`
  - `actor DubAudioFinalizer { func finalize(tts: TTSResult, targetDuration: Double, fps: Double, videoHash: String, variantIndex: Int, segmentId: UUID) async throws -> FinalizedDub }`

- [ ] **Step 1: 加 Dubs 目录助手**

在 `MixCut/Utilities/FileHelper.swift` 的 `globalVideoDirectory` 附近加:
```swift
/// 配音音频全局目录：AppSupport/MixCut/Dubs/{videoHash}/v{index}/{segmentId}.m4a
static func dubAudioURL(videoHash: String, variantIndex: Int, segmentId: UUID) -> URL {
    let dir = appSupportDirectory
        .appendingPathComponent("Dubs", isDirectory: true)
        .appendingPathComponent(videoHash, isDirectory: true)
        .appendingPathComponent("v\(variantIndex)", isDirectory: true)
    ensureDirectory(at: dir)
    return dir.appendingPathComponent("\(segmentId.uuidString).m4a")
}
```

- [ ] **Step 2: 写 DubAudioFinalizer 实现**

`MixCut/Services/TTS/DubAudioFinalizer.swift`:
```swift
import Foundation

/// 落库后的配音产物：m4a 路径 + 对齐方案（导出时复现）。
struct FinalizedDub: Sendable {
    let m4aPath: String
    let plan: AlignmentPlan
}

/// 把 TTS 原始 wav 按对齐方案做 atempo 变速 + 转 AAC/m4a，写到全局 Dubs 目录。
/// 定格补帧 / 末尾静音不在此处烧入音频——它们随 plan 落库，由导出阶段（P4）拼接时处理。
actor DubAudioFinalizer {
    func finalize(tts: TTSResult,
                  targetDuration: Double,
                  fps: Double,
                  videoHash: String,
                  variantIndex: Int,
                  segmentId: UUID) async throws -> FinalizedDub {
        let plan = AudioAligner.plan(targetDuration: targetDuration,
                                     audioDuration: tts.rawDuration,
                                     fps: fps)

        let dest = FileHelper.dubAudioURL(videoHash: videoHash, variantIndex: variantIndex, segmentId: segmentId)
        try? FileManager.default.removeItem(at: dest)

        // atempo 只接受 0.5~2.0，单系数即可覆盖我们 [0.9,1.1] 区间
        var filters: [String] = []
        if abs(plan.atempoFactor - 1.0) > 0.001 {
            filters.append("atempo=\(String(format: "%.4f", plan.atempoFactor))")
        }

        let runner = FFmpegRunner()
        var args = ["-y", "-i", tts.wavPath]
        if !filters.isEmpty {
            args += ["-filter:a", filters.joined(separator: ",")]
        }
        args += ["-c:a", "aac", "-b:a", "128k", dest.path]
        _ = try await runner.run(arguments: args)

        return FinalizedDub(m4aPath: dest.path, plan: plan)
    }
}
```

- [ ] **Step 3: 注册 xcodeproj 并编译**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 冒烟测试（控制者执行）**

> 控制者：QwenTTSClient 合成一句 → DubAudioFinalizer.finalize(targetDuration=自定) → 确认产出 .m4a 存在、ffprobe 时长 ≈ 目标（atempo 命中时）或 ≈ rawDuration/atempo。

- [ ] **Step 5: Commit**（⚠️ 跳过，不 commit）

---

### Task 6: `SegmentDub` 失效追踪字段 + `DubStaleness` 判定

**Files:**
- Modify: `MixCut/Models/SegmentDub.swift`（加字段）
- Create: `Sources/MixCutCore/DubStaleness.swift`（纯判定逻辑）
- Test: `Tests/MixCutCoreTests/DubStalenessTests.swift`
- Modify: `MixCut.xcodeproj/project.pbxproj`（注册 `DubStaleness.swift`，4 处）

**Interfaces:**
- Produces:
  - `SegmentDub` 新增：`var generatedForStartFrame: Int = -1`、`var generatedForEndFrame: Int = -1`、`var generatedForTextHash: String = ""`、`var trailingSilence: Double = 0`
  - `enum DubStaleness { static func textHash(_ text: String) -> String; static func isStale(generatedStartFrame: Int, generatedEndFrame: Int, generatedTextHash: String, currentStartFrame: Int, currentEndFrame: Int, currentText: String) -> Bool }`

- [ ] **Step 1: 备份数据库**（Schema 变更铁律）

Run: `cp ~/Library/Application\ Support/MixCut/MixCut.store ~/Library/Application\ Support/MixCut/MixCut.store.bak 2>/dev/null; echo done`
（路径以 `FileHelper.mixCutStoreURL` 为准；不存在则首次运行会新建，无需备份。）

- [ ] **Step 2: 写失败测试**

`Tests/MixCutCoreTests/DubStalenessTests.swift`:
```swift
import Testing
@testable import MixCutCore

@Suite("DubStaleness 失效判定")
struct DubStalenessTests {
    @Test("帧范围与台词都没变 → 不失效")
    func notStale() {
        let h = DubStaleness.textHash("原台词")
        #expect(!DubStaleness.isStale(generatedStartFrame: 10, generatedEndFrame: 100, generatedTextHash: h,
                                      currentStartFrame: 10, currentEndFrame: 100, currentText: "原台词"))
    }

    @Test("帧范围变了 → 失效")
    func frameChanged() {
        let h = DubStaleness.textHash("原台词")
        #expect(DubStaleness.isStale(generatedStartFrame: 10, generatedEndFrame: 100, generatedTextHash: h,
                                     currentStartFrame: 10, currentEndFrame: 120, currentText: "原台词"))
    }

    @Test("台词变了 → 失效")
    func textChanged() {
        let h = DubStaleness.textHash("原台词")
        #expect(DubStaleness.isStale(generatedStartFrame: 10, generatedEndFrame: 100, generatedTextHash: h,
                                     currentStartFrame: 10, currentEndFrame: 100, currentText: "改了的台词"))
    }

    @Test("从未生成（哨兵 -1）→ 视为失效")
    func neverGenerated() {
        #expect(DubStaleness.isStale(generatedStartFrame: -1, generatedEndFrame: -1, generatedTextHash: "",
                                     currentStartFrame: 10, currentEndFrame: 100, currentText: "原台词"))
    }

    @Test("textHash 同输入同输出、不同输入不同输出")
    func hashStable() {
        #expect(DubStaleness.textHash("abc") == DubStaleness.textHash("abc"))
        #expect(DubStaleness.textHash("abc") != DubStaleness.textHash("abd"))
    }
}
```

- [ ] **Step 3: 跑测试确认失败**

Run: `swift test --filter DubStalenessTests`
Expected: FAIL（`cannot find 'DubStaleness'`）

- [ ] **Step 4: 写 DubStaleness 实现**

`Sources/MixCutCore/DubStaleness.swift`:
```swift
import Foundation

/// 配音失效判定：分镜不真实切割，配音针对"生成那一刻"的帧范围+台词生成；
/// 之后边界或台词被改动 → 该配音失效，需单点重生成。
public enum DubStaleness {
    /// 台词指纹（用于廉价比对是否变化）。
    public static func textHash(_ text: String) -> String {
        // djb2，跨平台稳定，无需 CryptoKit
        var hash: UInt64 = 5381
        for byte in text.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return String(hash, radix: 16)
    }

    /// 生成时状态 vs 当前状态：任一不一致即失效。哨兵 -1 表示从未生成 → 失效。
    public static func isStale(generatedStartFrame: Int,
                               generatedEndFrame: Int,
                               generatedTextHash: String,
                               currentStartFrame: Int,
                               currentEndFrame: Int,
                               currentText: String) -> Bool {
        if generatedStartFrame < 0 || generatedEndFrame < 0 { return true }
        if generatedStartFrame != currentStartFrame { return true }
        if generatedEndFrame != currentEndFrame { return true }
        if generatedTextHash != textHash(currentText) { return true }
        return false
    }
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `swift test --filter DubStalenessTests`
Expected: PASS（5 测试全过）

- [ ] **Step 6: 给 SegmentDub 加字段**

在 `MixCut/Models/SegmentDub.swift` 的 `freezePadFrames` 行后加:
```swift
var trailingSilence: Double = 0      // 末尾留静音秒数（对齐用）
// —— 失效追踪：记录"针对哪个状态生成的" ——
var generatedForStartFrame: Int = -1 // 哨兵 -1 = 从未生成
var generatedForEndFrame: Int = -1
var generatedForTextHash: String = ""
```

- [ ] **Step 7: 全量编译 + 回归**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`
Run: `swift test 2>&1 | tail -6`
Expected: 全绿（含 P1/P2 + 本期 AlignmentPlan/QwenVoice/DubStaleness 三套）

- [ ] **Step 8: 启动验证 SwiftData 迁移无崩**

Run: `pkill -x MixCut; sleep 1; open ~/Library/Developer/Xcode/DerivedData/MixCut-byytuggmhodpumcmwnwrtzwkmavr/Build/Products/Debug/MixCut.app; sleep 4; pgrep -x MixCut >/dev/null && echo "存活：迁移成功" || echo "崩溃：检查 schema"`
Expected: `存活：迁移成功`（新增带默认值字段是加性迁移，旧库应平滑升级）

- [ ] **Step 9: Commit**（⚠️ 跳过，不 commit）

---

## 自检（Self-Review）

**Spec 覆盖（对照设计文档第 6 节 + 第 10 节）：**
- 第 6 节 TTS 合成 → Task 3/4（QwenTTSClient 真实对接）。
- 第 6 节 对齐阶梯（0.15s / atempo[0.9,1.1] / 定格 / 静音）→ Task 1（AudioAligner）+ Task 5（落库执行 atempo）。
- 第 6 节 `atempoFactor`/`freezePadFrames` 落库 → Task 6（SegmentDub 已有 + 加 trailingSilence）。
- 音频按 .m4a 存全局目录 → Task 5（FileHelper.dubAudioURL + AAC 编码）。
- 音色目录（供 Settings 选 3）→ Task 2（QwenVoiceCatalog）。
- 失效追踪（用户拍板方案一）→ Task 6（DubStaleness + SegmentDub 字段）。
- 单句失败容错/并发 → 归 P5 调度层（本期客户端逐句独立抛错，调度在 P5 包裹）。

**范围边界**：字幕/遮挡/两阶段导出 = P4；DubbingView/Settings 音色 UI/试听按钮/N 版编排/写 DubVariant = P5。本期只交付服务层 + 纯逻辑 + 数据字段，明确不越界。

**占位符扫描**：无 TBD；纯逻辑任务（1/2/6）全代码 + 真实断言测试；网络/IO 任务（4/5）给完整代码 + 控制者冒烟步骤（真实网络无法单测，已注明）。

**类型一致性**：`AlignmentPlan`(Task1) 被 Task5 消费；`TTSResult`(Task3) 被 Task4 产出、Task5 消费；`DubStaleness.textHash`(Task6) 与 SegmentDub.generatedForTextHash 配套；`fps`/`targetDuration`/`audioDuration` 参数名在 AudioAligner 与 DubAudioFinalizer 间一致。

**对齐口径同源**：DubAudioFinalizer 只调 `AudioAligner.plan`，不自己算 atempo；定格帧/静音随 plan 落库，导出（P4）照拼，保证"生成时算的对齐"与"导出时执行的对齐"一致。
