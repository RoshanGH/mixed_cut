# 逐句字幕时间 + 逐句烧录 — 实现计划

> **For agentic workers:** 用 superpowers:subagent-driven-development 或 superpowers:executing-plans 执行。步骤用 `- [ ]` 追踪。
> **本项目铁律**：改完必 xcodebuild 编译 + 重启 app + 截图自测；**不自动 git 提交**（攒着等用户验收，"commit"步骤=逻辑检查点，执行时按用户节奏）；不改坏遮挡三模式/首帧不黑/导出串行/参与组合/切项目联动/9:16。

**Goal:** 变体烧录字幕从"整段糊在画面上"改为"逐句按配音实际说到的时间出现"；时间由内置 whisper 对变体配音自动对齐，用户可手调。

**Architecture:** 纯对齐逻辑放 MixCutCore（可 `swift test`）→ SegmentDub 加 captionLines 字段 → 配音(重)生成后 ViewModel 自动对齐写库 → 独立弹窗编辑器调时间 → 最后改 DubSegmentGraph 逐句 overlay 烧录。分 5 阶段，敏感的导出改造放最后。

**Tech Stack:** Swift / SwiftUI / SwiftData / MixCutCore(Swift Testing) / 内置 whisper.cpp / ffmpeg filter_complex。

参考 spec：`docs/superpowers/specs/2026-07-09-per-sentence-subtitle-timing-design.md`

---

## ⚠️ 评审修正（必读，覆盖下文对应处）
1. **绝不写 `import MixCutCore`**：app 与 MixCutCore 同模块编译（`Package.swift` 注释 + `grep` 0 命中），CaptionLine/AlignWord/SentenceTimingAligner 在 app 侧直接用。（Phase 2/3 已按此改。）
2. **新建 Core 文件必须登记进 xcodeproj app target**：`CaptionLine.swift`/`SentenceTimingAligner.swift` 已用 ruby xcodeproj 加入 MixCut target 的 Sources build phase（否则 Xcode 编译 `cannot find CaptionLine`）。✅ 已做。
3. **Phase 3：alignCaptions 只 hook 在 `generateAudio`**（`updateVariantText`/`generateAllAudio` 都最终走 generateAudio；唯一落库点 `dub.audioFilePath=…; save()` 之后调一次即可覆盖首次/批量/改词重配全部路径）。**不要**再在 updateVariantText 调（会对同批 dub 双跑 whisper）。取舍：**同步 await（阻塞但安全）**——ASR 在 ASRService(actor) 子进程、不卡主线程，但会延长"生成完成"；不要 detached Task（ModelContext 非 Sendable、必须主线程写）。
4. **Phase 5 构造点更正为 4 处**：`DubExportService.swift` 有 3 处 `DubSegmentSpec(`（:56 锁定、:65 选定配音、:76 无配音回退——锁定/回退填 `[]`）+ `VariantBatchExportService.swift` 1 处；多 PNG 逻辑集中改 `renderSegment`（:220）。`exportSingleSegment` 收现成 spec，不单独构造。
5. **Phase 5 必须同步改 `Tests/MixCutCoreTests/DubSegmentGraphTests.swift`**：`build(...)` 有 10 处调用（:7/60/73/87/102/114/127/143/160/174）用旧 `captionOrigin/captionInputIndex` 参数，改数组签名后全部要更新 + 重写 overlay 断言为逐句 `enable=between`。否则 `swift test` 变红。
6. **Phase 5 保留守卫**：`DubSegmentGraph.swift:66` `keepOriginalAudio ? nil : caption`——改数组签名时保留"keepOriginalAudio 时清空 captions"。
7. **旧数据兜底**：本功能上线前的 dub 无 captionLines → Phase 5 渲染处：`captionLines 为空且是配音变体` 时回退渲染整段 `rewrittenText` 一张（保旧行为），避免老数据静默丢字幕。
8. **统一画布高度**具体化：`CaptionRenderer.render` 的 `canvasH` 随行数变；需在渲染层加"固定/取最大画布高"参数或统一落位 y，Phase 5 落地时具体实现。

---

## 文件结构

- **Create** `Sources/MixCutCore/CaptionLine.swift` — `CaptionLine` 值类型（text/start/end），MixCutCore 与 app 共用。
- **Create** `Sources/MixCutCore/SentenceTimingAligner.swift` — 纯对齐算法（rewrittenText + asrWords + audioDuration → [CaptionLine]）。
- **Create** `Tests/MixCutCoreTests/SentenceTimingAlignerTests.swift` — 单测。
- **Modify** `MixCut/Models/SegmentDub.swift` — 加 `captionLinesData: Data?` + `captionLines` 计算属性。
- **Modify** `MixCut/ViewModels/DubbingViewModel.swift` — 加 `alignCaptions(for:)`，在 generateAudio / updateVariantText 的配音落库后调用。
- **Create** `MixCut/Views/SegmentLibrary/CaptionTimingEditorSheet.swift` — 逐句时间编辑器弹窗。
- **Modify** `MixCut/Views/SegmentLibrary/SegmentVariantInspector.swift` — 变体卡加"逐句字幕"入口。
- **Modify** `Sources/MixCutCore/DubSegmentGraph.swift` — build 签名 单 caption → captions 数组 + `enable=between`。
- **Modify** `MixCut/Services/Export/DubExportService.swift` — `DubSegmentSpec.captionText` → `captionLines`；构造点改取 dub.captionLines；多 PNG 渲染 + 输入序号重排。
- **Modify** `MixCut/Services/Export/VariantBatchExportService.swift` — 构造点同步改。

---

## Phase 1 · 纯对齐逻辑（MixCutCore，TDD，零 app 依赖）

### Task 1.1: CaptionLine 值类型

**Files:** Create `Sources/MixCutCore/CaptionLine.swift`

- [ ] **Step 1: 写类型**

```swift
import Foundation

/// 一行逐句字幕：文本（原始，含标点；显示时另行 stripPunctuation）+ 相对分镜起点的秒时间窗。
public struct CaptionLine: Codable, Hashable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) {
        self.text = text; self.start = start; self.end = end
    }
}
```

- [ ] **Step 2: 编译** `swift build`（MixCutCore）→ 期望成功。
- [ ] **Step 3: commit**（检查点）`feat(core): add CaptionLine`

### Task 1.2: SentenceTimingAligner —— 先写失败测试

**Files:** Create `Tests/MixCutCoreTests/SentenceTimingAlignerTests.swift`

对齐器输入：`text`（改写台词，含标点）、`words: [(text,start,end)]`（ASR 字/token 级）、`audioDuration`。输出 `[CaptionLine]`（按 start 升序、clamp 到 [0, segmentDuration]）。核心规则见 spec §4.2：**主策略=按字符比例分到语音跨度**，有 words 时用字符匹配精修边界。

- [ ] **Step 1: 写测试（会编译失败，因 aligner 未实现）**

```swift
import Testing
@testable import MixCutCore

@Suite("SentenceTimingAligner")
struct SentenceTimingAlignerTests {

    // 用一个简化的 word 输入类型（aligner 只需要 text/start/end）
    private func w(_ t: String, _ s: Double, _ e: Double) -> AlignWord { AlignWord(text: t, start: s, end: e) }

    @Test("按标点切句 + 比例分配（无 words 时用 audioDuration 等比）")
    func proportionalNoWords() {
        let lines = SentenceTimingAligner.align(
            text: "你好啊。今天天气不错！",   // 两句：4字 / 6字（去标点）
            words: [], audioDuration: 10, segmentDuration: 12)
        #expect(lines.count == 2)
        #expect(lines[0].text.contains("你好"))
        #expect(abs(lines[0].start - 0) < 0.01)
        // 4:6 比例 → 第一句约 [0,4]，第二句约 [4,10]
        #expect(abs(lines[0].end - 4.0) < 0.5)
        #expect(abs(lines[1].end - 10.0) < 0.01)
        // 升序且不重叠
        #expect(lines[0].end <= lines[1].start + 0.001)
    }

    @Test("有 words 时用整体语音跨度做比例基准")
    func proportionalWithSpan() {
        // 语音从 1s 到 9s（前后各有静音），两句 4字/4字
        let words = [w("你好啊哈", 1.0, 5.0), w("今天不错", 5.0, 9.0)]
        let lines = SentenceTimingAligner.align(
            text: "你好啊哈。今天不错。", words: words, audioDuration: 10, segmentDuration: 12)
        #expect(lines.count == 2)
        #expect(lines[0].start >= 0.99 && lines[0].start <= 1.01)   // 跨度从首词 start 起
        #expect(lines[1].end <= 9.01)                                // 到末词 end 止
    }

    @Test("clamp 到 [0, segmentDuration]")
    func clamp() {
        let lines = SentenceTimingAligner.align(
            text: "唯一一句话。", words: [w("唯一一句话", 0, 100)], audioDuration: 100, segmentDuration: 8)
        #expect(lines.count == 1)
        #expect(lines[0].start >= 0)
        #expect(lines[0].end <= 8.0 + 0.001)
    }

    @Test("空文本 → 空结果，不崩")
    func emptyText() {
        #expect(SentenceTimingAligner.align(text: "  。！", words: [], audioDuration: 5, segmentDuration: 5).isEmpty)
    }

    @Test("多种句末标点 + 换行切句")
    func punctuation() {
        let lines = SentenceTimingAligner.align(
            text: "一句话？\n第二句！第三句。", words: [], audioDuration: 9, segmentDuration: 9)
        #expect(lines.count == 3)
    }
}
```

- [ ] **Step 2: 跑测试确认失败** Run: `swift test --filter SentenceTimingAligner`　Expected: 编译失败（`AlignWord`/`SentenceTimingAligner` 未定义）。

### Task 1.3: 实现 SentenceTimingAligner

**Files:** Create `Sources/MixCutCore/SentenceTimingAligner.swift`

- [ ] **Step 1: 实现**

```swift
import Foundation

/// 对齐器需要的最小 word 结构（app 层用 ASRWord 映射进来）。
public struct AlignWord: Sendable {
    public let text: String
    public let start: Double
    public let end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

/// 把"改写台词"按标点切句，用配音 ASR（或比例）给每句配上 [start,end]。纯函数、可单测。
/// 规则见 spec §4.2：主策略=按去标点字符数比例分到"语音跨度"；有 words 时用字符顺序匹配精修边界。
public enum SentenceTimingAligner {

    private static let sentenceEnders: Set<Character> = ["。","！","？","!","?",".",";","；","\n"]
    private static let stripped: Set<Character> = ["，",",","、","。","！","？","!","?",".",";","；"," ","\n","\r","\t","…","·","：",":"]

    /// 去标点/空白，返回纯字符数组（用于比例与匹配）。
    static func chars(_ s: String) -> [Character] { s.filter { !stripped.contains($0) } }

    /// 按句末标点/换行切句，返回每句原文（保留内部非句末标点；空/纯标点段丢弃）。
    static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in text {
            cur.append(ch)
            if sentenceEnders.contains(ch) {
                if !chars(cur).isEmpty { out.append(cur.trimmingCharacters(in: .whitespacesAndNewlines)) }
                cur = ""
            }
        }
        if !chars(cur).isEmpty { out.append(cur.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return out
    }

    public static func align(text: String, words: [AlignWord], audioDuration: Double, segmentDuration: Double) -> [CaptionLine] {
        let sentences = splitSentences(text)
        guard !sentences.isEmpty else { return [] }

        // 语音跨度：有 words 用 [首词.start, 末词.end]，否则 [0, audioDuration]
        let spanStart = words.first?.start ?? 0
        let spanEnd = max(spanStart + 0.01, words.last?.end ?? max(audioDuration, 0.01))

        // 主策略：按去标点字符数比例分配到跨度
        let counts = sentences.map { max(1, chars($0).count) }
        let total = counts.reduce(0, +)
        var lines: [CaptionLine] = []
        var acc = 0
        for (i, s) in sentences.enumerated() {
            let a = spanStart + (spanEnd - spanStart) * Double(acc) / Double(total)
            acc += counts[i]
            let b = spanStart + (spanEnd - spanStart) * Double(acc) / Double(total)
            lines.append(CaptionLine(text: s, start: a, end: b))
        }

        // 精修（有 words 时）：把 words 展成"字符→时间"序列，按字符数线性内插；用各句去标点字符顺序单向匹配，命中则替换边界。
        if !words.isEmpty {
            lines = refine(lines: lines, sentences: sentences, words: words)
        }

        // clamp + 升序 + 不重叠兜底
        return normalize(lines, segmentDuration: segmentDuration)
    }

    /// 字符级时间序列（一个多字 token 的 [start,end] 按字符线性内插）。
    private static func charTimeline(_ words: [AlignWord]) -> [(Character, Double, Double)] {
        var seq: [(Character, Double, Double)] = []
        for wd in words {
            let cs = chars(wd.text)
            guard !cs.isEmpty else { continue }
            let dur = max(0, wd.end - wd.start) / Double(cs.count)
            for (k, c) in cs.enumerated() {
                seq.append((c, wd.start + dur * Double(k), wd.start + dur * Double(k + 1)))
            }
        }
        return seq
    }

    private static func refine(lines: [CaptionLine], sentences: [String], words: [AlignWord]) -> [CaptionLine] {
        let tl = charTimeline(words)
        guard !tl.isEmpty else { return lines }
        var ptr = 0
        var out = lines
        for i in 0..<sentences.count {
            let sc = chars(sentences[i])
            guard !sc.isEmpty else { continue }
            // 从 ptr 起找该句首字
            var startT: Double? = nil, endT: Double? = nil
            var j = ptr
            var matched = 0
            while j < tl.count && matched < sc.count {
                if tl[j].0 == sc[matched] {
                    if matched == 0 { startT = tl[j].1 }
                    endT = tl[j].2
                    matched += 1
                }
                j += 1
            }
            if let s = startT, let e = endT, matched >= max(1, sc.count / 2) {
                out[i].start = s; out[i].end = max(s + 0.05, e)
                ptr = j  // 单向前进
            }
        }
        return out
    }

    private static func normalize(_ lines: [CaptionLine], segmentDuration: Double) -> [CaptionLine] {
        var out = lines.sorted { $0.start < $1.start }
        for i in out.indices {
            out[i].start = min(max(0, out[i].start), segmentDuration)
            out[i].end = min(max(out[i].start + 0.05, out[i].end), segmentDuration)
            if i > 0, out[i].start < out[i-1].end { out[i].start = out[i-1].end } // 不重叠
            if out[i].end < out[i].start { out[i].end = out[i].start + 0.05 }
        }
        return out
    }
}
```

- [ ] **Step 2: 跑测试** Run: `swift test --filter SentenceTimingAligner`　Expected: 全 PASS。
- [ ] **Step 3: 若失败**：用 superpowers:systematic-debugging，修 aligner（不是删测试），直到绿。
- [ ] **Step 4: commit** `feat(core): SentenceTimingAligner + tests`

---

## Phase 2 · 数据模型（additive，编译验证）

### Task 2.1: SegmentDub 加 captionLines

**Files:** Modify `MixCut/Models/SegmentDub.swift`；改前 `cp ~/Library/Application\ Support/MixCut/MixCut.store{,.bak}`（Schema 变更铁律）。

- [ ] **Step 1: 加字段 + 计算属性**（放 `participatesInCombination` 之后）

```swift
import MixCutCore   // 顶部若未 import

// 在 @Model 内新增：
var captionLinesData: Data?    // [CaptionLine] JSON；nil = 尚未对齐

// 计算属性（与 keywords 同款）：
extension SegmentDub {
    var captionLines: [CaptionLine] {
        get {
            guard let d = captionLinesData else { return [] }
            return (try? JSONDecoder().decode([CaptionLine].self, from: d)) ?? []
        }
        set { captionLinesData = try? JSONEncoder().encode(newValue) }
    }
}
```

- [ ] **Step 2: 编译** `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build`　Expected: BUILD SUCCEEDED。
- [ ] **Step 3: 重启 app 冒烟**（数据库能开、库/变体正常显示）。
- [ ] **Step 4: commit** `feat(model): SegmentDub.captionLines`

---

## Phase 3 · (重)生成配音后自动对齐（写库，可观测）

### Task 3.1: DubbingViewModel.alignCaptions

**Files:** Modify `MixCut/ViewModels/DubbingViewModel.swift`（生成配音落库处，约 `:421-435`；及 updateVariantText 重配音落库处）。参考 spec §4。

- [ ] **Step 1: 加统一对齐入口**

```swift
/// 对某条已生成配音的 dub 做逐句对齐，写回 captionLines。失败静默走比例兜底，绝不阻断配音成功。
func alignCaptions(for dub: SegmentDub, context: ModelContext) async {
    guard let audio = dub.audioFilePath, FileManager.default.fileExists(atPath: audio) else { return }
    let segDur = dub.segment?.duration ?? 0
    guard segDur > 0, !dub.rewrittenText.isEmpty else { return }
    var words: [AlignWord] = []
    var audioDur = dub.audioDuration
    do {
        let r = try await asrService.transcribe(videoPath: audio)   // 内部 ffmpeg 抽音频→whisper（含 --no-gpu 回退）
        words = r.words.map { AlignWord(text: $0.word, start: $0.start, end: $0.end) }
        if r.duration > 0 { audioDur = r.duration }
    } catch {
        // 静默：走无 words 的比例兜底
        MixLog.info("逐句对齐 ASR 失败，走比例兜底: \(error.localizedDescription)")
    }
    let lines = SentenceTimingAligner.align(text: dub.rewrittenText, words: words,
                                            audioDuration: audioDur, segmentDuration: segDur)
    await MainActor.run {
        dub.captionLines = lines
        try? context.save()
    }
}
```

（`asrService` 若 VM 里没有则注入一个 `ASRService()`；注意 ASRService 是 actor，`transcribe` 用 await。）

- [ ] **Step 2: 在两条配音落库路径后调用**：`generateAudio` 里 `dub.audioFilePath = …; try? context.save()` 之后 `await alignCaptions(for: dub, context: context)`；`updateVariantText` 重配音成功后同样调用。
- [ ] **Step 3: 编译 + 重启**。
- [ ] **Step 4: 自测（观测 captionLines 已写）**：给一个分镜生成配音 → 加一句临时 `MixLog.info("captionLines=\(dub.captionLines)")` 或在检视栏临时打印，确认每句 + 时间被算出且 ≤ 分镜时长。确认后移除临时打印。
- [ ] **Step 5: commit** `feat(dub): 配音生成后自动逐句对齐`

---

## Phase 4 · 逐句时间编辑器（UI，截图自测）

### Task 4.1: CaptionTimingEditorSheet

**Files:** Create `MixCut/Views/SegmentLibrary/CaptionTimingEditorSheet.swift`

要点（照 spec §5 + 项目铁律）：独立 sheet；列出 `dub.captionLines`，**文本只读**；每行 起/止 可 −/＋(±0.1s 或 ±1帧) 或数字框；点行 → 用 `AVAudioPlayer` 放该 dub 音频 `[start,end]`（**不要用 RangeVideoPlayer**，纯音频会黑屏）；「重新自动对齐」按钮（二次确认，调 `dubVM.alignCaptions`）；即时写库；`.task(id: dub.id)` 顶层加载。校验 起<止、不重叠、clamp [0,分镜时长]。

- [ ] **Step 1: 写 sheet**（完整 SwiftUI，遵循 SegmentVariantInspector 的样式与写库模式）。
- [ ] **Step 2: 编译**。
- [ ] **Step 3: 自测**：编译错误用 everything-claude-code:build-error-resolver。

### Task 4.2: 变体卡加入口

**Files:** Modify `MixCut/Views/SegmentLibrary/SegmentVariantInspector.swift`（`versionCard`/`generatedControls` 区，仅"已生成配音"时显示）。

- [ ] **Step 1: 加一个"逐句字幕"小按钮**（`.sheet(item:)` 弹 CaptionTimingEditorSheet；用一个 `@State editingCaptionDub: SegmentDub?`）。
- [ ] **Step 2: 编译 + 重启 + 截图**：选带配音的变体 → 点入口 → 弹窗列出每句 + 时间；改一句时间即时写库、重开保持；点句能听到对应音频段。用 cliclick+screencapture 自测（窗口 `open -a` 两次拿 AX 窗口）。
- [ ] **Step 3: 回归**：变体生成/试听/重生成/删除、参与组合勾选、切分镜联动 不坏。
- [ ] **Step 4: commit** `feat(ui): 逐句字幕时间编辑器`

---

## Phase 5 · 逐句烧录（导出流水线，最敏感，最后做）

> ⚠️ 这块碰 ffmpeg filter_complex + 遮挡三模式 + 首帧不黑 + 输入序号。**每小步编译 + 真导出一条变体成片肉眼看**，出问题立即回退本 Phase。先备份心态：Phase 1-4 已独立可用，即使 Phase 5 回退也不丢前面价值。

### Task 5.1: DubSegmentSpec 换字段

**Files:** Modify `MixCut/Services/Export/DubExportService.swift`（`DubSegmentSpec.captionText: String` → `captionLines: [CaptionLine]`）、`VariantBatchExportService.swift`。

- [ ] **Step 1:** `captionText: String` → `captionLines: [CaptionLine]`；三处构造点（DubExportService 方案组合导出 `:61-70`、VariantBatchExportService `:70`、exportSingleSegment）改为从选定 dub 取 `dub.captionLines`；非变体/无配音路径填 `[]`。
- [ ] **Step 2: 编译**（此时烧录逻辑还没改，先让类型过——渲染处临时用 `captionLines.map(\.text).joined(" ")` 当整段占位，保证行为暂时等价、可编译可导出）。
- [ ] **Step 3: 真导出一条 + 肉眼看**：字幕仍整段（占位），但导出不崩、遮挡/首帧正常。
- [ ] **Step 4: commit** `refactor(export): captionText→captionLines（占位等价）`

### Task 5.2: 多 PNG 渲染 + 输入序号重排 + enable

**Files:** Modify `MixCut/Services/Export/DubExportService.swift`（`:228-270` 渲染/输入区）、`Sources/MixCutCore/DubSegmentGraph.swift`（`build` 签名 + filter）。

- [ ] **Step 1: 渲染多张 PNG**：对每条 `CaptionLine` `stripPunctuation(text)` → `CaptionRenderer.renderToFile`，收集 `[(inputIndex, origin, start, end)]`。**统一各句画布高度/落位 y**（防竖直跳，spec §6.3）。
- [ ] **Step 2: 输入序号重排**：先 push 全部 caption PNG（input 1..N），再 push dub、bgm，`dubAudioInputIndex/bgmInputIndex = N + 偏移`（不再假设 caption=1、dub=count）。设行数上限（≤20，超则合并相邻短句）。
- [ ] **Step 3: DubSegmentGraphBuilder.build**：单 caption → `captions: [(inputIndex,origin,start,end)]`，filter 里每条 `overlay=x:y:enable='between(t,start,end)'` 串联（t=分镜内 0 起，已由 trim/setpts 保证）。
- [ ] **Step 4: 编译 + 真导出一条变体 + 肉眼逐帧看**：字幕**逐句出现**、去标点、每句卡在被说的时间窗；遮挡三模式（.blur/.solid/.dim）各导一条确认底正常（句间空窗露底无字属预期）；**首帧不黑**；多变体组合导出各取各自 captionLines。
- [ ] **Step 5: 回归全跑**：导出串行（只 1 个 ffmpeg 在跑）、参与组合、单/批量分镜导出、方案组合导出 都正常。
- [ ] **Step 6: DMG 前不做**；`swift test`（MixCutCore 全绿）+ 关键路径人工验收清单（spec §9）走一遍。
- [ ] **Step 7: commit** `feat(export): 逐句字幕烧录（多 overlay + enable=between）`

---

## 收尾
- [ ] `swift test`（MixCutCore）全绿；app 编译 + 全回归清单（spec §9 人工验收 1-5）过。
- [ ] 更新 `docs/优化日志.md` 记一笔。
- [ ] 交用户验收后再决定 commit/发版（本项目铁律：不自动发）。
