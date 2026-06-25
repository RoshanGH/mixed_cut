# 配音「裂变」编排（P5）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在分镜素材库内把配音全链路接通到「能选音色、能改写台词、能按需生成配音、能在方案里挑变体、能导出配音版」,实现每分镜「K 改写台词 × 3 音色」裂变变体池 + 组合引擎按音色模式消费。

**Architecture:** 退役旧「整片版本 `DubVariant`」,改为「每分镜变体池」(`Segment` 1──* `SegmentDub`,每个 `SegmentDub` = 一个 分镜×改写版×音色)。UI 全在 `SegmentLibraryView`(顶部「配音设置」栏 + 右侧「变体池」检视栏)。台词改写预生成文本,TTS 音频按需合成。组合引擎(`SchemeViewModel.createSchemeSegments`)按「统一/混用」给每槽选定变体,导出复用 P4 引擎(只改输入构建)。复用 P2 改写、P3 配音对齐、P4 导出、`DubStaleness` 失效追踪。

**Tech Stack:** Swift 5.10 / SwiftUI / SwiftData;MixCutCore 纯逻辑库(`swift test`);千问 DashScope TTS;内置 ffmpeg。

## Global Constraints

- **schema 变更前必须先备份 `MixCut.store`**(CLAUDE.md 铁律,无 VersionedSchema)。备份命令见 Task 1。因目前无任何真实配音数据,备份后可直接重构。
- **视频/缩略图严格 9:16 竖屏**。
- **MixCutCore 纯逻辑、无 SwiftData/AppKit-UI 依赖**;新增 Core 文件须在 `MixCut.xcodeproj/project.pbxproj` 登记进 App target(4 处,模式见 Task 2);新增 App 文件登记 3–4 处(模式 = `DubAudioFinalizer.swift`)。Core 与 App **同模块编译,无 `import MixCutCore`**。
- **不可变优先**;`let` 优先;值类型 `Sendable`;SwiftData 读写在 `@MainActor`;共享可变状态用 actor。
- **AI 提供商仅千问/MiniMax/Claude**;TTS 复用 Settings 里已配的千问 key(`KeychainHelper.getAPIKey(for: .qwen)`),无需新增 key UI。
- **明星锁定段(`Segment.isVoiceLocked`)**:原声原画原字幕,不裂变、不遮挡、不叠字幕、导出时原声**不做 loudnorm**(P4 已实现)。
- **K（每分镜改写版本数）固定 = 2**,本期不做可配。
- **TTS 按需**:改写只预生成文本;音频仅在 试听/格生成/导出补齐 时合成。
- **不破坏现有功能**:分镜库多选/批量导出/批量删除/`Equatable` 性能优化/双击编辑台词/切项目联动(`.task(id:)`);普通导出走原 `ExportService` 不动;方案生成现有流程不回归。
- **每次编译后**按 CLAUDE.md:`xcodebuild ... Debug build` 成功后 `pkill -x MixCut; sleep 1; open <DerivedData>/Build/Products/Debug/MixCut.app`(由执行者在 UI 任务末尾做)。DerivedData:`/Users/menggang/Library/Developer/Xcode/DerivedData/MixCut-byytuggmhodpumcmwnwrtzwkmavr/`。

---

## 文件结构

**MixCutCore(纯逻辑 + `swift test`,登记进 App target)**
- `Sources/MixCutCore/VariantSelector.swift` — 组合引擎逐槽变体分配(统一/混用,确定性轮换)

**Models(修改 / 删除)**
- 删除 `MixCut/Models/DubVariant.swift`
- 改 `MixCut/Models/SegmentDub.swift`(变体池单元)
- 改 `MixCut/Models/DubEnums.swift`(去 `DubVariantStatus`,加 `VoiceMode`)
- 改 `MixCut/Models/Segment.swift`(加 `segmentDubs` 反向关系)
- 改 `MixCut/Models/Video.swift`(加 `selectedVoiceIds`)
- 改 `MixCut/Models/MixScheme.swift`(加 `voiceModeRaw`/`unifiedVoiceId`)
- 改 `MixCut/Models/SchemeSegment.swift`(加 `selectedSegmentDubId`)
- 改 `MixCut/App/MixCutApp.swift`(schema 去 `DubVariant.self`)

**Services(修改)**
- 改 `MixCut/Utilities/FileHelper.swift`(`dubAudioURL` 带 voiceId+textVariantIndex)
- 改 `MixCut/Services/TTS/DubAudioFinalizer.swift`(`finalize` 参数随之改)
- 改 `MixCut/Services/Export/DubExportService.swift`(`from(scheme:)` 读 `selectedSegmentDubId` + 导出前补齐音频)

**ViewModels(新增 / 修改)**
- 新增 `MixCut/ViewModels/DubbingViewModel.swift` — 选音色 + 一键改写(建池)+ 按需 TTS + 试听
- 改 `MixCut/ViewModels/SchemeViewModel.swift`(`createSchemeSegments` 注入变体分配 + 传 voiceMode)

**Views(新增 / 修改)**
- 新增 `MixCut/Views/SegmentLibrary/DubSettingsBar.swift` — 顶部配音设置栏(选 3 音色 + 一键改写 + 试听)
- 新增 `MixCut/Views/SegmentLibrary/SegmentVariantInspector.swift` — 右侧变体池矩阵
- 改 `MixCut/Views/SegmentLibrary/SegmentLibraryView.swift`(挂顶栏 + 右侧检视栏)
- 改 `MixCut/Views/Schemes/SchemeDetailView.swift`(`StoryboardCard` 加变体标 + ▶ + 换变体)+ 方案生成「音色模式」入口
- 改 `MixCut/Views/Export/ExportView.swift`(配音版导出入口,可选)

---

## 任务依赖与可测性

Task 1（模型重构,保持可编译）→ Task 2（VariantSelector 纯逻辑,`swift test`)→ Task 3（FileHelper/Finalizer 路径）→ Task 4（DubbingViewModel）→ Task 5/6（两个 UI)→ Task 7（方案生成接变体）→ Task 8（方案页变体标）→ Task 9（导出补齐 + 入口）。纯逻辑(Task 2)走 TDD;模型/服务/VM/UI 以「`xcodebuild` 编译通过 + `swift test` 不回归 + 人工跑」验收(App 代码无 xcodeproj 测试 target)。

---

### Task 1: 模型重构 —— 退役 DubVariant,SegmentDub 改变体池,新增字段(保持全程可编译)

**Files:**
- Backup: `MixCut.store`
- Delete: `MixCut/Models/DubVariant.swift`
- Modify: `MixCut/Models/SegmentDub.swift`、`MixCut/Models/DubEnums.swift`、`MixCut/Models/Segment.swift`、`MixCut/Models/Video.swift`、`MixCut/Models/MixScheme.swift`、`MixCut/Models/SchemeSegment.swift`、`MixCut/App/MixCutApp.swift`、`MixCut/Services/Export/DubExportService.swift`、`MixCut.xcodeproj/project.pbxproj`(从 Sources 移除 DubVariant.swift 引用)

**Interfaces:**
- Produces:
  - `SegmentDub`(变体池单元):字段见下;`init(segment:voiceId:voiceProvider:textVariantIndex:rewrittenText:)`
  - `Segment.segmentDubs: [SegmentDub]`
  - `Video.selectedVoiceIds: [String]`(get/set,JSON 编解码)
  - `MixScheme.voiceMode: VoiceMode`、`MixScheme.unifiedVoiceId: String?`
  - `SchemeSegment.selectedSegmentDubId: UUID?`
  - `enum VoiceMode: String { case unified, mixed }`
  - `DubExportInput.from(scheme: MixScheme) -> DubExportInput?`(去掉 variant 形参)

- [ ] **Step 1: 备份数据库**

Run:
```bash
cp ~/Library/Application\ Support/MixCut.store ~/Library/Application\ Support/MixCut.store.p5bak 2>/dev/null; \
cp ~/Library/Application\ Support/default.store ~/Library/Application\ Support/default.store.p5bak 2>/dev/null; \
ls -la ~/Library/Application\ Support/*.p5bak 2>/dev/null || echo "no store yet (fresh app) — OK"
```
Expected: 打印备份文件,或「no store yet」(都可继续)。

- [ ] **Step 2: 删除 DubVariant.swift 并从 pbxproj 移除其引用**

删除文件:
```bash
rm MixCut/Models/DubVariant.swift
```
在 `MixCut.xcodeproj/project.pbxproj` 删除 `DubVariant.swift` 的两行(PBXBuildFile 行 + PBXFileReference 行 + 它在 group children 与 Sources build phase 的两行,共 4 处)。用 `grep -n "DubVariant.swift" MixCut.xcodeproj/project.pbxproj` 找到所有行后逐行删除。删后 `grep -c "DubVariant.swift" MixCut.xcodeproj/project.pbxproj` 应为 `0`。

- [ ] **Step 3: 改 DubEnums.swift —— 去 DubVariantStatus,加 VoiceMode**

把 `MixCut/Models/DubEnums.swift` 中的 `DubVariantStatus` 枚举整段删除(它只被已删除的 DubVariant 使用),保留 `SegmentDubStatus` 与 `MaskStyle`,并新增:
```swift
/// 方案的音色一致性模式
enum VoiceMode: String, Codable, CaseIterable {
    case unified   // 整片统一音色（从选定音色里指定一个）
    case mixed     // 片内混用（各槽位可不同音色）
}
```

- [ ] **Step 4: 改 SegmentDub.swift —— 变体池单元**

整文件替换为:
```swift
// MixCut/Models/SegmentDub.swift
import Foundation
import SwiftData

/// 某分镜的一个配音变体（= 分镜 × 改写版 × 音色）。一个 Segment 挂多个 = 变体池。
@Model
final class SegmentDub {
    @Attribute(.unique) var id: UUID
    var segment: Segment?
    var voiceId: String = ""
    var voiceProvider: String = "qwen"
    var textVariantIndex: Int = 0          // 第几个改写版（0..K-1）
    var rewrittenText: String = ""         // 同 textVariantIndex 的各音色行共享同文本
    var audioFilePath: String?             // 按需生成；初始 nil
    var audioDuration: Double = 0
    var atempoFactor: Double = 1.0
    var freezePadFrames: Int = 0
    var trailingSilence: Double = 0

    // 失效追踪（DubStaleness 生成那一刻快照）
    var generatedForStartFrame: Int = -1
    var generatedForEndFrame: Int = -1
    var generatedForTextHash: String = ""

    var statusRaw: String = "pending"      // SegmentDubStatus.rawValue

    var status: SegmentDubStatus {
        get { SegmentDubStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    init(segment: Segment?, voiceId: String, voiceProvider: String = "qwen",
         textVariantIndex: Int, rewrittenText: String = "") {
        self.id = UUID()
        self.segment = segment
        self.voiceId = voiceId
        self.voiceProvider = voiceProvider
        self.textVariantIndex = textVariantIndex
        self.rewrittenText = rewrittenText
    }
}
```

- [ ] **Step 5: 改 Segment.swift —— 加变体池反向关系**

在 `MixCut/Models/Segment.swift` 的 `schemeSegments` 关系声明之后,加:
```swift
@Relationship(deleteRule: .cascade, inverse: \SegmentDub.segment)
var segmentDubs: [SegmentDub] = []
```

- [ ] **Step 6: 改 Video.swift —— 选定音色**

在 `MixCut/Models/Video.swift` 的 `asrSentencesData` 附近加存储字段:
```swift
var selectedVoiceIdsData: Data?   // [String] 选定音色（≤3），JSON
```
并在 `asrSentences` 计算属性附近加:
```swift
/// 选定的 TTS 音色 id（≤3）
var selectedVoiceIds: [String] {
    get {
        guard let data = selectedVoiceIdsData else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
    set {
        selectedVoiceIdsData = try? JSONEncoder().encode(newValue)
    }
}
```

- [ ] **Step 7: 改 MixScheme.swift —— 音色模式**

在 `MixCut/Models/MixScheme.swift` 的存储字段区加:
```swift
var voiceModeRaw: String = "unified"   // VoiceMode.rawValue
var unifiedVoiceId: String?            // 统一模式选的音色（混用时 nil）
```
并加计算属性:
```swift
var voiceMode: VoiceMode {
    get { VoiceMode(rawValue: voiceModeRaw) ?? .unified }
    set { voiceModeRaw = newValue.rawValue }
}
```

- [ ] **Step 8: 改 SchemeSegment.swift —— 选定变体**

在 `MixCut/Models/SchemeSegment.swift` 存储字段区加:
```swift
var selectedSegmentDubId: UUID?   // 该槽选定的 SegmentDub.id；nil = 原声/锁定
```

- [ ] **Step 9: 改 MixCutApp.swift —— schema 去 DubVariant.self**

在 `MixCut/App/MixCutApp.swift` 找到 `DubVariant.self` 出现的两处(schema 注册 + reset 类型列表),删除这两个 `DubVariant.self,`(保留 `SegmentDub.self`)。

- [ ] **Step 10: 改 DubExportService.swift —— from(scheme:) 读 selectedSegmentDubId**

把 `MixCut/Services/Export/DubExportService.swift` 里的 `DubExportInput.from(scheme:variant:)` 整个方法替换为(签名去掉 variant,改为读 scheme 每槽 selectedSegmentDubId;其余 spec 构建与回退逻辑保持 P4 既有语义):
```swift
@MainActor
static func from(scheme: MixScheme) -> DubExportInput? {
    let ordered = scheme.orderedSegments
    guard !ordered.isEmpty else { return nil }

    var specs: [DubSegmentSpec] = []
    var maxW = 0, maxH = 0
    for schemeSeg in ordered {
        guard let segment = schemeSeg.segment,
              let video = segment.video,
              FileManager.default.fileExists(atPath: video.localPath) else { continue }

        let fps = video.fps > 0 ? video.fps : 30
        maxW = max(maxW, video.width)
        maxH = max(maxH, video.height)

        // 该槽选定的变体（nil 或找不到 → 原声）
        let chosen: SegmentDub? = schemeSeg.selectedSegmentDubId.flatMap { dubId in
            segment.segmentDubs.first { $0.id == dubId }
        }

        if segment.isVoiceLocked || chosen == nil {
            // 锁定段 / 未选变体 → 保留原声原字幕
            specs.append(DubSegmentSpec(
                videoPath: video.localPath, startFrame: segment.startFrame, endFrame: segment.endFrame,
                fps: fps, captionText: segment.text, hasHardSubtitle: false, maskStyleRaw: segment.maskStyleRaw,
                maskRect: segment.maskRect, isVoiceLocked: true, dubAudioPath: nil,
                freezePadFrames: 0, trailingSilence: 0))
        } else if let dub = chosen,
                  let audioPath = dub.audioFilePath,
                  FileManager.default.fileExists(atPath: audioPath) {
            let caption = dub.rewrittenText.isEmpty ? segment.text : dub.rewrittenText
            specs.append(DubSegmentSpec(
                videoPath: video.localPath, startFrame: segment.startFrame, endFrame: segment.endFrame,
                fps: fps, captionText: caption, hasHardSubtitle: segment.hasHardSubtitle, maskStyleRaw: segment.maskStyleRaw,
                maskRect: segment.maskRect, isVoiceLocked: false, dubAudioPath: audioPath,
                freezePadFrames: dub.freezePadFrames, trailingSilence: dub.trailingSilence))
        } else {
            // 选了变体但音频还没生成 → 回退原声（Task 9 会在导出前补齐音频再调用本方法）
            MixLog.info("分镜 \(segment.segmentIndex) 选定变体无音频，暂回退原声")
            specs.append(DubSegmentSpec(
                videoPath: video.localPath, startFrame: segment.startFrame, endFrame: segment.endFrame,
                fps: fps, captionText: segment.text, hasHardSubtitle: false, maskStyleRaw: segment.maskStyleRaw,
                maskRect: segment.maskRect, isVoiceLocked: true, dubAudioPath: nil,
                freezePadFrames: 0, trailingSilence: 0))
        }
    }
    guard !specs.isEmpty else { return nil }
    return DubExportInput(segments: specs, maxWidth: maxW, maxHeight: maxH)
}
```

- [ ] **Step 11: 编译验证**

Run:
```bash
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -6
```
Expected: `** BUILD SUCCEEDED **`(如报「找不到 DubVariant」,说明还有引用未清,按报错文件清掉)。
Run: `grep -rc "DubVariant" MixCut/ | grep -v ':0' || echo "no DubVariant refs"`
Expected: `no DubVariant refs`

- [ ] **Step 12: 提交**

```bash
git add -A
git commit -m "refactor(dubbing): P5 退役DubVariant,SegmentDub改每分镜变体池+方案/视频新增字段"
```

---

### Task 2: VariantSelector(MixCutCore 纯逻辑,逐槽变体分配)

**Files:**
- Create: `Sources/MixCutCore/VariantSelector.swift`
- Test: `Tests/MixCutCoreTests/VariantSelectorTests.swift`
- Modify: `MixCut.xcodeproj/project.pbxproj`(登记 Core 文件)

**pbxproj 登记规则(Core 文件,4 处,照抄 AlignmentPlan.swift 模式)**:
1. `PBXBuildFile`:`<BUILDID> /* X.swift in Sources */ = {isa = PBXBuildFile; fileRef = <REFID> /* X.swift */; };`
2. `PBXFileReference`:`<REFID> /* X.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; name = X.swift; path = Sources/MixCutCore/X.swift; sourceTree = "<group>"; };`
3. MixCutCore 的 PBXGroup children 加 `<REFID> /* X.swift */,`
4. App target PBXSourcesBuildPhase 加 `<BUILDID> /* X.swift in Sources */,`
用 `uuidgen | tr -dc 'A-F0-9' | cut -c1-24` 生成两个唯一 24-hex ID。

**Interfaces:**
- Produces:
  - `struct DubOption: Equatable, Sendable { let id: UUID; let voiceId: String; let textVariantIndex: Int }`
  - `struct SlotInput: Equatable, Sendable { let isVoiceLocked: Bool; let options: [DubOption] }`
  - `enum VariantSelectorMode: Equatable, Sendable { case unified(voiceId: String); case mixed }`
  - `enum VariantSelector { static func assign(slots: [SlotInput], mode: VariantSelectorMode, variationSeed: Int) -> [UUID?] }`
- 规则:锁定段或无候选 → `nil`;`unified` 只在 `voiceId == 指定` 的候选里挑;`mixed` 全部候选;用 `variationSeed` 做确定性轮换 `候选[(variationSeed + slotIndex) % 候选数]`,保证同 seed 同结果、不同 seed 多样。

- [ ] **Step 1: 写失败测试**

```swift
import Testing
@testable import MixCutCore

@Suite("VariantSelector")
struct VariantSelectorTests {
    private func opt(_ v: String, _ t: Int) -> DubOption { DubOption(id: UUID(), voiceId: v, textVariantIndex: t) }

    @Test("锁定段 → nil")
    func lockedIsNil() {
        let slots = [SlotInput(isVoiceLocked: true, options: [opt("Cherry", 0)])]
        #expect(VariantSelector.assign(slots: slots, mode: .mixed, variationSeed: 0) == [nil])
    }

    @Test("无候选 → nil")
    func emptyOptionsIsNil() {
        let slots = [SlotInput(isVoiceLocked: false, options: [])]
        #expect(VariantSelector.assign(slots: slots, mode: .mixed, variationSeed: 0) == [nil])
    }

    @Test("unified 只选指定音色的候选")
    func unifiedFiltersVoice() {
        let cherry = opt("Cherry", 0), ethan = opt("Ethan", 0)
        let slots = [SlotInput(isVoiceLocked: false, options: [cherry, ethan])]
        let picked = VariantSelector.assign(slots: slots, mode: .unified(voiceId: "Ethan"), variationSeed: 0)
        #expect(picked == [ethan.id])
    }

    @Test("unified 指定音色无候选 → nil（回退原声）")
    func unifiedMissingVoiceIsNil() {
        let slots = [SlotInput(isVoiceLocked: false, options: [opt("Cherry", 0)])]
        let picked = VariantSelector.assign(slots: slots, mode: .unified(voiceId: "Moon"), variationSeed: 0)
        #expect(picked == [nil])
    }

    @Test("mixed 用 seed 确定性轮换")
    func mixedRotatesBySeed() {
        let a = opt("Cherry", 0), b = opt("Ethan", 1)
        let slots = [SlotInput(isVoiceLocked: false, options: [a, b])]
        #expect(VariantSelector.assign(slots: slots, mode: .mixed, variationSeed: 0) == [a.id])
        #expect(VariantSelector.assign(slots: slots, mode: .mixed, variationSeed: 1) == [b.id])
    }

    @Test("逐槽位移确定性")
    func perSlotOffset() {
        let a = opt("Cherry", 0), b = opt("Cherry", 1)
        let slots = [
            SlotInput(isVoiceLocked: false, options: [a, b]),
            SlotInput(isVoiceLocked: false, options: [a, b])
        ]
        let picked = VariantSelector.assign(slots: slots, mode: .mixed, variationSeed: 0)
        #expect(picked == [a.id, b.id])   // slot0:(0+0)%2=0→a; slot1:(0+1)%2=1→b
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter VariantSelectorTests`
Expected: 编译失败 `cannot find 'VariantSelector' in scope`

- [ ] **Step 3: 写实现**

```swift
import Foundation

/// 一个可被组合引擎选中的配音变体候选。
public struct DubOption: Equatable, Sendable {
    public let id: UUID
    public let voiceId: String
    public let textVariantIndex: Int
    public init(id: UUID, voiceId: String, textVariantIndex: Int) {
        self.id = id; self.voiceId = voiceId; self.textVariantIndex = textVariantIndex
    }
}

/// 一个时间线槽位（对应一个 SchemeSegment）。
public struct SlotInput: Equatable, Sendable {
    public let isVoiceLocked: Bool
    public let options: [DubOption]
    public init(isVoiceLocked: Bool, options: [DubOption]) {
        self.isVoiceLocked = isVoiceLocked; self.options = options
    }
}

/// 音色分配模式。
public enum VariantSelectorMode: Equatable, Sendable {
    case unified(voiceId: String)
    case mixed
}

/// 组合引擎逐槽变体分配（纯函数）。
public enum VariantSelector {
    /// 为每个槽位选定一个变体 id（锁定段/无候选 → nil）。
    /// 用 variationSeed 做确定性轮换：同 seed 同结果、不同 seed 多样。
    public static func assign(slots: [SlotInput], mode: VariantSelectorMode, variationSeed: Int) -> [UUID?] {
        slots.enumerated().map { index, slot in
            guard !slot.isVoiceLocked else { return nil }
            let candidates: [DubOption]
            switch mode {
            case .unified(let voiceId):
                candidates = slot.options.filter { $0.voiceId == voiceId }
            case .mixed:
                candidates = slot.options
            }
            guard !candidates.isEmpty else { return nil }
            let pick = ((variationSeed + index) % candidates.count + candidates.count) % candidates.count
            return candidates[pick].id
        }
    }
}
```

- [ ] **Step 4: 登记 pbxproj + 跑测试通过**

Run: `swift test --filter VariantSelectorTests`
Expected: PASS（6 tests）
Run: `grep -c "VariantSelector.swift" MixCut.xcodeproj/project.pbxproj`
Expected: `4`

- [ ] **Step 5: 提交**

```bash
git add Sources/MixCutCore/VariantSelector.swift Tests/MixCutCoreTests/VariantSelectorTests.swift MixCut.xcodeproj/project.pbxproj
git commit -m "feat(dubbing): P5 VariantSelector 逐槽变体分配（统一/混用）"
```

---

### Task 3: FileHelper.dubAudioURL + DubAudioFinalizer 按 (voiceId, textVariantIndex) 落盘

**Files:**
- Modify: `MixCut/Utilities/FileHelper.swift`、`MixCut/Services/TTS/DubAudioFinalizer.swift`

**Interfaces:**
- Produces:
  - `FileHelper.dubAudioURL(videoHash: String, segmentId: UUID, voiceId: String, textVariantIndex: Int) -> URL`
  - `DubAudioFinalizer.finalize(tts: TTSResult, targetDuration: Double, fps: Double, videoHash: String, segmentId: UUID, voiceId: String, textVariantIndex: Int) async throws -> FinalizedDub`

- [ ] **Step 1: 改 FileHelper.dubAudioURL**

把 `MixCut/Utilities/FileHelper.swift` 的 `dubAudioURL(videoHash:variantIndex:segmentId:)` 整个替换为:
```swift
/// 配音音频路径：Dubs/{videoHash}/{segmentId}/{voiceId}-v{textVariantIndex}.m4a
static func dubAudioURL(videoHash: String, segmentId: UUID, voiceId: String, textVariantIndex: Int) -> URL {
    let dir = appSupportDirectory
        .appendingPathComponent("Dubs", isDirectory: true)
        .appendingPathComponent(videoHash, isDirectory: true)
        .appendingPathComponent(segmentId.uuidString, isDirectory: true)
    ensureDirectory(at: dir)
    return dir.appendingPathComponent("\(voiceId)-v\(textVariantIndex).m4a")
}
```
> 注:`appSupportDirectory`/`ensureDirectory` 是 FileHelper 既有成员;若旧实现用的是别的基目录变量名,沿用同一个(读旧 `dubAudioURL` 上下文确认)。

- [ ] **Step 2: 改 DubAudioFinalizer.finalize 参数**

把 `MixCut/Services/TTS/DubAudioFinalizer.swift` 的 `finalize(...)` 签名与 dest 计算替换为:
```swift
func finalize(tts: TTSResult,
              targetDuration: Double,
              fps: Double,
              videoHash: String,
              segmentId: UUID,
              voiceId: String,
              textVariantIndex: Int) async throws -> FinalizedDub {
    let plan = AudioAligner.plan(targetDuration: targetDuration,
                                 audioDuration: tts.rawDuration,
                                 fps: fps)

    let dest = FileHelper.dubAudioURL(videoHash: videoHash, segmentId: segmentId,
                                      voiceId: voiceId, textVariantIndex: textVariantIndex)
    try? FileManager.default.removeItem(at: dest)
    // ……（其余 atempo + 转 AAC 逻辑保持不变）……
    return FinalizedDub(m4aPath: dest.path, plan: plan)
}
```
(只改签名与 `dest` 这一行,中间 ffmpeg 拼参逻辑不动。)

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -4`
Expected: `** BUILD SUCCEEDED **`(此时 finalize 还没有新调用方,编译应通过;若旧有调用方报错,按新签名改它)。

- [ ] **Step 4: 提交**

```bash
git add MixCut/Utilities/FileHelper.swift MixCut/Services/TTS/DubAudioFinalizer.swift
git commit -m "feat(dubbing): P5 配音音频按 voiceId+改写版 落盘"
```

---

### Task 4: DubbingViewModel —— 选音色 + 一键改写(建池)+ 按需 TTS + 试听

**Files:**
- Create: `MixCut/ViewModels/DubbingViewModel.swift`
- Modify: `MixCut.xcodeproj/project.pbxproj`(登记 App 文件,3–4 处,模式 = DubAudioFinalizer.swift)

**Interfaces:**
- Consumes: `ScriptRewriteService.rewrite(inputs:style:charsPerSecond:onProgress:) -> [RewrittenSegment]`;`RewriteSegmentInput(segmentId:originalText:durationSeconds:keywords:)`;`QwenTTSClient().synthesize(text:voiceId:languageType:) -> TTSResult`;`DubAudioFinalizer().finalize(...)`;`DubStaleness.textHash(of:)`;`QwenVoiceCatalog.all`;`Segment`/`SegmentDub`/`Video`(SwiftData)
- Produces:
  - `@MainActor @Observable final class DubbingViewModel`
  - `let topVoices: [QwenVoice]`(前 10)
  - `func loadSelectedVoices(for video: Video)`
  - `func toggleVoice(_ voiceId: String, for video: Video, context: ModelContext)`(≤3)
  - `func rewriteAll(video: Video, context: ModelContext) async`
  - `func generateAudio(for dub: SegmentDub, context: ModelContext) async`
  - `func audition(voiceId: String) async`
  - `var isRewriting: Bool`、`var rewriteProgress: String`、`var busyDubIDs: Set<UUID>`、`var auditioningVoiceId: String?`、`var errorMessage: String?`
  - 常量 `static let textVariantCount = 2`

- [ ] **Step 1: 写实现**

```swift
import Foundation
import SwiftData
import AVFoundation

@MainActor
@Observable
final class DubbingViewModel {
    static let textVariantCount = 2

    /// 两个差异化改写风格（喂给 ScriptRewriteService 的 style 文本）
    private static let rewriteStyles = [
        "口语化、活泼带感叹词，适合年轻受众的信息流广告",
        "干练直接、强调卖点与行动号召，适合效果类信息流广告"
    ]
    private static let auditionText = "这款产品真的很好用，喜欢的话点击下方链接了解一下吧。"

    let topVoices: [QwenVoice] = Array(QwenVoiceCatalog.all.prefix(10))

    var isRewriting = false
    var rewriteProgress = ""
    var busyDubIDs: Set<UUID> = []
    var auditioningVoiceId: String?
    var errorMessage: String?

    private let rewriteService = ScriptRewriteService()
    private let tts = QwenTTSClient()
    private let finalizer = DubAudioFinalizer()
    private var auditionPlayer: AVAudioPlayer?

    // MARK: - 音色选择

    func toggleVoice(_ voiceId: String, for video: Video, context: ModelContext) {
        var ids = video.selectedVoiceIds
        if let idx = ids.firstIndex(of: voiceId) {
            ids.remove(at: idx)
        } else if ids.count < 3 {
            ids.append(voiceId)
        } else {
            return // 已满 3
        }
        video.selectedVoiceIds = ids
        try? context.save()
    }

    // MARK: - 一键改写（预生成 K 个文本变体 × 选定音色 建池）

    func rewriteAll(video: Video, context: ModelContext) async {
        let voices = video.selectedVoiceIds
        guard !voices.isEmpty else { errorMessage = "请先选择至少 1 个音色"; return }
        let reconfigurable = video.segments.filter { !$0.isVoiceLocked && !$0.text.isEmpty }
        guard !reconfigurable.isEmpty else { errorMessage = "没有可重配的分镜"; return }

        isRewriting = true
        defer { isRewriting = false }

        let inputs = reconfigurable.map {
            RewriteSegmentInput(segmentId: $0.id.uuidString,
                                originalText: $0.text,
                                durationSeconds: $0.duration,
                                keywords: $0.keywords)
        }
        let segById = Dictionary(uniqueKeysWithValues: reconfigurable.map { ($0.id.uuidString, $0) })

        for k in 0..<Self.textVariantCount {
            rewriteProgress = "改写第 \(k + 1)/\(Self.textVariantCount) 套…"
            do {
                let results = try await rewriteService.rewrite(
                    inputs: inputs,
                    style: Self.rewriteStyles[k % Self.rewriteStyles.count],
                    charsPerSecond: 5.0)
                for r in results {
                    guard let seg = segById[r.segmentId] else { continue }
                    for voiceId in voices {
                        upsertDub(segment: seg, voiceId: voiceId, textVariantIndex: k,
                                  text: r.rewrittenText, context: context)
                    }
                }
                try? context.save()
            } catch {
                errorMessage = "改写失败：\(error.localizedDescription)"
                return
            }
        }
        rewriteProgress = ""
    }

    /// 同 (分镜, 音色, 改写版) 已存在则更新文本（并因文本变更清空旧音频），否则新建。
    private func upsertDub(segment: Segment, voiceId: String, textVariantIndex: Int,
                           text: String, context: ModelContext) {
        if let existing = segment.segmentDubs.first(where: {
            $0.voiceId == voiceId && $0.textVariantIndex == textVariantIndex
        }) {
            if existing.rewrittenText != text {
                existing.rewrittenText = text
                existing.audioFilePath = nil
                existing.status = .pending
            }
        } else {
            let dub = SegmentDub(segment: segment, voiceId: voiceId,
                                 textVariantIndex: textVariantIndex, rewrittenText: text)
            context.insert(dub)
            segment.segmentDubs.append(dub)
        }
    }

    // MARK: - 按需生成单格音频

    func generateAudio(for dub: SegmentDub, context: ModelContext) async {
        guard let segment = dub.segment, let video = segment.video else { return }
        guard !dub.rewrittenText.isEmpty else { errorMessage = "该变体没有台词"; return }
        busyDubIDs.insert(dub.id)
        defer { busyDubIDs.remove(dub.id) }
        do {
            let result = try await tts.synthesize(text: dub.rewrittenText, voiceId: dub.voiceId, languageType: "Chinese")
            let finalized = try await finalizer.finalize(
                tts: result, targetDuration: segment.duration, fps: video.fps > 0 ? video.fps : 30,
                videoHash: video.contentHash ?? video.id.uuidString,
                segmentId: segment.id, voiceId: dub.voiceId, textVariantIndex: dub.textVariantIndex)
            dub.audioFilePath = finalized.m4aPath
            dub.atempoFactor = finalized.plan.atempoFactor
            dub.freezePadFrames = finalized.plan.freezePadFrames
            dub.trailingSilence = finalized.plan.trailingSilence
            dub.generatedForStartFrame = segment.startFrame
            dub.generatedForEndFrame = segment.endFrame
            dub.generatedForTextHash = DubStaleness.textHash(of: dub.rewrittenText)
            dub.status = .generated
            try? context.save()
        } catch {
            dub.status = .failed
            try? context.save()
            errorMessage = "配音生成失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 试听音色样例

    func audition(voiceId: String) async {
        auditioningVoiceId = voiceId
        defer { auditioningVoiceId = nil }
        do {
            let result = try await tts.synthesize(text: Self.auditionText, voiceId: voiceId, languageType: "Chinese")
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: result.wavPath))
            auditionPlayer = player
            player.play()
        } catch {
            errorMessage = "试听失败：\(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 2: 登记 pbxproj(App 文件)+ 编译**

把 `DubbingViewModel.swift` 登记进 pbxproj(PBXBuildFile + PBXFileReference `path = DubbingViewModel.swift` + ViewModels 分组 children + Sources build phase),用唯一 24-hex ID。
Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -6`
Expected: `** BUILD SUCCEEDED **`
Run: `grep -c "DubbingViewModel.swift" MixCut.xcodeproj/project.pbxproj`
Expected: `3` 或 `4`

- [ ] **Step 3: 提交**

```bash
git add MixCut/ViewModels/DubbingViewModel.swift MixCut.xcodeproj/project.pbxproj
git commit -m "feat(dubbing): P5 DubbingViewModel 选音色/一键改写建池/按需TTS/试听"
```

---

### Task 5: 顶部「配音设置」栏(DubSettingsBar)+ 挂进 SegmentLibraryView

**Files:**
- Create: `MixCut/Views/SegmentLibrary/DubSettingsBar.swift`
- Modify: `MixCut/Views/SegmentLibrary/SegmentLibraryView.swift`、`MixCut.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `DubbingViewModel`、`QwenVoice`、当前 `Video`(从分镜库当前分组取);`Video.selectedVoiceIds`
- Produces: `struct DubSettingsBar: View { init(video: Video, dubVM: DubbingViewModel) }`

**前置说明(给实现者)**:`SegmentLibraryView` 是按视频分组展示(`groupedSegments: [VideoSegmentGroup]`)。配音设置是**针对单个视频**的。本期取「当前可见分组里第一个视频」作为配音目标(若库里有多视频分组,顶栏加一个视频下拉切换;若只有一个分组直接用它)。实现者按现有 `groupedSegments` 结构取 `video`。

- [ ] **Step 1: 写 DubSettingsBar**

```swift
import SwiftUI

/// 分镜素材库顶部「配音设置」栏：选 ≤3 音色（可试听）+ 一键改写台词。
struct DubSettingsBar: View {
    let video: Video
    @Bindable var dubVM: DubbingViewModel
    @Environment(\.modelContext) private var modelContext
    @State private var expanded = true

    private var selected: [String] { video.selectedVoiceIds }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    Label("配音设置", systemImage: expanded ? "chevron.down" : "chevron.right")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                Text("已选 \(selected.count)/3")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if dubVM.isRewriting {
                    ProgressView().controlSize(.small)
                    Text(dubVM.rewriteProgress).font(.caption).foregroundStyle(.secondary)
                } else {
                    Button {
                        Task { await dubVM.rewriteAll(video: video, context: modelContext) }
                    } label: {
                        Label("一键改写台词", systemImage: "wand.and.stars")
                    }
                    .disabled(selected.isEmpty)
                    .help(selected.isEmpty ? "请先选择音色" : "为所有可重配分镜生成 \(DubbingViewModel.textVariantCount) 套改写台词")
                }
            }

            if expanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(dubVM.topVoices) { voice in
                            voiceCard(voice)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(10)
        .background(Color(.windowBackgroundColor).opacity(0.6))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.25), lineWidth: 1))
        .padding(.horizontal, 12).padding(.top, 8)
        .alert("配音", isPresented: Binding(get: { dubVM.errorMessage != nil },
                                          set: { if !$0 { dubVM.errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(dubVM.errorMessage ?? "") }
    }

    @ViewBuilder
    private func voiceCard(_ voice: QwenVoice) -> some View {
        let isSelected = selected.contains(voice.id)
        let isFull = selected.count >= 3 && !isSelected
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(voice.displayName).font(.caption.weight(.semibold))
                Spacer()
                if isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
            }
            Text(voice.summary).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(2).frame(height: 26, alignment: .top)
            Button {
                Task { await dubVM.audition(voiceId: voice.id) }
            } label: {
                if dubVM.auditioningVoiceId == voice.id {
                    ProgressView().controlSize(.mini)
                } else {
                    Label("试听", systemImage: "play.circle").font(.caption2)
                }
            }
            .buttonStyle(.borderless).controlSize(.mini)
        }
        .padding(8)
        .frame(width: 140, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color(.controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: isSelected ? 2 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .opacity(isFull ? 0.45 : 1)
        .onTapGesture {
            if !isFull { dubVM.toggleVoice(voice.id, for: video, context: modelContext) }
        }
    }
}
```

- [ ] **Step 2: 挂进 SegmentLibraryView**

在 `MixCut/Views/SegmentLibrary/SegmentLibraryView.swift`:
1. 加状态:`@State private var dubVM = DubbingViewModel()`。
2. 在 `mainContent` 的 `filterToolbar` 与其下方 `Divider()` 之间(约 line 50–51),插入(取当前分组首个视频):
```swift
if let video = viewModel.groupedSegments.first?.video {
    DubSettingsBar(video: video, dubVM: dubVM)
}
```
> `VideoSegmentGroup` 的视频属性名以实际为准(实现者读 `SegmentLibraryViewModel.groupedSegments` 元素结构确认,可能是 `.video`)。

- [ ] **Step 3: 登记 pbxproj + 编译 + 自测截图**

登记 `DubSettingsBar.swift`(App 文件,3–4 处)。
Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -6` → `** BUILD SUCCEEDED **`
重启应用:`pkill -x MixCut; sleep 1; open /Users/menggang/Library/Developer/Xcode/DerivedData/MixCut-byytuggmhodpumcmwnwrtzwkmavr/Build/Products/Debug/MixCut.app`
**人工**:进分镜素材库,确认顶部出现「配音设置」栏、10 个音色卡可横滑、可选最多 3、满 3 其余变灰、折叠/展开正常。截图留证。`grep -c "DubSettingsBar.swift" MixCut.xcodeproj/project.pbxproj` = 3/4。

- [ ] **Step 4: 提交**

```bash
git add MixCut/Views/SegmentLibrary/DubSettingsBar.swift MixCut/Views/SegmentLibrary/SegmentLibraryView.swift MixCut.xcodeproj/project.pbxproj
git commit -m "feat(dubbing): P5 顶部配音设置栏（选3音色+试听+一键改写）"
```

---

### Task 6: 右侧「变体池」检视栏(SegmentVariantInspector)+ 挂进 SegmentLibraryView

**Files:**
- Create: `MixCut/Views/SegmentLibrary/SegmentVariantInspector.swift`
- Modify: `MixCut/Views/SegmentLibrary/SegmentLibraryView.swift`、`MixCut.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `DubbingViewModel`、选中的 `Segment`、`Video.selectedVoiceIds`、`QwenVoiceCatalog`、`DubStaleness.check`/`DubSnapshot`/`textHash`
- Produces: `struct SegmentVariantInspector: View { init(segment: Segment, dubVM: DubbingViewModel) }`

- [ ] **Step 1: 写 SegmentVariantInspector**

```swift
import SwiftUI

/// 右侧变体池矩阵：行 = 改写版（0..K-1），列 = 选定音色，格 = 按需配音。
struct SegmentVariantInspector: View {
    let segment: Segment
    @Bindable var dubVM: DubbingViewModel
    @Environment(\.modelContext) private var modelContext

    private var voices: [String] { segment.video?.selectedVoiceIds ?? [] }
    private func voiceName(_ id: String) -> String {
        QwenVoiceCatalog.all.first { $0.id == id }?.displayName ?? id
    }
    private func dub(textVariant t: Int, voiceId v: String) -> SegmentDub? {
        segment.segmentDubs.first { $0.textVariantIndex == t && $0.voiceId == v }
    }
    private func isStale(_ dub: SegmentDub) -> Bool {
        guard dub.audioFilePath != nil else { return false }
        let snap = DubSnapshot(recordedStartFrame: dub.generatedForStartFrame,
                               recordedEndFrame: dub.generatedForEndFrame,
                               recordedTextHash: dub.generatedForTextHash)
        if case .stale = DubStaleness.check(snapshot: snap,
                                            currentStartFrame: segment.startFrame,
                                            currentEndFrame: segment.endFrame,
                                            currentTextHash: DubStaleness.textHash(of: dub.rewrittenText)) {
            return true
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("变体池").font(.headline)
            Text("分镜 \(segment.segmentIndex) · 时长 \(String(format: "%.1f", segment.duration))s")
                .font(.caption).foregroundStyle(.secondary)

            if segment.isVoiceLocked {
                Label("保留原声（明星锁定，不参与裂变）", systemImage: "lock.fill")
                    .font(.callout).foregroundStyle(.orange).padding(.top, 8)
            } else if voices.isEmpty {
                Text("请先在顶部「配音设置」选择音色").font(.callout).foregroundStyle(.secondary).padding(.top, 8)
            } else if segment.segmentDubs.isEmpty {
                Text("点顶部「一键改写台词」生成变体").font(.callout).foregroundStyle(.secondary).padding(.top, 8)
            } else {
                matrix
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 320)
        .background(Color(.windowBackgroundColor))
    }

    private var matrix: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(0..<DubbingViewModel.textVariantCount, id: \.self) { t in
                    let text = dub(textVariant: t, voiceId: voices.first ?? "")?.rewrittenText ?? ""
                    VStack(alignment: .leading, spacing: 6) {
                        Text("改写版 \(Character(UnicodeScalar(65 + t)!))").font(.caption.weight(.semibold))
                        Text(text.isEmpty ? "（无文本）" : text).font(.callout)
                            .textSelection(.enabled)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.textBackgroundColor).opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        HStack(spacing: 8) {
                            ForEach(voices, id: \.self) { v in cell(textVariant: t, voiceId: v) }
                        }
                    }
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func cell(textVariant t: Int, voiceId v: String) -> some View {
        let d = dub(textVariant: t, voiceId: v)
        VStack(spacing: 3) {
            Text(voiceName(v)).font(.caption2).foregroundStyle(.secondary)
            if let d, dubVM.busyDubIDs.contains(d.id) {
                ProgressView().controlSize(.mini)
            } else if let d, d.audioFilePath != nil {
                Button {
                    Task { await dubVM.generateAudio(for: d, context: modelContext) }
                } label: {
                    Image(systemName: isStale(d) ? "exclamationmark.arrow.circlepath" : "checkmark.circle.fill")
                        .foregroundStyle(isStale(d) ? .orange : .green)
                }
                .buttonStyle(.borderless)
                .help(isStale(d) ? "已过期，点重生成" : "已生成（点重生成）")
            } else if let d {
                Button("＋生成") {
                    Task { await dubVM.generateAudio(for: d, context: modelContext) }
                }
                .font(.caption2).buttonStyle(.borderless)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .frame(width: 86, height: 44)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
```
> 说明:格按钮统一调 `generateAudio`(已生成则等于重生成)。播放已生成音频的 ▶ 可后续加;本期「✓ 已生成」即表示可用,导出会用它。试听已生成音频留作增强(非阻塞)。

- [ ] **Step 2: 挂进 SegmentLibraryView(右侧检视栏)**

把 `mainContent` 的内容区(`segmentContent`/`emptyState` 那段)包进一个 `HStack(spacing: 0)`,右侧在选中分镜时显示检视栏:
```swift
HStack(spacing: 0) {
    // 既有内容（segmentContent / emptyState）放左侧，撑满
    Group { /* 原 content */ }
        .frame(maxWidth: .infinity)
    if let seg = viewModel.selectedSegment {
        Divider()
        SegmentVariantInspector(segment: seg, dubVM: dubVM)
    }
}
```
> 实现者:把原本直接放在 VStack 里的内容区移进这个 HStack 左侧分支,不要改其余 toolbar/批量条逻辑。`viewModel.selectedSegment` 已存在(单选)。

- [ ] **Step 3: 登记 pbxproj + 编译 + 自测截图**

登记 `SegmentVariantInspector.swift`。编译 `** BUILD SUCCEEDED **`,重启应用。
**人工**:选 3 音色 → 一键改写 → 点某分镜(单选)→ 右侧出现变体池矩阵(2 行改写 × 3 列音色),点某格「＋生成」会转圈→✓;锁定段显示「保留原声」。截图留证。9:16 不受影响。

- [ ] **Step 4: 提交**

```bash
git add MixCut/Views/SegmentLibrary/SegmentVariantInspector.swift MixCut/Views/SegmentLibrary/SegmentLibraryView.swift MixCut.xcodeproj/project.pbxproj
git commit -m "feat(dubbing): P5 右侧变体池检视栏（K改写×音色矩阵+按需生成）"
```

---

### Task 7: 方案生成接入变体(音色模式开关 + 逐槽分配)

**Files:**
- Modify: `MixCut/ViewModels/SchemeViewModel.swift`(`createSchemeSegments` 注入分配)、方案生成入口 UI(`SchemeListView` 或生成设置处,加「音色模式」选择)

**Interfaces:**
- Consumes: `VariantSelector.assign(slots:mode:variationSeed:)`、`SlotInput`、`DubOption`、`VariantSelectorMode`;`MixScheme.voiceMode`/`unifiedVoiceId`;`SchemeSegment.selectedSegmentDubId`;`Segment.segmentDubs`/`isVoiceLocked`;`Video.selectedVoiceIds`
- Produces: `createSchemeSegments` 在建槽后给每槽写 `selectedSegmentDubId`;`MixScheme` 落 `voiceMode`/`unifiedVoiceId`

- [ ] **Step 1: 在 createSchemeSegments 末尾注入变体分配**

在 `MixCut/ViewModels/SchemeViewModel.swift` 的 `createSchemeSegments(...)`(line ~296–330)里,**所有 SchemeSegment 插入完成后**,加一段(用方案的 voiceMode/unifiedVoiceId,seed 用 `scheme.variationIndex`):
```swift
// —— 配音变体逐槽分配 ——
let ordered = scheme.orderedSegments
let slots: [SlotInput] = ordered.map { ss in
    let seg = ss.segment
    let options = (seg?.segmentDubs ?? []).map {
        DubOption(id: $0.id, voiceId: $0.voiceId, textVariantIndex: $0.textVariantIndex)
    }
    return SlotInput(isVoiceLocked: seg?.isVoiceLocked ?? false, options: options)
}
let mode: VariantSelectorMode = scheme.voiceMode == .unified
    ? .unified(voiceId: scheme.unifiedVoiceId ?? "")
    : .mixed
let assigned = VariantSelector.assign(slots: slots, mode: mode, variationSeed: scheme.variationIndex)
for (ss, dubId) in zip(ordered, assigned) {
    ss.selectedSegmentDubId = dubId
}
```

- [ ] **Step 2: 生成方案时传入音色模式**

在方案生成的调用链里(实现者读 `SchemeViewModel` 生成入口),把用户选择的音色模式写到新建的 `MixScheme` 上:`scheme.voiceMode = …`、统一模式时 `scheme.unifiedVoiceId = …`。生成设置 UI(方案列表/生成弹窗,实现者按现有生成入口落位)加一个 `Picker`:
```swift
Picker("配音音色", selection: $voiceMode) {
    Text("统一音色").tag(VoiceMode.unified)
    Text("混用音色").tag(VoiceMode.mixed)
}
// 统一模式再给一个从 video.selectedVoiceIds 选 unifiedVoiceId 的 Picker
```
> 若当前生成入口没有现成设置面板,最小实现:在方案列表生成按钮旁加一个 `Menu`/`Picker` 持有 `@State voiceMode`/`unifiedVoiceId`,生成时传入。默认 `unified` + `selectedVoiceIds.first`。

- [ ] **Step 3: 编译 + 自测**

编译 `** BUILD SUCCEEDED **`,重启。
**人工**:先在分镜库选音色+改写+生成几格音频 → 生成方案(分别试「统一」「混用」)→ 不报错。变体是否真的写入下个任务在方案页可视化验证。

- [ ] **Step 4: 提交**

```bash
git add MixCut/ViewModels/SchemeViewModel.swift MixCut/Views/Schemes/
git commit -m "feat(dubbing): P5 方案生成按音色模式逐槽分配配音变体"
```

---

### Task 8: 方案页逐槽变体标 + ▶试听 + 换变体(StoryboardCard)

**Files:**
- Modify: `MixCut/Views/Schemes/SchemeDetailView.swift`(`StoryboardCard` line ~247)

**Interfaces:**
- Consumes: `SchemeSegment.selectedSegmentDubId`、`Segment.segmentDubs`/`isVoiceLocked`、`QwenVoiceCatalog`、`DubbingViewModel`(可选,用于▶播放/补生成);`MixScheme.voiceMode`
- Produces: `StoryboardCard` 内显示变体标 + 换变体下拉

- [ ] **Step 1: 在 StoryboardCard 内加变体标与换变体**

在 `StoryboardCard`(`MixCut/Views/Schemes/SchemeDetailView.swift` line ~247)的卡片 body 适当位置(缩略图下方/台词附近)加:
```swift
// 计算当前选定变体
private var chosenDub: SegmentDub? {
    guard let id = schemeSeg.selectedSegmentDubId else { return nil }
    return schemeSeg.segment?.segmentDubs.first { $0.id == id }
}
private func voiceName(_ id: String) -> String {
    QwenVoiceCatalog.all.first { $0.id == id }?.displayName ?? id
}
```
卡片内呈现:
```swift
Group {
    if schemeSeg.segment?.isVoiceLocked == true {
        Label("原声（锁定）", systemImage: "lock.fill")
            .font(.caption2).foregroundStyle(.orange)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(0.15)))
    } else if let d = chosenDub {
        Menu {
            // 换变体：列出该分镜池里所有变体
            ForEach(schemeSeg.segment?.segmentDubs ?? [], id: \.id) { opt in
                Button {
                    schemeSeg.selectedSegmentDubId = opt.id
                    try? modelContext.save()
                } label: {
                    Text("\(voiceName(opt.voiceId)) · 改写\(Character(UnicodeScalar(65 + opt.textVariantIndex)!))"
                         + (opt.id == d.id ? " ✓" : ""))
                }
            }
        } label: {
            Label("\(voiceName(d.voiceId)) · 改写\(Character(UnicodeScalar(65 + d.textVariantIndex)!))",
                  systemImage: "waveform")
                .font(.caption2).foregroundStyle(.green)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.green.opacity(0.15)))
        }
        .menuStyle(.borderlessButton).fixedSize()
    } else {
        Text("原声").font(.caption2).foregroundStyle(.secondary)
    }
}
```
> 需要 `@Environment(\.modelContext) private var modelContext` 在 `StoryboardCard` 内(若没有则加)。▶试听已生成音频可作增强(用 `AVAudioPlayer` 播 `chosenDub?.audioFilePath`),本期至少做到「看到用了哪个 + 换变体」。

- [ ] **Step 2: 编译 + 自测截图**

编译 `** BUILD SUCCEEDED **`,重启。
**人工**:打开一个已生成的方案,确认每槽显示绿标(音色·改写版)/橙标(原声锁定);点绿标下拉能换变体并即时更新。截图留证。9:16 卡片不受影响。

- [ ] **Step 3: 提交**

```bash
git add MixCut/Views/Schemes/SchemeDetailView.swift
git commit -m "feat(dubbing): P5 方案页逐槽变体标+换变体"
```

---

### Task 9: 导出配音版 —— 入口 + 导出前补齐缺失音频

**Files:**
- Modify: `MixCut/Views/Export/ExportView.swift`(加「导出配音版」入口)、并新增导出前补齐逻辑(放 `DubbingViewModel` 或 ExportView 调用处)

**Interfaces:**
- Consumes: `DubExportInput.from(scheme:)`(Task 1)、`DubExportService().export(input:outputPath:config:onProgress:)`(P4)、`DubbingViewModel.generateAudio`(补齐)、`MixScheme`/`SchemeSegment.selectedSegmentDubId`/`Segment.segmentDubs`
- Produces: `func ensureSelectedAudio(for scheme: MixScheme, context:) async`(补齐被选中但无音频的变体)→ 再 `DubExportInput.from(scheme:)` → `DubExportService.export`

- [ ] **Step 1: 在 DubbingViewModel 加导出前补齐**

```swift
/// 导出前：对方案里被选中但还没音频的变体按需补齐合成。
func ensureSelectedAudio(for scheme: MixScheme, context: ModelContext) async {
    for ss in scheme.orderedSegments {
        guard let id = ss.selectedSegmentDubId,
              let dub = ss.segment?.segmentDubs.first(where: { $0.id == id }),
              dub.audioFilePath == nil else { continue }
        await generateAudio(for: dub, context: context)
    }
}
```

- [ ] **Step 2: ExportView 加「导出配音版」入口**

在 `MixCut/Views/Export/ExportView.swift` 导出区加一个按钮(与现有「导出」并列;现有普通导出走 `ExportService` 不动):
```swift
Button("导出配音版") {
    Task {
        await dubVM.ensureSelectedAudio(for: scheme, context: modelContext)
        guard let input = DubExportInput.from(scheme: scheme) else { /* 提示无可导出 */ return }
        let out = /* 现有取输出路径逻辑 */ ""
        try? await DubExportService().export(input: input, outputPath: out,
            config: ExportConfig()) { p in /* 复用现有进度回显 */ }
    }
}
```
> 实现者:复用 ExportView 现有「选输出路径 / 进度展示 / 完成提示」基础设施;`dubVM` 用 `@State private var dubVM = DubbingViewModel()` 或从环境取。`scheme` = 当前选中方案。

- [ ] **Step 3: 编译 + 端到端自测**

编译 `** BUILD SUCCEEDED **`,重启。
**人工端到端**(必做):选 3 音色 → 一键改写 → 给方案要用的几格生成音频 → 生成方案(统一/混用各一)→ 方案页确认变体标 → 点「导出配音版」→ 用 ffprobe 校验输出 9:16 h264 + 时长合理 → **肉眼播放**:旧硬字幕 100% 遮住、新字幕清晰居中不飘、配音是新音色对得上、锁定段原声原画原字幕、衔接无黑帧。截图/录屏留证。

- [ ] **Step 4: 提交**

```bash
git add MixCut/Views/Export/ExportView.swift MixCut/ViewModels/DubbingViewModel.swift
git commit -m "feat(dubbing): P5 导出配音版入口+导出前按需补齐音频"
```

---

## Self-Review

**1. Spec 覆盖**(对照 `2026-06-23-dubbing-p5-fission-orchestration-design.md`):
- §3 数据模型(退役 DubVariant / SegmentDub 变体池 / Video.selectedVoiceIds / MixScheme.voiceMode+unifiedVoiceId / SchemeSegment.selectedSegmentDubId)→ Task 1 ✅
- §3.5 音频路径(voiceId+textVariantIndex)→ Task 3 ✅
- §4.1 顶栏选音色+试听+一键改写 → Task 5 ✅
- §4.2 右侧检视栏变体池矩阵(K 行 × 音色列 + 按需 + 失效标)→ Task 6 ✅
- §5.1 改写预生成建池 / §5.2 按需 TTS / §5.3 试听 → Task 4 ✅
- §6.1 音色模式开关 / §6.2 组合引擎逐槽分配(VariantSelector)→ Task 2 + Task 7 ✅
- §6.3 方案页变体标 + 换变体 → Task 8 ✅
- §7 导出 from(scheme:) + 补齐缺失音频 → Task 1(from)+ Task 9(补齐/入口)✅
- §9 模块边界(DubbingViewModel / VariantSelector / 复用 P2P3P4)✅
- §10 测试(VariantSelector 单测 + 各任务编译/人工)✅

**2. 占位符扫描**:UI 任务中标注「实现者按现有结构落位」之处(`groupedSegments.video` 属性名、ExportView 输出路径基础设施、方案生成入口),均为「复用既有、读上下文确认」而非缺代码;核心逻辑代码完整。可接受(SwiftUI 集成需贴合现状)。

**3. 类型一致性**:`SegmentDub(segment:voiceId:voiceProvider:textVariantIndex:rewrittenText:)`、`VariantSelector.assign(slots:mode:variationSeed:)`、`DubOption(id:voiceId:textVariantIndex:)`、`SlotInput(isVoiceLocked:options:)`、`VariantSelectorMode.unified(voiceId:)/.mixed`、`DubAudioFinalizer.finalize(...segmentId:voiceId:textVariantIndex:)`、`FileHelper.dubAudioURL(videoHash:segmentId:voiceId:textVariantIndex:)`、`DubExportInput.from(scheme:)`、`DubbingViewModel.textVariantCount` 在定义处与各消费处一致。`VoiceMode`(模型枚举,unified/mixed)与 `VariantSelectorMode`(Core 枚举,带 voiceId)是两个类型,Task 7 显式转换,无冲突。

> **已知约束/留给执行期**:① UI 任务无 xcodeproj 测试 target,以编译+人工截图验收;② `VideoSegmentGroup` 的视频属性名、ExportView 既有基础设施、方案生成入口面板的精确落位需实现者读当前代码贴合;③ 顶栏「当前视频」取分组首个,多视频分组下的视频切换可作增强;④ ▶播放已生成/选定音频是增强项,本期核心是生成+选用+导出。
