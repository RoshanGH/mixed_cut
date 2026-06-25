# 变体感知的分镜库批量导出（含 BGM 混音）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 分镜素材库多选导出时，对每个选中分镜导出「1 个原版 + 每个已生成配音变体一个」，变体视频 = 原画面 + 克隆配音与原 BGM 切片混音 + 烧录新字幕（遮挡旧字幕）。

**Architecture:** 纯逻辑层（MixCutCore）负责「任务展开+命名」和「BGM 滤镜图」并单测；App 层把 `DubExportService` 的单片渲染暴露为按分镜可调用并补 BGM 输入，新增一个编排服务把展开后的任务路由到「流复制原版 / dub 渲染变体」，最后接进 `BatchExportSheet`。

**Tech Stack:** Swift 6 / SwiftUI / SwiftData / MixCutCore(SPM 纯逻辑，`swift test`) / 内置 FFmpeg。

## Global Constraints

- 视频统一 9:16 竖屏；变体渲染沿用 `DubExportService` 已有的 9:16 标准化与 `h264_videotoolbox` 固定参数，不改。
- BGM 增益常量默认 `0.6`（人声经 loudnorm 为主、BGM 垫底）。
- 文件命名：原版 `{编号}_{视频名}.mp4`；变体 `{编号}_{视频名}_{字母}.mp4`，字母由 `textVariantIndex` 映射（0→A、1→B…）。同名冲突用 `(1)(2)` 去重。
- 只导出 `audioFilePath != nil`（已生成音频）的变体；锁定原声（`isVoiceLocked`）分镜只导原版。
- `bgm.wav` 缺失时变体回退为纯克隆人声音轨，不报错。
- `DubSegmentGraphBuilder.build` 改动必须向后兼容：`bgmInputIndex == nil` 时输出与现状逐字节一致（MixScheme 方案导出不受影响）。
- API Key 仅运行时经 `KeychainHelper.getAPIKey(for:)` 读取，禁止硬编码（本计划不涉及网络，但守此线）。
- **Git：本计划执行期间不自动 `git add/commit/push`、不发版。** 每个任务末尾只做「编译/测试通过」检查；全部完成、用户验证后再由用户决定提交。计划内不含 commit 步骤。
- MixCutCore 新增 `.swift` 文件除了被 `swift test` 自动发现外，还必须注册进 `MixCut.xcodeproj/project.pbxproj`（4 处）App 才能编译；App 层新增文件注册 3 处。注册方法见 Task 1 / Task 5 步骤。

---

## File Structure

- `Sources/MixCutCore/SegmentExportExpander.swift`（新）— 纯逻辑：选中分镜 → 导出任务列表 + 命名。
- `Tests/MixCutCoreTests/SegmentExportExpanderTests.swift`（新）— 展开/命名单测。
- `Sources/MixCutCore/DubSegmentGraph.swift`（改）— 音频段增加可选 BGM 混音。
- `Tests/MixCutCoreTests/DubSegmentGraphTests.swift`（改）— 增 BGM 用例 + 回归保护。
- `MixCut/Services/Export/DubExportService.swift`（改）— `DubSegmentSpec` 加 `bgmAudioPath`；`renderSegment` 接 BGM 输入；新增公开 `exportSingleSegment`。
- `MixCut/Services/Export/VariantBatchExportService.swift`（新）— 编排：@MainActor 解析任务 + actor 执行（路由原版/变体）+ 命名去重。
- `MixCut/Views/SegmentLibrary/BatchExportSheet.swift`（改）— 改用新编排，显示含变体的文件总数与列表。

---

### Task 1: SegmentExportExpander（纯逻辑任务展开 + 命名）

**Files:**
- Create: `Sources/MixCutCore/SegmentExportExpander.swift`
- Test: `Tests/MixCutCoreTests/SegmentExportExpanderTests.swift`
- Modify: `MixCut.xcodeproj/project.pbxproj`（注册新核心文件，4 处）

**Interfaces:**
- Produces:
  - `SegmentExportExpander.expand(_ sources: [SegmentExportSource]) -> [SegmentExportPlanItem]`
  - `SegmentExportExpander.letter(for index: Int) -> String`
  - `struct SegmentExportSource { let segmentKey: String; let sequenceNumber: Int; let videoName: String; let isVoiceLocked: Bool; let variants: [VariantRef] }`
  - `struct VariantRef { let dubKey: String; let textVariantIndex: Int }`
  - `struct SegmentExportPlanItem { let segmentKey: String; let dubKey: String?; let fileName: String }`（`dubKey == nil` ⇒ 原版）

- [ ] **Step 1：写失败测试**

创建 `Tests/MixCutCoreTests/SegmentExportExpanderTests.swift`：

```swift
import Testing
@testable import MixCutCore

@Suite("SegmentExportExpander")
struct SegmentExportExpanderTests {

    @Test("非锁定分镜：1 原版 + 2 变体，命名正确")
    func nonLockedWithTwoVariants() {
        let src = SegmentExportSource(
            segmentKey: "seg1", sequenceNumber: 2, videoName: "clip", isVoiceLocked: false,
            variants: [VariantRef(dubKey: "a", textVariantIndex: 0),
                       VariantRef(dubKey: "b", textVariantIndex: 1)])
        let out = SegmentExportExpander.expand([src])
        #expect(out.count == 3)
        #expect(out[0].dubKey == nil)
        #expect(out[0].fileName == "2_clip.mp4")
        #expect(out[1].dubKey == "a")
        #expect(out[1].fileName == "2_clip_A.mp4")
        #expect(out[2].dubKey == "b")
        #expect(out[2].fileName == "2_clip_B.mp4")
    }

    @Test("锁定原声分镜：只产原版，忽略变体")
    func lockedProducesOnlyOriginal() {
        let src = SegmentExportSource(
            segmentKey: "s", sequenceNumber: 1, videoName: "v", isVoiceLocked: true,
            variants: [VariantRef(dubKey: "a", textVariantIndex: 0)])
        let out = SegmentExportExpander.expand([src])
        #expect(out.count == 1)
        #expect(out[0].dubKey == nil)
        #expect(out[0].fileName == "1_v.mp4")
    }

    @Test("变体乱序输入按 textVariantIndex 升序产出 A/B")
    func variantsSortedByIndex() {
        let src = SegmentExportSource(
            segmentKey: "s", sequenceNumber: 3, videoName: "v", isVoiceLocked: false,
            variants: [VariantRef(dubKey: "second", textVariantIndex: 1),
                       VariantRef(dubKey: "first", textVariantIndex: 0)])
        let out = SegmentExportExpander.expand([src])
        #expect(out.map(\.fileName) == ["3_v.mp4", "3_v_A.mp4", "3_v_B.mp4"])
        #expect(out[1].dubKey == "first")
        #expect(out[2].dubKey == "second")
    }

    @Test("无变体分镜只产原版")
    func noVariants() {
        let src = SegmentExportSource(
            segmentKey: "s", sequenceNumber: 5, videoName: "v", isVoiceLocked: false, variants: [])
        #expect(SegmentExportExpander.expand([src]).count == 1)
    }

    @Test("字母映射")
    func letterMapping() {
        #expect(SegmentExportExpander.letter(for: 0) == "A")
        #expect(SegmentExportExpander.letter(for: 2) == "C")
        #expect(SegmentExportExpander.letter(for: 26) == "V26")  // 越界回退
    }
}
```

- [ ] **Step 2：跑测试确认失败**

Run: `swift test --filter SegmentExportExpander`
Expected: 编译失败 / `cannot find 'SegmentExportExpander' in scope`。

- [ ] **Step 3：写实现**

创建 `Sources/MixCutCore/SegmentExportExpander.swift`：

```swift
import Foundation

/// 一个已生成音频的配音变体引用（纯值类型）。
public struct VariantRef: Equatable, Sendable {
    public let dubKey: String
    public let textVariantIndex: Int
    public init(dubKey: String, textVariantIndex: Int) {
        self.dubKey = dubKey
        self.textVariantIndex = textVariantIndex
    }
}

/// 一个选中分镜的导出来源描述（纯值类型，App 层从 Segment 构造）。
public struct SegmentExportSource: Equatable, Sendable {
    public let segmentKey: String
    public let sequenceNumber: Int
    public let videoName: String      // 不含扩展名
    public let isVoiceLocked: Bool
    public let variants: [VariantRef] // 仅含已生成音频的变体
    public init(segmentKey: String, sequenceNumber: Int, videoName: String,
                isVoiceLocked: Bool, variants: [VariantRef]) {
        self.segmentKey = segmentKey
        self.sequenceNumber = sequenceNumber
        self.videoName = videoName
        self.isVoiceLocked = isVoiceLocked
        self.variants = variants
    }
}

/// 展开后的单个导出任务（dubKey == nil 表示原版）。
public struct SegmentExportPlanItem: Equatable, Sendable {
    public let segmentKey: String
    public let dubKey: String?
    public let fileName: String
    public init(segmentKey: String, dubKey: String?, fileName: String) {
        self.segmentKey = segmentKey
        self.dubKey = dubKey
        self.fileName = fileName
    }
}

/// 把选中分镜展开成「1 原版 + N 变体」的导出任务列表并命名。
public enum SegmentExportExpander {

    public static func expand(_ sources: [SegmentExportSource]) -> [SegmentExportPlanItem] {
        var out: [SegmentExportPlanItem] = []
        for s in sources {
            out.append(SegmentExportPlanItem(
                segmentKey: s.segmentKey, dubKey: nil,
                fileName: "\(s.sequenceNumber)_\(s.videoName).mp4"))
            guard !s.isVoiceLocked else { continue }
            for v in s.variants.sorted(by: { $0.textVariantIndex < $1.textVariantIndex }) {
                let letter = letter(for: v.textVariantIndex)
                out.append(SegmentExportPlanItem(
                    segmentKey: s.segmentKey, dubKey: v.dubKey,
                    fileName: "\(s.sequenceNumber)_\(s.videoName)_\(letter).mp4"))
            }
        }
        return out
    }

    /// textVariantIndex → 字母（0→A）；越界回退 "V{index}"。
    public static func letter(for index: Int) -> String {
        guard index >= 0, index < 26,
              let scalar = UnicodeScalar(UnicodeScalar("A").value + UInt32(index)) else {
            return "V\(index)"
        }
        return String(scalar)
    }
}
```

- [ ] **Step 4：跑测试确认通过**

Run: `swift test --filter SegmentExportExpander`
Expected: 5 个测试全部 PASS。

- [ ] **Step 5：注册到 pbxproj（App 编译用）**

查现有核心文件的 4 处登记作模板：

Run: `grep -n "SpeechRatePlanner.swift" MixCut.xcodeproj/project.pbxproj`
Expected: 4 行（PBXBuildFile / PBXFileReference / 组 children / Sources 构建阶段）。

用 `uuidgen | tr -dc 'A-F0-9' | cut -c1-24` 生成两个新 24 位十六进制 ID（一个给 buildFile、一个给 fileRef），仿照 `SpeechRatePlanner.swift` 的 4 行，把文件名换成 `SegmentExportExpander.swift`、`path = Sources/MixCutCore/SegmentExportExpander.swift`，分别插入对应 4 处。

- [ ] **Step 6：确认 App 仍可编译**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`。

---

### Task 2: DubSegmentGraphBuilder 增加可选 BGM 混音

**Files:**
- Modify: `Sources/MixCutCore/DubSegmentGraph.swift`
- Test: `Tests/MixCutCoreTests/DubSegmentGraphTests.swift`

**Interfaces:**
- Consumes: 无（纯逻辑）。
- Produces: `DubSegmentGraphBuilder.build(...)` 新增末位可选参数 `bgmInputIndex: Int? = nil`；新增 `public static let bgmGain: Double = 0.6`。`nil` 时输出与现状一致。

- [ ] **Step 1：写失败测试**

在 `Tests/MixCutCoreTests/DubSegmentGraphTests.swift` 末尾追加（不删原有用例）：

```swift
@Suite("DubSegmentGraph BGM 混音")
struct DubSegmentGraphBGMTests {

    @Test("提供 bgmInputIndex 时音轨为 voice+bgm amix")
    func mixesBGMWhenIndexProvided() {
        let g = DubSegmentGraphBuilder.build(
            mode: .none, startFrame: 30, endFrame: 90, fps: 30,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 0, width: 0, height: 0),
            captionOrigin: nil, captionInputIndex: 1,
            keepOriginalAudio: false, dubAudioInputIndex: 1,
            freezePadFrames: 0, trailingSilence: 0,
            bgmInputIndex: 2)
        let fc = g.filterComplex
        #expect(fc.contains("[1:a]aresample=44100"))          // 人声链
        #expect(fc.contains("[2:a]atrim=start=1.00000:end=3.00000"))  // BGM 切片 30/30~90/30
        #expect(fc.contains("volume=0.60"))
        #expect(fc.contains("amix=inputs=2:duration=first:normalize=0[aout]"))
    }

    @Test("bgmInputIndex 为 nil 时退化为纯人声（回归保护）")
    func noBGMFallsBackToVoiceOnly() {
        let g = DubSegmentGraphBuilder.build(
            mode: .none, startFrame: 30, endFrame: 90, fps: 30,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 0, width: 0, height: 0),
            captionOrigin: nil, captionInputIndex: 1,
            keepOriginalAudio: false, dubAudioInputIndex: 1,
            freezePadFrames: 0, trailingSilence: 0)
        let fc = g.filterComplex
        #expect(!fc.contains("amix"))
        #expect(fc.contains("[1:a]aresample=44100,loudnorm=I=-16:TP=-1.5:LRA=11[aout]"))
    }

    @Test("带 trailingSilence + BGM：人声有 apad 再与 BGM 混")
    func bgmWithTrailingSilence() {
        let g = DubSegmentGraphBuilder.build(
            mode: .none, startFrame: 0, endFrame: 60, fps: 30,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 0, width: 0, height: 0),
            captionOrigin: nil, captionInputIndex: 1,
            keepOriginalAudio: false, dubAudioInputIndex: 1,
            freezePadFrames: 0, trailingSilence: 0.5,
            bgmInputIndex: 2)
        let fc = g.filterComplex
        #expect(fc.contains("apad=pad_dur=0.500"))
        #expect(fc.contains("amix=inputs=2:duration=first:normalize=0[aout]"))
    }
}
```

- [ ] **Step 2：跑测试确认失败**

Run: `swift test --filter "DubSegmentGraph BGM"`
Expected: 编译失败（`build` 无 `bgmInputIndex` 参数）。

- [ ] **Step 3：写实现**

在 `Sources/MixCutCore/DubSegmentGraph.swift` 的 `DubSegmentGraphBuilder` 内，`loudnorm`/`silenceEpsilon` 旁加常量：

```swift
    /// 混音时 BGM 相对音量（人声为主、BGM 垫底）
    public static let bgmGain: Double = 0.6
```

把 `build` 的签名末位追加参数（其余参数不变）：

```swift
        freezePadFrames: Int,
        trailingSilence: Double,
        bgmInputIndex: Int? = nil
    ) -> DubSegmentGraph {
```

把「5) 音频 → [aout]」整段替换为：

```swift
        // 5) 音频 → [aout]
        if keepOriginalAudio {
            let aStart = Double(startFrame) / fps
            let aEnd = Double(endFrame) / fps
            parts.append(
                "[0:a]atrim=start=\(String(format: "%.5f", aStart)):end=\(String(format: "%.5f", aEnd))," +
                "asetpts=PTS-STARTPTS,aresample=44100[aout]"
            )
        } else {
            let padSuffix = trailingSilence > silenceEpsilon
                ? ",apad=pad_dur=\(String(format: "%.3f", trailingSilence))"
                : ""
            if let bgmIdx = bgmInputIndex {
                let aStart = Double(startFrame) / fps
                let aEnd = Double(endFrame) / fps
                parts.append("[\(dubAudioInputIndex):a]aresample=44100,\(loudnorm)\(padSuffix)[voice]")
                parts.append(
                    "[\(bgmIdx):a]atrim=start=\(String(format: "%.5f", aStart)):end=\(String(format: "%.5f", aEnd))," +
                    "asetpts=PTS-STARTPTS,aresample=44100,volume=\(String(format: "%.2f", Self.bgmGain))[bgmcut]"
                )
                parts.append("[voice][bgmcut]amix=inputs=2:duration=first:normalize=0[aout]")
            } else {
                parts.append("[\(dubAudioInputIndex):a]aresample=44100,\(loudnorm)\(padSuffix)[aout]")
            }
        }
```

> 说明：`nil` 分支用 `padSuffix` 拼出的字符串与原「两分支」逐字节相同（有 `apad` / 无 `apad`），回归测试守此。

- [ ] **Step 4：跑测试确认通过**

Run: `swift test --filter "DubSegmentGraph"`
Expected: 新增 3 个 + 原有用例全部 PASS。

---

### Task 3: DubExportService 单片渲染 + BGM 输入

**Files:**
- Modify: `MixCut/Services/Export/DubExportService.swift`

**Interfaces:**
- Consumes: `DubSegmentGraphBuilder.build(..., bgmInputIndex:)`（Task 2）。
- Produces:
  - `DubSegmentSpec` 末位新增字段 `let bgmAudioPath: String?`。
  - `DubExportService.exportSingleSegment(spec: DubSegmentSpec, videoWidth: Int, videoHeight: Int, outputPath: String, config: ExportConfig) async throws`。

- [ ] **Step 1：给 `DubSegmentSpec` 加 `bgmAudioPath` 字段**

在 `struct DubSegmentSpec` 末位（`trailingSilence` 之后）加：

```swift
    let trailingSilence: Double
    let bgmAudioPath: String?      // 配音镜头的 BGM 源（整轨 bgm.wav）；nil = 不混 BGM
```

- [ ] **Step 2：更新 `DubExportInput.from` 内 3 处 `DubSegmentSpec(...)` 构造**

该方法里有 3 处构造（锁定/回退两处 + 配音一处），各在末位补 `bgmAudioPath: nil`（MixScheme 方案导出暂不混 BGM，属本计划范围外）。例如配音那处：

```swift
                specs.append(DubSegmentSpec(
                    videoPath: video.localPath, startFrame: segment.startFrame, endFrame: segment.endFrame,
                    fps: fps, captionText: caption, hasHardSubtitle: segment.hasHardSubtitle, maskStyleRaw: segment.maskStyleRaw,
                    maskRect: segment.maskRect, isVoiceLocked: false, dubAudioPath: audioPath,
                    freezePadFrames: dub.freezePadFrames, trailingSilence: dub.trailingSilence,
                    bgmAudioPath: nil))
```

锁定段与回退段两处同样在末位加 `bgmAudioPath: nil`。

- [ ] **Step 3：改 `renderSegment` 的输入装配与索引计算**

把 `renderSegment` 里「字幕 PNG … dub 音轨」那段（变量 `captionOrigin`/`captionInputIndex`/`dubAudioInputIndex`/`extraInputs`/`keepOriginalAudio` 到调用 `DubSegmentGraphBuilder.build` 之前）替换为以下基于追加顺序的索引计算（input 0 = 源视频，extraInputs 依次为 input 1..N）：

```swift
        let maskPixel = PixelRect.from(spec.maskRect, outputWidth: outW, outputHeight: outH)

        var captionOrigin: (x: Int, y: Int)? = nil
        var captionInputIndex = 1
        var dubAudioInputIndex = 1
        var bgmInputIndex: Int? = nil
        var extraInputs: [String] = []

        let keepOriginalAudio = spec.isVoiceLocked || spec.dubAudioPath == nil

        if !spec.isVoiceLocked, !spec.captionText.isEmpty {
            let canvasW = max(2, Int(Double(outW) * 0.9))
            let withBackdrop = (mode != .solid)
            let pngURL = workDir.appendingPathComponent(String(format: "cap_%03d.png", index))
            let img = try CaptionRenderer.renderToFile(
                text: spec.captionText, canvasWidth: canvasW, withBackdrop: withBackdrop, to: pngURL)
            captionOrigin = CaptionLayout.overlayOrigin(
                outputWidth: outW, outputHeight: outH, maskRect: spec.maskRect,
                captionWidth: img.pixelWidth, captionHeight: img.pixelHeight)
            extraInputs.append(pngURL.path)
            captionInputIndex = extraInputs.count   // 1-based：与 ffmpeg 输入序号一致
        }

        if !keepOriginalAudio, let dubPath = spec.dubAudioPath {
            extraInputs.append(dubPath)
            dubAudioInputIndex = extraInputs.count
            if let bgmPath = spec.bgmAudioPath, FileManager.default.fileExists(atPath: bgmPath) {
                extraInputs.append(bgmPath)
                bgmInputIndex = extraInputs.count
            }
        }

        let graph = DubSegmentGraphBuilder.build(
            mode: mode,
            startFrame: spec.startFrame, endFrame: spec.endFrame, fps: spec.fps,
            outputWidth: outW, outputHeight: outH,
            maskPixel: maskPixel,
            captionOrigin: captionOrigin,
            captionInputIndex: captionInputIndex,
            keepOriginalAudio: keepOriginalAudio,
            dubAudioInputIndex: dubAudioInputIndex,
            freezePadFrames: spec.freezePadFrames,
            trailingSilence: spec.trailingSilence,
            bgmInputIndex: bgmInputIndex)
```

> 注意：原 `renderSegment` 顶部已有 `let mode = ...` 与 `let maskPixel = ...`；替换时把重复的 `maskPixel` 行去掉一处，确保 `mode`/`maskPixel` 各只定义一次。其余（`var args = ["-y","-i",spec.videoPath]`、追加 `extraInputs`、编码参数、`ffmpeg.run`）保持不变。

- [ ] **Step 4：新增公开 `exportSingleSegment`**

在 `DubExportService` 内（`export(...)` 方法之后）添加：

```swift
    /// 渲染单个分镜为独立 mp4（分镜库变体导出用）。
    /// 分辨率按本片自身宽高与 config 计算，不与其他片拼接。
    func exportSingleSegment(
        spec: DubSegmentSpec,
        videoWidth: Int,
        videoHeight: Int,
        outputPath: String,
        config: ExportConfig = ExportConfig()
    ) async throws {
        let (outW, outH) = Self.resolution(config: config, maxWidth: videoWidth, maxHeight: videoHeight)
        let workDir = FileHelper.tempDirectory.appendingPathComponent("dubseg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        try await renderSegment(spec: spec, index: 0, outW: outW, outH: outH,
                                workDir: workDir, config: config, outputPath: outputPath)
    }
```

- [ ] **Step 5：编译确认**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`。

---

### Task 4: VariantBatchExportService（编排：解析任务 + 路由执行）

**Files:**
- Create: `MixCut/Services/Export/VariantBatchExportService.swift`
- Modify: `MixCut.xcodeproj/project.pbxproj`（注册新 App 文件，3 处）

**Interfaces:**
- Consumes: `SegmentExportExpander.expand`（Task 1）、`DubExportService.exportSingleSegment`（Task 3）、`FFmpegRunner.cutSegment`、`FileHelper.stemsDirectory(videoHash:)`。
- Produces:
  - `enum VariantExportJob: Sendable { case original(...); case variant(...) }`
  - `struct VariantExportProgress: Sendable { let total: Int; let completed: Int; let currentName: String?; let failed: [(String, String)] }`
  - `VariantExportInput.from(segments:numberProvider:) -> [VariantExportJob]`（`@MainActor`）
  - `VariantBatchExportService.exportAll(jobs:outputDirectory:config:onProgress:) async -> (succeeded: Int, failed: [(String, String)])`

- [ ] **Step 1：创建文件与值类型 + @MainActor 解析**

创建 `MixCut/Services/Export/VariantBatchExportService.swift`：

```swift
import Foundation

/// 单个导出任务（值类型，可跨 actor 传递）。
enum VariantExportJob: Sendable {
    /// 原版：流复制切片。
    case original(sourcePath: String, startTime: Double, endTime: Double, fps: Double, fileName: String)
    /// 变体：dub 渲染（含 BGM）。
    case variant(spec: DubSegmentSpec, videoWidth: Int, videoHeight: Int, fileName: String)

    var fileName: String {
        switch self {
        case let .original(_, _, _, _, name): return name
        case let .variant(_, _, _, name): return name
        }
    }
}

/// 导出进度（纯值，不耦合 SwiftData）。
struct VariantExportProgress: Sendable {
    let total: Int
    let completed: Int
    let currentName: String?
    let failed: [(String, String)]   // (文件名, 错误)
    var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
}

/// 从选中分镜解析出导出任务（@MainActor：读 SwiftData）。
enum VariantExportInput {
    @MainActor
    static func from(segments: [Segment], numberProvider: (Segment) -> Int) -> [VariantExportJob] {
        // 1) 构造展开来源（仅含已生成音频的变体）
        var segByKey: [String: Segment] = [:]
        var dubByKey: [String: SegmentDub] = [:]
        var sources: [SegmentExportSource] = []

        for seg in segments {
            guard let video = seg.video else { continue }
            let key = seg.id.uuidString
            segByKey[key] = seg
            let stem = (video.name as NSString).deletingPathExtension
            let variants: [VariantRef] = seg.segmentDubs
                .filter { $0.audioFilePath != nil }
                .map { dub in
                    dubByKey[dub.id.uuidString] = dub
                    return VariantRef(dubKey: dub.id.uuidString, textVariantIndex: dub.textVariantIndex)
                }
            sources.append(SegmentExportSource(
                segmentKey: key, sequenceNumber: numberProvider(seg),
                videoName: stem, isVoiceLocked: seg.isVoiceLocked, variants: variants))
        }

        // 2) 展开
        let items = SegmentExportExpander.expand(sources)

        // 3) 解析成可执行任务
        var jobs: [VariantExportJob] = []
        for item in items {
            guard let seg = segByKey[item.segmentKey], let video = seg.video else { continue }
            let fps = video.fps > 0 ? video.fps : 30
            if let dubKey = item.dubKey, let dub = dubByKey[dubKey],
               let audioPath = dub.audioFilePath {
                // BGM 切片源（整轨 bgm.wav），不存在则 nil
                let bgmPath: String? = {
                    guard let hash = video.contentHash, !hash.isEmpty else { return nil }
                    let p = FileHelper.stemsDirectory(videoHash: hash).appendingPathComponent("bgm.wav").path
                    return FileManager.default.fileExists(atPath: p) ? p : nil
                }()
                let caption = dub.rewrittenText.isEmpty ? seg.text : dub.rewrittenText
                let spec = DubSegmentSpec(
                    videoPath: video.localPath, startFrame: seg.startFrame, endFrame: seg.endFrame,
                    fps: fps, captionText: caption, hasHardSubtitle: seg.hasHardSubtitle,
                    maskStyleRaw: seg.maskStyleRaw, maskRect: seg.maskRect, isVoiceLocked: false,
                    dubAudioPath: audioPath, freezePadFrames: dub.freezePadFrames,
                    trailingSilence: dub.trailingSilence, bgmAudioPath: bgmPath)
                jobs.append(.variant(spec: spec, videoWidth: video.width, videoHeight: video.height,
                                     fileName: item.fileName))
            } else {
                jobs.append(.original(sourcePath: video.localPath, startTime: seg.startTime,
                                      endTime: seg.endTime, fps: fps, fileName: item.fileName))
            }
        }
        return jobs
    }
}
```

- [ ] **Step 2：实现执行 actor（路由 + 命名去重 + 进度）**

在同文件追加：

```swift
/// 变体感知批量导出：原版走流复制，变体走 dub 渲染。
actor VariantBatchExportService {
    private let ffmpeg: FFmpegRunner
    private let dubExport: DubExportService

    init(ffmpeg: FFmpegRunner = FFmpegRunner(), dubExport: DubExportService = DubExportService()) {
        self.ffmpeg = ffmpeg
        self.dubExport = dubExport
    }

    func exportAll(
        jobs: [VariantExportJob],
        outputDirectory: URL,
        config: ExportConfig = ExportConfig(),
        onProgress: @Sendable @MainActor (VariantExportProgress) -> Void
    ) async -> (succeeded: Int, failed: [(String, String)]) {
        var succeeded = 0
        var failed: [(String, String)] = []
        var usedNames: Set<String> = []
        let total = jobs.count

        for (idx, job) in jobs.enumerated() {
            await onProgress(VariantExportProgress(total: total, completed: idx,
                                                   currentName: job.fileName, failed: failed))
            let outURL = Self.uniqueDestination(directory: outputDirectory,
                                                preferredName: job.fileName, usedInBatch: &usedNames)
            do {
                switch job {
                case let .original(sourcePath, startTime, endTime, fps, _):
                    try await ffmpeg.cutSegment(from: sourcePath, start: startTime, end: endTime,
                                                fps: fps, to: outURL.path)
                case let .variant(spec, w, h, _):
                    try await dubExport.exportSingleSegment(spec: spec, videoWidth: w, videoHeight: h,
                                                            outputPath: outURL.path, config: config)
                }
                succeeded += 1
            } catch {
                failed.append((job.fileName, error.localizedDescription))
                MixLog.error("变体导出失败 \(job.fileName): \(error)")
            }
            if Task.isCancelled { break }
        }

        await onProgress(VariantExportProgress(total: total, completed: succeeded + failed.count,
                                               currentName: nil, failed: failed))
        return (succeeded, failed)
    }

    /// 同名冲突 → 加 (1)(2)（与 BatchSegmentExportService 同策略）。
    private static func uniqueDestination(directory: URL, preferredName: String,
                                          usedInBatch: inout Set<String>) -> URL {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool {
            usedInBatch.contains(name) || fm.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
        var candidate = preferredName
        if !exists(candidate) { usedInBatch.insert(candidate); return directory.appendingPathComponent(candidate) }
        let url = URL(fileURLWithPath: preferredName)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 1
        while exists(candidate) {
            candidate = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            counter += 1
            if counter > 9999 { break }
        }
        usedInBatch.insert(candidate)
        return directory.appendingPathComponent(candidate)
    }
}
```

- [ ] **Step 3：注册到 pbxproj（App 文件，3 处）**

查 App 文件模板：

Run: `grep -n "BatchSegmentExportService.swift" MixCut.xcodeproj/project.pbxproj`
Expected: 3 行（PBXBuildFile / PBXFileReference / 组 children；App 文件不在 SPM Sources 阶段单列，但在 app target 的 Sources 阶段）。实际以 grep 结果为准，仿照其登记行用新 24 位 ID 加 `VariantBatchExportService.swift`、`path = VariantBatchExportService.swift`。

> 若 grep 出 4 行，按 4 处办；以现有同目录文件的真实登记数为准。

- [ ] **Step 4：编译确认**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`。

---

### Task 5: 接入 BatchExportSheet（UI）

**Files:**
- Modify: `MixCut/Views/SegmentLibrary/BatchExportSheet.swift`

**Interfaces:**
- Consumes: `VariantExportInput.from`、`VariantBatchExportService`、`VariantExportProgress`（Task 4）。

- [ ] **Step 1：把数据源从 `[BatchExportItem]` 换成 `[VariantExportJob]`**

`BatchExportSheet` 顶部把服务与计算属性替换：

```swift
    private let exportService = VariantBatchExportService()

    private var jobs: [VariantExportJob] {
        VariantExportInput.from(segments: segments, numberProvider: numberProvider)
    }
```

删除原 `private var items: [BatchExportItem] { ... }` 计算属性与 `private let exportService = BatchSegmentExportService()`。

- [ ] **Step 2：把所有 `items` 引用改为 `jobs`，进度类型改 `VariantExportProgress`**

逐处替换（编译器会逐个报错指引）：
- 标题：`"批量导出 \(jobs.count) 个分镜"` 改为含变体的总数文案：
  ```swift
  Text(didFinish ? "导出完成" : isExporting ? "导出中" : "批量导出 \(jobs.count) 个文件（含配音变体）")
  ```
- `@State private var progress: SegmentBatchExportProgress?` → `@State private var progress: VariantExportProgress?`
- 文件列表预览：`ForEach(items)` → 用文件名列表。把列表段替换为：
  ```swift
  Text("文件列表（\(jobs.count) 个）")
  ...
  ForEach(Array(jobs.enumerated()), id: \.offset) { _, job in
      HStack(spacing: 6) {
          Image(systemName: "film").font(.system(size: 9)).foregroundStyle(.tertiary)
          Text(job.fileName)
              .font(.system(size: 11, design: .monospaced))
              .lineLimit(1).truncationMode(.middle)
          Spacer()
      }
      .padding(.horizontal, 6).padding(.vertical, 3)
  }
  ```
  （移除原先按 `item.duration` 显示时长那两处——`VariantExportJob` 不携带时长；总时长那行一并删除。）
- 进度视图 `progressView(_ p:)` 形参类型改 `VariantExportProgress`；内部：
  - `p.completedCount` → `p.completed`，`p.totalCount` → `p.total`，`p.totalProgress` → `p.fraction`
  - `if let current = p.currentItem` → `if let name = p.currentName`，里面 `current.fileName` → `name`，删除「切片中 X 秒」那行（无时长）。
  - `p.failedItems` → `p.failed`
- 结果视图 `resultView`：
  - 兜底构造改为 `VariantExportProgress(total: jobs.count, completed: jobs.count, currentName: nil, failed: [])`
  - `p.totalCount` → `p.total`，`p.failedItems` → `p.failed`
  - 失败列表 `ForEach(Array(p.failed.enumerated()), id: \.offset) { _, pair in ... pair.0 (文件名) ... pair.1 (错误) ... }`
- 底部按钮 `disabled(outputDirectory == nil || items.isEmpty)` → `jobs.isEmpty`。

- [ ] **Step 3：改 `startExport()` 调用新服务**

```swift
    private func startExport() {
        guard let dir = outputDirectory else { return }
        isExporting = true
        let jobsCopy = jobs
        progress = VariantExportProgress(total: jobsCopy.count, completed: 0,
                                         currentName: jobsCopy.first?.fileName, failed: [])
        exportTask = Task {
            let result = await exportService.exportAll(
                jobs: jobsCopy,
                outputDirectory: dir,
                onProgress: { @MainActor p in self.progress = p }
            )
            await MainActor.run {
                self.progress = VariantExportProgress(
                    total: jobsCopy.count, completed: result.succeeded + result.failed.count,
                    currentName: nil, failed: result.failed)
                self.isExporting = false
                self.didFinish = true
                if result.failed.isEmpty {
                    ToastCenter.shared.show("已导出 \(result.succeeded) 个文件", icon: "checkmark.seal.fill", style: .success)
                } else {
                    ToastCenter.shared.show("导出 \(result.succeeded) 成功 / \(result.failed.count) 失败", icon: "exclamationmark.triangle.fill", style: .warning)
                }
            }
        }
    }
```

- [ ] **Step 4：编译确认**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 5：编译成功后按项目规则重启 App + 打包 DMG**

```bash
DD=/Users/menggang/Library/Developer/Xcode/DerivedData/MixCut-byytuggmhodpumcmwnwrtzwkmavr
pkill -x MixCut; sleep 1; open "$DD/Build/Products/Debug/MixCut.app"
```

- [ ] **Step 6：人工验证（必须，逐项过）**

1. 一键改写台词跑出 A/B 变体的某分镜，在分镜库勾选它 → 批量导出。
2. 弹窗文件列表应显示 3 个：`{编号}_{名}.mp4` / `_A.mp4` / `_B.mp4`。
3. 导出后用 QuickTime 播放三个文件：
   - 原版：原声、原字幕、原画面。
   - A/B：克隆配音 + **能听到背景音乐**（不是纯人声）、新字幕已烧录、旧硬字幕被遮挡（按该分镜遮挡样式）。
4. 勾一个「保留原声」分镜一起导 → 它只产 1 个原版文件。
5. 多选多个分镜混合导出 → 数量、命名、A/B 对应正确，无同名覆盖。
6. 截图导出弹窗与一个变体播放画面留档。

---

## Self-Review

**Spec 覆盖：**
- 1+N 展开/命名/锁定只原版/未生成跳过 → Task 1（展开）+ Task 4（仅取 `audioFilePath != nil` 变体）。✓
- 变体 = 原画面+克隆配音+BGM+烧字幕遮挡 → Task 2（BGM 图）+ Task 3（单片渲染接 BGM）+ Task 4（spec 装配）。✓
- `bgm.wav` 缺失回退纯人声 → Task 3（`renderSegment` 文件存在判断）+ Task 4（bgmPath nil）+ Task 2（nil 分支）。✓
- 命名去重 → Task 4 `uniqueDestination`。✓
- UI 显示含变体总数 → Task 5。✓
- 向后兼容（方案导出不受影响）→ Task 2 `bgmInputIndex = nil` 默认 + 回归测试；Task 3 `DubExportInput.from` 传 `bgmAudioPath: nil`。✓

**占位符扫描：** 无 TBD/TODO，所有改动步骤含完整代码。✓

**类型一致性：** `SegmentExportSource/VariantRef/SegmentExportPlanItem`（Task1）→ Task4 使用字段一致；`bgmInputIndex`（Task2）↔ `renderSegment` 调用（Task3）一致；`VariantExportJob/VariantExportProgress/VariantExportInput.from`（Task4）↔ `BatchExportSheet`（Task5）一致；`DubSegmentSpec.bgmAudioPath`（Task3）↔ Task4 装配一致。✓

**遗留/范围外（spec 已声明）：** 自动识别明星镜头、克隆参考音跳过明星段、方案导出 BGM、BGM 自适应增益——均不在本计划。
