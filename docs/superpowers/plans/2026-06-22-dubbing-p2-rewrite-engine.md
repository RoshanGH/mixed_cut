# 分镜级配音 P2：AI 台词改写引擎 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建「整片一次调用」的 AI 台词改写引擎——输入一个视频里所有"可重配"分镜的 [原台词 + 时长 + 关键词]，按字数预算和差异化风格产出一整套连贯的新台词。

**Architecture:** 全部可测纯逻辑（字数预算计算、prompt 构建、AI 结果映射与校验）放进 `MixCutCore`，用 `swift test` 覆盖；`ScriptRewriteService`（app 层 actor）只做薄胶水——加载模板 → 构建 prompt → 调 `AIProvider.generateJSON` → 用纯逻辑映射结果。复用现有 AI 基础设施，不新增协议、不引第三方依赖。

**Tech Stack:** Swift 5.10+ / SwiftData / 现有 `AIProvider`(OpenAI 兼容) / Swift Testing(`import Testing`) / xcodebuild(app) + `swift test`(MixCutCore)

## Global Constraints

- **不传视频给 AI**：只发结构化文本（原台词/时长/字数预算/关键词），与项目「不直接传视频给 AI」原则一致。
- **复用现有 AI 设施**：用 `AIProvider.generateJSON<T:Decodable>(prompt:responseType:)`，provider 经 `AIProviderManager.currentProvider()` 动态获取；Service 用 `injectedProvider ?? currentProvider()` 范式以便注入 mock 测试。
- **MixCutCore 双构建注册**：`Sources/MixCutCore/` 下新文件 `swift test` 会自动纳入，但 **app target 必须在 `MixCut.xcodeproj/project.pbxproj` 手动注册**（4 处：PBXBuildFile / PBXFileReference / PBXGroup / Sources Build Phase），否则 app 编译找不到符号。不要 `import MixCutCore`（同模块编译）。
- **字数预算**：`目标字数 = 分镜时长(秒) × 目标语速(字/秒)`；允许区间 `[0.85×目标, 1.0×目标]`（TTS 实际略快，留余量）。
- **分镜时长来源**：`时长 = (endFrame - startFrame) / video.fps`，与 `FrameTime.seconds(frame:fps:)`、`Segment.duration` 一致。
- **每步独立容错**：AI 漏返回某分镜 → 该分镜回退原台词并标记 `isFallback`，不阻塞其余。
- **提交策略**：本项目直接提交 `main`。按用户要求「全部做完一次性验证再提交」——执行时各任务可本地 commit，但最终需用户验收后才推送/对外。
- **本期不做（归 P5 DubbingView）**：台词校对关卡 UI、N 版编排（循环调用本引擎、每版传不同 style）、写入 `SegmentDub`。本引擎只返回值类型结果，不碰 SwiftData。

---

## 文件结构

| 文件 | 职责 | 新建/修改 |
|---|---|---|
| `Sources/MixCutCore/CharBudget.swift` | 字数预算纯计算 | 新建 |
| `Sources/MixCutCore/RewriteTypes.swift` | 改写输入/输出/AI DTO 值类型 | 新建 |
| `Sources/MixCutCore/RewritePromptBuilder.swift` | 由输入+风格+预算拼 prompt | 新建 |
| `Sources/MixCutCore/RewriteResultMapper.swift` | AI 返回 → 结果映射+校验+回退 | 新建 |
| `MixCut/Resources/Prompts/script_rewrite_prompt.md` | 改写 prompt 模板 | 新建 |
| `MixCut/Services/AI/ScriptRewriteService.swift` | actor 薄胶水：模板→prompt→AI→映射 | 新建 |
| `Tests/MixCutCoreTests/CharBudgetTests.swift` | 预算单测 | 新建 |
| `Tests/MixCutCoreTests/RewritePromptBuilderTests.swift` | prompt 单测 | 新建 |
| `Tests/MixCutCoreTests/RewriteResultMapperTests.swift` | 映射单测 | 新建 |
| `MixCut.xcodeproj/project.pbxproj` | 注册 4 个新源文件 + 1 个 prompt 资源 | 修改 |

---

### Task 1: 字数预算计算 `CharBudget`

**Files:**
- Create: `Sources/MixCutCore/CharBudget.swift`
- Test: `Tests/MixCutCoreTests/CharBudgetTests.swift`
- Modify: `MixCut.xcodeproj/project.pbxproj`（注册 `CharBudget.swift` 到 app target，4 处）

**Interfaces:**
- Produces:
  - `struct CharBudget: Equatable, Sendable { let target: Int; let minChars: Int; let maxChars: Int }`
  - `static func CharBudget.forDuration(_ seconds: Double, charsPerSecond cps: Double) -> CharBudget`

- [ ] **Step 1: 写失败测试**

`Tests/MixCutCoreTests/CharBudgetTests.swift`:
```swift
import Testing
@testable import MixCutCore

@Suite("CharBudget 字数预算")
struct CharBudgetTests {
    @Test("目标=时长×语速，下限=0.85×目标（四舍五入）")
    func normalBudget() {
        let b = CharBudget.forDuration(3.0, charsPerSecond: 5.0) // 目标 15，下限 round(12.75)=13
        #expect(b.target == 15)
        #expect(b.maxChars == 15)
        #expect(b.minChars == 13)
    }

    @Test("时长为 0 → 全 0")
    func zeroDuration() {
        let b = CharBudget.forDuration(0, charsPerSecond: 5.0)
        #expect(b == CharBudget(target: 0, minChars: 0, maxChars: 0))
    }

    @Test("语速非正 → 全 0，不崩")
    func nonPositiveRate() {
        let b = CharBudget.forDuration(3.0, charsPerSecond: 0)
        #expect(b == CharBudget(target: 0, minChars: 0, maxChars: 0))
    }

    @Test("四舍五入：2.0s × 5 = 10，下限 round(8.5)=9")
    func rounding() {
        let b = CharBudget.forDuration(2.0, charsPerSecond: 5.0)
        #expect(b.maxChars == 10)
        #expect(b.minChars == 9)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter CharBudgetTests`
Expected: FAIL（`cannot find 'CharBudget' in scope`）

- [ ] **Step 3: 写最小实现**

`Sources/MixCutCore/CharBudget.swift`:
```swift
import Foundation

/// 改写台词的字数预算：目标字数 = 时长 × 语速；允许区间 [0.85×目标, 1.0×目标]。
public struct CharBudget: Equatable, Sendable {
    /// 目标字数（= 时长 × 语速，四舍五入）
    public let target: Int
    /// 下限（0.85×目标，四舍五入）
    public let minChars: Int
    /// 上限（= 目标）
    public let maxChars: Int

    public init(target: Int, minChars: Int, maxChars: Int) {
        self.target = target
        self.minChars = minChars
        self.maxChars = maxChars
    }

    /// 由分镜时长与目标语速计算预算。时长或语速非正时返回全 0。
    public static func forDuration(_ seconds: Double, charsPerSecond cps: Double) -> CharBudget {
        guard seconds > 0, cps > 0 else {
            return CharBudget(target: 0, minChars: 0, maxChars: 0)
        }
        let t = seconds * cps
        let maxC = Int(t.rounded())
        let minC = Int((t * 0.85).rounded())
        return CharBudget(target: maxC, minChars: minC, maxChars: maxC)
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter CharBudgetTests`
Expected: PASS（4 测试全过）

- [ ] **Step 5: 注册到 xcodeproj 并验证 app 编译**

在 `MixCut.xcodeproj/project.pbxproj` 仿照已有 `SubtitleMaskRect.swift` 的 4 处条目，为 `CharBudget.swift` 添加：PBXBuildFile、PBXFileReference、PBXGroup（MixCutCore 组）、Sources Build Phase。
Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Sources/MixCutCore/CharBudget.swift Tests/MixCutCoreTests/CharBudgetTests.swift MixCut.xcodeproj/project.pbxproj
git commit -m "feat(dubbing): 字数预算计算 CharBudget (P2-1)"
```

---

### Task 2: 改写数据类型 `RewriteTypes`

**Files:**
- Create: `Sources/MixCutCore/RewriteTypes.swift`
- Test: `Tests/MixCutCoreTests/RewriteTypesTests.swift`
- Modify: `MixCut.xcodeproj/project.pbxproj`（注册 `RewriteTypes.swift`，4 处）

**Interfaces:**
- Consumes: 无
- Produces:
  - `struct RewriteSegmentInput: Equatable, Sendable { let segmentId: String; let originalText: String; let durationSeconds: Double; let keywords: [String] }`
  - `struct RewrittenSegment: Equatable, Sendable { let segmentId: String; let rewrittenText: String; let isFallback: Bool; let withinBudget: Bool }`
  - `struct RewriteResultDTO: Codable, Equatable, Sendable { struct Item: Codable, Equatable, Sendable { let segmentId: String; let rewrittenText: String }; let segments: [Item] }`

- [ ] **Step 1: 写失败测试**

`Tests/MixCutCoreTests/RewriteTypesTests.swift`:
```swift
import Foundation
import Testing
@testable import MixCutCore

@Suite("Rewrite 数据类型")
struct RewriteTypesTests {
    @Test("RewriteResultDTO 可从 AI 风格 JSON 解码")
    func decodeDTO() throws {
        let json = """
        {"segments":[{"segmentId":"s1","rewrittenText":"全新文案一"},{"segmentId":"s2","rewrittenText":"全新文案二"}]}
        """.data(using: .utf8)!
        let dto = try JSONDecoder().decode(RewriteResultDTO.self, from: json)
        #expect(dto.segments.count == 2)
        #expect(dto.segments[0].segmentId == "s1")
        #expect(dto.segments[1].rewrittenText == "全新文案二")
    }

    @Test("输入/输出值语义相等")
    func valueEquality() {
        let a = RewriteSegmentInput(segmentId: "s1", originalText: "原文", durationSeconds: 2.0, keywords: ["A"])
        let b = RewriteSegmentInput(segmentId: "s1", originalText: "原文", durationSeconds: 2.0, keywords: ["A"])
        #expect(a == b)
        let r = RewrittenSegment(segmentId: "s1", rewrittenText: "新", isFallback: false, withinBudget: true)
        #expect(r.segmentId == "s1")
        #expect(r.withinBudget)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter RewriteTypesTests`
Expected: FAIL（`cannot find 'RewriteResultDTO' in scope`）

- [ ] **Step 3: 写最小实现**

`Sources/MixCutCore/RewriteTypes.swift`:
```swift
import Foundation

/// 送入改写引擎的单个可重配分镜（明星保留原声分镜由调用方提前剔除）。
public struct RewriteSegmentInput: Equatable, Sendable {
    public let segmentId: String
    public let originalText: String
    public let durationSeconds: Double
    public let keywords: [String]

    public init(segmentId: String, originalText: String, durationSeconds: Double, keywords: [String]) {
        self.segmentId = segmentId
        self.originalText = originalText
        self.durationSeconds = durationSeconds
        self.keywords = keywords
    }
}

/// 改写引擎产出的单个分镜结果。
public struct RewrittenSegment: Equatable, Sendable {
    public let segmentId: String
    public let rewrittenText: String
    /// AI 未返回该分镜 → 回退原台词，置 true
    public let isFallback: Bool
    /// 字数是否落在预算区间内
    public let withinBudget: Bool

    public init(segmentId: String, rewrittenText: String, isFallback: Bool, withinBudget: Bool) {
        self.segmentId = segmentId
        self.rewrittenText = rewrittenText
        self.isFallback = isFallback
        self.withinBudget = withinBudget
    }
}

/// AI 返回的原始 JSON 结构（generateJSON 的 responseType）。
public struct RewriteResultDTO: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public let segmentId: String
        public let rewrittenText: String

        public init(segmentId: String, rewrittenText: String) {
            self.segmentId = segmentId
            self.rewrittenText = rewrittenText
        }
    }
    public let segments: [Item]

    public init(segments: [Item]) {
        self.segments = segments
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter RewriteTypesTests`
Expected: PASS

- [ ] **Step 5: 注册到 xcodeproj 并验证 app 编译**

为 `RewriteTypes.swift` 在 pbxproj 加 4 处条目。
Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Sources/MixCutCore/RewriteTypes.swift Tests/MixCutCoreTests/RewriteTypesTests.swift MixCut.xcodeproj/project.pbxproj
git commit -m "feat(dubbing): 改写输入/输出/DTO 数据类型 (P2-2)"
```

---

### Task 3: prompt 构建 `RewritePromptBuilder`

**Files:**
- Create: `Sources/MixCutCore/RewritePromptBuilder.swift`
- Test: `Tests/MixCutCoreTests/RewritePromptBuilderTests.swift`
- Modify: `MixCut.xcodeproj/project.pbxproj`（注册 `RewritePromptBuilder.swift`，4 处）

**Interfaces:**
- Consumes: `RewriteSegmentInput`(Task 2), `CharBudget`(Task 1)
- Produces: `static func RewritePromptBuilder.build(template: String, inputs: [RewriteSegmentInput], style: String, charsPerSecond cps: Double) -> String`
  - 模板里 `{{STYLE}}` 替换为风格、`{{SEGMENTS}}` 替换为逐分镜清单（含 segmentId / 时长 / 字数预算 / 关键词 / 原台词）

- [ ] **Step 1: 写失败测试**

`Tests/MixCutCoreTests/RewritePromptBuilderTests.swift`:
```swift
import Testing
@testable import MixCutCore

@Suite("RewritePromptBuilder")
struct RewritePromptBuilderTests {
    private var sampleInputs: [RewriteSegmentInput] {
        [
            RewriteSegmentInput(segmentId: "s1", originalText: "原台词一", durationSeconds: 3.0, keywords: ["补水", "9.9元"]),
            RewriteSegmentInput(segmentId: "s2", originalText: "原台词二", durationSeconds: 2.0, keywords: [])
        ]
    }

    @Test("占位符被替换，风格与分镜清单注入")
    func substitutesPlaceholders() {
        let tpl = "风格：{{STYLE}}\n分镜：\n{{SEGMENTS}}"
        let out = RewritePromptBuilder.build(template: tpl, inputs: sampleInputs, style: "快闪风格", charsPerSecond: 5.0)
        #expect(!out.contains("{{STYLE}}"))
        #expect(!out.contains("{{SEGMENTS}}"))
        #expect(out.contains("快闪风格"))
    }

    @Test("每个分镜的 id / 字数预算 / 关键词 / 原台词都进入 prompt")
    func includesPerSegmentFacts() {
        let tpl = "{{SEGMENTS}}"
        let out = RewritePromptBuilder.build(template: tpl, inputs: sampleInputs, style: "x", charsPerSecond: 5.0)
        #expect(out.contains("s1"))
        #expect(out.contains("s2"))
        #expect(out.contains("13~15")) // s1: 3.0×5=15，下限 round(12.75)=13
        #expect(out.contains("9~10"))  // s2: 2.0×5=10，下限 round(8.5)=9
        #expect(out.contains("补水"))
        #expect(out.contains("9.9元"))
        #expect(out.contains("原台词一"))
        #expect(out.contains("无")) // s2 无关键词
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter RewritePromptBuilderTests`
Expected: FAIL（`cannot find 'RewritePromptBuilder'`）

- [ ] **Step 3: 写最小实现**

`Sources/MixCutCore/RewritePromptBuilder.swift`:
```swift
import Foundation

/// 把改写输入拼成可发送给 AI 的 prompt。模板里 {{STYLE}} / {{SEGMENTS}} 为占位符。
public enum RewritePromptBuilder {
    public static func build(template: String,
                             inputs: [RewriteSegmentInput],
                             style: String,
                             charsPerSecond cps: Double) -> String {
        let segmentLines = inputs.map { input -> String in
            let budget = CharBudget.forDuration(input.durationSeconds, charsPerSecond: cps)
            let kw = input.keywords.isEmpty ? "无" : input.keywords.joined(separator: "、")
            let dur = String(format: "%.2f", input.durationSeconds)
            return "- segmentId=\(input.segmentId) | 时长=\(dur)s | 字数预算=\(budget.minChars)~\(budget.maxChars)字 | 必须保留关键事实=\(kw) | 原台词：\(input.originalText)"
        }.joined(separator: "\n")

        return template
            .replacingOccurrences(of: "{{STYLE}}", with: style)
            .replacingOccurrences(of: "{{SEGMENTS}}", with: segmentLines)
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter RewritePromptBuilderTests`
Expected: PASS

- [ ] **Step 5: 注册到 xcodeproj 并验证 app 编译**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Sources/MixCutCore/RewritePromptBuilder.swift Tests/MixCutCoreTests/RewritePromptBuilderTests.swift MixCut.xcodeproj/project.pbxproj
git commit -m "feat(dubbing): 改写 prompt 构建 RewritePromptBuilder (P2-3)"
```

---

### Task 4: 结果映射 `RewriteResultMapper`

**Files:**
- Create: `Sources/MixCutCore/RewriteResultMapper.swift`
- Test: `Tests/MixCutCoreTests/RewriteResultMapperTests.swift`
- Modify: `MixCut.xcodeproj/project.pbxproj`（注册 `RewriteResultMapper.swift`，4 处）

**Interfaces:**
- Consumes: `RewriteResultDTO`/`RewriteSegmentInput`/`RewrittenSegment`(Task 2), `CharBudget`(Task 1)
- Produces: `static func RewriteResultMapper.map(dto: RewriteResultDTO, inputs: [RewriteSegmentInput], charsPerSecond cps: Double) -> [RewrittenSegment]`
  - 以 `inputs` 顺序为准；AI 漏返回/返回空白 → 回退原台词且 `isFallback=true`；多余 segmentId 忽略；`withinBudget` 按字符数判定。

- [ ] **Step 1: 写失败测试**

`Tests/MixCutCoreTests/RewriteResultMapperTests.swift`:
```swift
import Testing
@testable import MixCutCore

@Suite("RewriteResultMapper")
struct RewriteResultMapperTests {
    private var inputs: [RewriteSegmentInput] {
        [
            RewriteSegmentInput(segmentId: "s1", originalText: "原一", durationSeconds: 3.0, keywords: []), // 预算 13~15
            RewriteSegmentInput(segmentId: "s2", originalText: "原二", durationSeconds: 2.0, keywords: [])  // 预算 9~10
        ]
    }

    @Test("全部命中：按输入顺序映射，非回退")
    func fullCoverage() {
        let dto = RewriteResultDTO(segments: [
            .init(segmentId: "s2", rewrittenText: "九个字九个字九"),   // 9 字 → 在 9~10 内
            .init(segmentId: "s1", rewrittenText: "十三个字十三个字十三个")  // 13 字 → 在 13~15 内
        ])
        let out = RewriteResultMapper.map(dto: dto, inputs: inputs, charsPerSecond: 5.0)
        #expect(out.map(\.segmentId) == ["s1", "s2"]) // 顺序按 inputs
        #expect(out.allSatisfy { !$0.isFallback })
        #expect(out[0].withinBudget)
        #expect(out[1].withinBudget)
    }

    @Test("漏返回 → 回退原台词并标记 isFallback")
    func missingFallsBack() {
        let dto = RewriteResultDTO(segments: [
            .init(segmentId: "s1", rewrittenText: "十三个字十三个字十三个")
        ])
        let out = RewriteResultMapper.map(dto: dto, inputs: inputs, charsPerSecond: 5.0)
        #expect(out[1].segmentId == "s2")
        #expect(out[1].isFallback)
        #expect(out[1].rewrittenText == "原二")
        #expect(!out[1].withinBudget)
    }

    @Test("返回空白 → 视为漏返回，回退")
    func blankFallsBack() {
        let dto = RewriteResultDTO(segments: [
            .init(segmentId: "s1", rewrittenText: "   "),
            .init(segmentId: "s2", rewrittenText: "九个字九个字九")
        ])
        let out = RewriteResultMapper.map(dto: dto, inputs: inputs, charsPerSecond: 5.0)
        #expect(out[0].isFallback)
        #expect(out[0].rewrittenText == "原一")
    }

    @Test("多余 segmentId 被忽略，超预算字数 withinBudget=false")
    func extraIgnoredAndBudget() {
        let dto = RewriteResultDTO(segments: [
            .init(segmentId: "s1", rewrittenText: "这句话太长太长太长太长太长太长了"), // >15 字
            .init(segmentId: "s2", rewrittenText: "九个字九个字九"),
            .init(segmentId: "ghost", rewrittenText: "不存在")
        ])
        let out = RewriteResultMapper.map(dto: dto, inputs: inputs, charsPerSecond: 5.0)
        #expect(out.count == 2)
        #expect(!out[0].withinBudget) // s1 超上限
        #expect(!out[0].isFallback)   // 但有内容，不算回退
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter RewriteResultMapperTests`
Expected: FAIL（`cannot find 'RewriteResultMapper'`）

- [ ] **Step 3: 写最小实现**

`Sources/MixCutCore/RewriteResultMapper.swift`:
```swift
import Foundation

/// 把 AI 返回的 DTO 按输入分镜映射成结果：保序、漏返回回退原文、超预算标记。
public enum RewriteResultMapper {
    public static func map(dto: RewriteResultDTO,
                           inputs: [RewriteSegmentInput],
                           charsPerSecond cps: Double) -> [RewrittenSegment] {
        // segmentId → 改写文本（重复 id 取首个）
        var byId: [String: String] = [:]
        for item in dto.segments where byId[item.segmentId] == nil {
            byId[item.segmentId] = item.rewrittenText
        }

        return inputs.map { input in
            let budget = CharBudget.forDuration(input.durationSeconds, charsPerSecond: cps)
            let raw = byId[input.segmentId]
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if !trimmed.isEmpty {
                let count = trimmed.count
                let within = count >= budget.minChars && count <= budget.maxChars
                return RewrittenSegment(segmentId: input.segmentId,
                                        rewrittenText: trimmed,
                                        isFallback: false,
                                        withinBudget: within)
            } else {
                // 漏返回或空白 → 回退原台词
                return RewrittenSegment(segmentId: input.segmentId,
                                        rewrittenText: input.originalText,
                                        isFallback: true,
                                        withinBudget: false)
            }
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter RewriteResultMapperTests`
Expected: PASS（4 测试全过）

- [ ] **Step 5: 注册到 xcodeproj 并验证 app 编译**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Sources/MixCutCore/RewriteResultMapper.swift Tests/MixCutCoreTests/RewriteResultMapperTests.swift MixCut.xcodeproj/project.pbxproj
git commit -m "feat(dubbing): AI 改写结果映射 RewriteResultMapper (P2-4)"
```

---

### Task 5: 改写 prompt 模板 `script_rewrite_prompt.md`

**Files:**
- Create: `MixCut/Resources/Prompts/script_rewrite_prompt.md`
- Modify: `MixCut.xcodeproj/project.pbxproj`（确保该 .md 进入 app bundle 的 Resources Copy 阶段）

**Interfaces:**
- Consumes: 无（由 Task 6 `PromptLoader().loadPrompt(named: "script_rewrite_prompt")` 加载）
- Produces: 含 `{{STYLE}}` 与 `{{SEGMENTS}}` 占位符、要求严格 JSON 输出 `{"segments":[{"segmentId","rewrittenText"}]}` 的模板文件。

- [ ] **Step 1: 写模板文件**

`MixCut/Resources/Prompts/script_rewrite_prompt.md`:
```markdown
# 广告台词改写任务

你是资深信息流广告文案改写专家。下面给出某条广告视频里若干「可重配」分镜的原始台词，请逐条改写成**全新说法**，用于生成差异化投放版本（规避平台去重），同时保持整段旁白连贯自然。

## 本版风格
{{STYLE}}

## 硬性约束（必须全部满足）
1. **逐条改写**：为下方每个 segmentId 产出一条新台词，segmentId 必须原样回填，一个都不能漏。
2. **字数预算**：每条新台词的字数必须落在该分镜「字数预算」区间内（含端点）。宁可接近上限，不要低于下限。中文按汉字计数。
3. **保留关键事实**：「必须保留关键事实」里的产品名、价格、数字、卖点不可篡改、不可遗漏，只能换表达方式。若为「无」则无此约束。
4. **差异化**：尽量换措辞、换句式、换角度，与原台词明显不同，但语义一致。
5. **承上启下**：相邻分镜读起来要连贯，像同一个旁白一气呵成。
6. **不要旁白外内容**：只写口播台词本身，不要加镜头说明、表情、括号注释。

## 待改写分镜
{{SEGMENTS}}

## 输出格式（严格 JSON，不要任何额外文字/解释/代码块标记）
{"segments":[{"segmentId":"对应id","rewrittenText":"改写后的台词"}]}
```

- [ ] **Step 2: 确认资源纳入 bundle**

检查 `MixCut.xcodeproj/project.pbxproj` 中 `Prompts` 是文件夹引用（蓝色，整目录已在 Resources Copy 阶段）还是分文件 group：
- 若为文件夹引用：磁盘新增 .md 自动进 bundle，无需改 pbxproj。
- 若为分文件 group：仿照已有 `ad_styles.md` 的条目，为 `script_rewrite_prompt.md` 加 PBXBuildFile + PBXFileReference + PBXGroup + Resources Build Phase。

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 验证运行时能加载到模板**

编译后产物里确认 bundle 含该文件：
Run: `find /Users/menggang/Library/Developer/Xcode/DerivedData/MixCut-byytuggmhodpumcmwnwrtzwkmavr/Build/Products/Debug/MixCut.app -name "script_rewrite_prompt.md"`
Expected: 输出该文件路径（非空）

- [ ] **Step 4: Commit**

```bash
git add MixCut/Resources/Prompts/script_rewrite_prompt.md MixCut.xcodeproj/project.pbxproj
git commit -m "feat(dubbing): 台词改写 prompt 模板 (P2-5)"
```

---

### Task 6: 改写服务 `ScriptRewriteService`

**Files:**
- Create: `MixCut/Services/AI/ScriptRewriteService.swift`
- Modify: `MixCut.xcodeproj/project.pbxproj`（注册 `ScriptRewriteService.swift`，4 处）

**Interfaces:**
- Consumes:
  - `RewritePromptBuilder.build(...)`(Task 3), `RewriteResultMapper.map(...)`(Task 4), `RewriteResultDTO`/`RewriteSegmentInput`/`RewrittenSegment`(Task 2)
  - 现有：`AIProvider.generateJSON(prompt:responseType:)`、`AIProviderManager.currentProvider()`、`PromptLoader().loadPrompt(named:)`
- Produces:
  - `actor ScriptRewriteService { init(provider: (any AIProvider)? = nil) }`
  - `func rewrite(inputs: [RewriteSegmentInput], style: String, charsPerSecond: Double, onProgress: ((String) -> Void)?) async throws -> [RewrittenSegment]`

- [ ] **Step 1: 写实现**

`MixCut/Services/AI/ScriptRewriteService.swift`:
```swift
import Foundation

/// AI 整片台词改写服务（薄胶水）。
/// 纯逻辑（prompt 构建 / 结果映射 / 字数预算）在 MixCutCore，便于 swift test 覆盖。
/// 本 actor 只负责：加载模板 → 构建 prompt → 调 AIProvider → 映射结果。
actor ScriptRewriteService {
    private let injectedProvider: (any AIProvider)?
    private let promptLoader = PromptLoader()

    /// - Parameter provider: 注入用于测试；生产传 nil，运行时动态取当前 provider（Settings 改了立即生效）。
    init(provider: (any AIProvider)? = nil) {
        self.injectedProvider = provider
    }

    private var provider: any AIProvider {
        injectedProvider ?? AIProviderManager.currentProvider()
    }

    /// 改写一个视频内所有"可重配"分镜的台词（明星保留原声分镜由调用方剔除后传入）。
    /// - Parameters:
    ///   - inputs: 可重配分镜的 [原台词 + 时长 + 关键词]
    ///   - style: 本版差异化风格说明（来自 ad_styles）
    ///   - charsPerSecond: 目标语速（字/秒）
    /// - Returns: 与 inputs 同序的改写结果；AI 漏返回的分镜回退原台词并标记 isFallback。
    func rewrite(inputs: [RewriteSegmentInput],
                 style: String,
                 charsPerSecond: Double,
                 onProgress: ((String) -> Void)? = nil) async throws -> [RewrittenSegment] {
        guard !inputs.isEmpty else { return [] }

        onProgress?("正在构建改写 prompt…")
        let template = promptLoader.loadPrompt(named: "script_rewrite_prompt") ?? Self.fallbackTemplate
        let prompt = RewritePromptBuilder.build(template: template,
                                                inputs: inputs,
                                                style: style,
                                                charsPerSecond: charsPerSecond)

        onProgress?("正在调用 AI 改写台词…")
        let dto = try await provider.generateJSON(prompt: prompt, responseType: RewriteResultDTO.self)

        onProgress?("改写完成，正在校验字数预算…")
        return RewriteResultMapper.map(dto: dto, inputs: inputs, charsPerSecond: charsPerSecond)
    }

    /// 模板文件缺失时的兜底，避免整功能因资源问题挂掉。
    private static let fallbackTemplate = """
    你是广告文案改写专家。把下列分镜原台词逐条改写为全新说法，保持关键事实不变，字数落在各自预算区间内。
    风格：{{STYLE}}
    分镜：
    {{SEGMENTS}}
    严格输出 JSON：{"segments":[{"segmentId":"id","rewrittenText":"新台词"}]}
    """
}
```

- [ ] **Step 2: 注册到 xcodeproj**

为 `ScriptRewriteService.swift` 在 pbxproj 加 4 处条目（参照同目录 `AIAnalysisService.swift`）。

- [ ] **Step 3: 编译验证（app target，含全部 MixCutCore 符号）**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 跑全部 MixCutCore 测试确认无回归**

Run: `swift test 2>&1 | tail -5`
Expected: 全部测试通过（含 P1 的 SubtitleMaskRect 与本期 4 个新套件）

- [ ] **Step 5: Commit**

```bash
git add MixCut/Services/AI/ScriptRewriteService.swift MixCut.xcodeproj/project.pbxproj
git commit -m "feat(dubbing): AI 整片台词改写服务 ScriptRewriteService (P2-6)"
```

---

## 自检（Self-Review）

**Spec 覆盖（对照设计文档第 5 节）：**
- 5.1 校对关卡 → **本期不做，归 P5 DubbingView**（已在 Global Constraints 标注；本引擎只产出值类型结果，校对/写回 `Segment.text` 由 P5 UI 完成）。
- 5.2 整片一次调用 → Task 6 `rewrite(inputs:...)` 一次性打包所有分镜。
- 5.2 字数预算 `[0.85×, 1.0×]` → Task 1 `CharBudget`。
- 5.2 prompt 硬约束（保留 keywords / 差异化 / 承上启下）→ Task 5 模板。
- 5.2 N 版差异化（不同 style）→ Task 6 `style` 参数，由 P5 编排循环调用。
- 5.2 走 `generateJSON` 返回 `[{segmentId, rewrittenText}]` → Task 2 DTO + Task 6 调用。

**占位符扫描：** 无 TBD/TODO；每个代码步骤含完整代码；测试含真实断言。

**类型一致性：** `RewriteSegmentInput`/`RewrittenSegment`/`RewriteResultDTO`/`CharBudget` 在 Task 1-2 定义，Task 3/4/6 引用签名一致；`charsPerSecond` 参数名贯穿 `CharBudget.forDuration` / `RewritePromptBuilder.build` / `RewriteResultMapper.map` / `ScriptRewriteService.rewrite` 一致。

**字数预算口径一致：** Builder 显示的 `minChars~maxChars`、Mapper 的 `withinBudget` 判定、CharBudget 计算三者同源（都走 `CharBudget.forDuration`），不会出现"prompt 说 13~15、校验却按别的区间"。
