# 分镜头级 AI 局部编辑（纯提示词）+ 占位式重组 — 实施计划

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把一条逻辑分镜切成有序「分镜头」，对单个分镜头用纯文字提示词调阿里 `wan2.7-videoedit` 生成 AI 编辑变体，再占位式（每坑单选、顺序锁死）重组成一条新逻辑分镜进库，下游全走既有逻辑。

**Architecture:** 纯算法（分镜头切分/资格判定/占位校验/帧数对齐）放 `Sources/MixCutCore`（`public enum` 全 static 纯函数 + Swift Testing）；有副作用的（FFmpeg 切片/拼接、DashScope 调用、SwiftData 落库）放 `MixCut/Services` + `MixCut/ViewModels`，仿现有配音（`SegmentDub`/`DubbingViewModel`/`QwenTTSClient`）范式。DashScope 异步轮询客户端为净新增（项目无现成 HTTP 轮询骨架）。

**Tech Stack:** Swift 5.10 / SwiftUI / SwiftData / macOS 14；FFmpeg（内置二进制，`actor FFmpegRunner`）；DashScope REST（`wan2.7-videoedit`）；Swift Testing（MixCutCore 单测）。

---

## ⚠️ 执行前必读（项目铁律）

1. **不自动 git 提交/发版**：本项目规则禁止自动 `git add/commit/push`。本计划各 Task 末尾的"检查点"是**编译/测试验证**，**不含 git 提交**；提交时机由用户决定。执行时请在**独立 feature 分支/worktree** 上做（勿在 main 直接改）。
2. **自己先测**：改 UI 后必须编译→`pkill -x MixCut; open <app>`→截图/自测，不能甩给用户。不可自测的列人工验收清单。
3. **Schema 变更先备份库**：`cp ~/Library/Application\ Support/MixCut.store ~/Library/Application\ Support/MixCut.store.bak`（注意本项目专属库是 `MixCut.store` 不是 `default.store`）。
4. **9:16 竖屏铁律**：所有视频/缩略图/预览一律 9:16。
5. **Universal 铁律**：本功能不新增内置二进制（wan2.7 是云 API），不影响 universal；但发版仍走 `-destination generic + ARCHS="arm64 x86_64"`。
6. **切换项目联动**：新视图依赖项目数据时用 `.task(id:)`/`onChange`。

**参考 spec**：`docs/superpowers/specs/2026-07-03-shot-level-prompt-edit-design.md`

---

## 文件结构（先锁定分解）

**新建（纯算法，Sources/MixCutCore）**
- `Sources/MixCutCore/ShotSegmentationEngine.swift` — 逻辑分镜窗口 + scene cuts + fps → 有序物理镜头帧区间
- `Sources/MixCutCore/ShotEditRules.swift` — 可编辑资格 `[2s,10s]` + 占位式选择校验
- `Sources/MixCutCore/FrameCountAligner.swift` — 变体/原切片规整到目标帧数的 trim/pad 计划
- `Tests/MixCutCoreTests/ShotSegmentationEngineTests.swift`
- `Tests/MixCutCoreTests/ShotEditRulesTests.swift`
- `Tests/MixCutCoreTests/FrameCountAlignerTests.swift`

**新建（数据模型，MixCut/Models）**
- `MixCut/Models/PhysicalShot.swift` — @Model 分镜头
- `MixCut/Models/ShotVariant.swift` — @Model 变体（仿 `SegmentDub`）
- （改）`MixCut/Models/Segment.swift` — 加 `sourceSegmentID`、`physicalShots` cascade 关系
- （改）`MixCut/App/MixCutApp.swift` — ModelContainer schema 注册新模型

**新建（服务，MixCut/Services）**
- `MixCut/Services/ShotEdit/ShotSlicerService.swift` — actor：对分镜跑 scene 检测 + 调 Engine，产出/持久化 PhysicalShot
- `MixCut/Services/ShotEdit/Wan25VideoEditClient.swift` — actor：DashScope 异步 task 轮询客户端（净新增）
- `MixCut/Services/ShotEdit/ShotVariantService.swift` — actor：切片→调 client→下载→缩略图→落库
- `MixCut/Services/ShotEdit/ShotCompositionService.swift` — actor：帧数对齐→concat→合回原音频→建 Video/Segment
- `MixCut/Services/ShotEdit/PromptPresets.swift` — 预设提示词
- （改）`MixCut/Utilities/FileHelper.swift` — 加 ShotVariants 落盘路径

**新建（VM + UI，MixCut/ViewModels + Views）**
- `MixCut/ViewModels/ShotEditViewModel.swift` — @MainActor @Observable
- `MixCut/Views/SegmentLibrary/ShotEditSheet.swift` — 全屏工作区
- `MixCut/Views/SegmentLibrary/ShotTrackRow.swift` — 分镜头轨道（9:16）
- `MixCut/Views/SegmentLibrary/ShotVariantPicker.swift` — 单分镜头的版本单选 + 生成
- （改）`MixCut/Views/SegmentLibrary/SegmentLibraryView.swift` — 入口按钮 + sheet 挂载
- （改）`MixCut/ViewModels/SegmentLibraryViewModel.swift` — 合成分镜按 `sourceSegmentID` 归入原视频组、紧排原分镜之后（Task 13b）

---

## Phase 0：API 验证闸门（首日 spike，Go/No-Go）

> **这是整个功能的命门（spec §10.1）。未通过不得进入 Phase 3+。** 产物是可弃的 spike 脚本，不进主代码。

### Task 0: wan2.7-videoedit 实测验证

**Files:**
- Create（可弃）: `scratchpad/wan25_spike.sh`（或 `.swift`）

- [ ] **Step 1: 确认 model-id / 端点 / 参数**
  用现有 `api_key_qwen`（`UserDefaults` key 名 `api_key_qwen`）向 `POST https://dashscope.aliyuncs.com/api/v1/services/aigc/video-generation/video-synthesis`（头 `Authorization: Bearer <key>`、`Content-Type: application/json`、`X-DashScope-Async: enable`）提交一个 `wan2.7-videoedit` 任务；确认 model-id 真实存在（北京区命名坑，参照旧文档 `wanx2.1-` vs `wan2.1-`）。

- [ ] **Step 2: 确认输入形态**
  用一段真实 3~4s 竖屏分镜切片测试：`media` 传 **Base64** 是否被接受；不行则测 DashScope 临时上传拿 `oss://`（加头 `X-DashScope-OssResourceResolve: enable`）。记录结论。

- [ ] **Step 3: 轮询取结果**
  `GET https://dashscope.aliyuncs.com/api/v1/tasks/{task_id}` 轮询到 `SUCCEEDED`，拿输出视频 URL，立即下载（URL 24h 过期）。

- [ ] **Step 4: 【核心】保真度实测**
  用 spec §7 的 4 类示例各跑一条，人工判定："只改目标、人物动作/其余画面/整段一致"是否成立：
  - `把画面里的长发女孩换成利落的短发`
  - `把女孩的睡衣从粉色换成蓝色`
  - `把画面背景里那幅画换成梵高的《星月夜》`
  - `把手里的可乐换成一瓶雪碧`

- [ ] **Step 5: 记录硬事实**
  记录：输出是否**有声**、输出**实际帧数 vs 输入帧数偏差**（影响 §Phase1 FrameCountAligner）、输出分辨率/fps、单次**计费**、`duration` 是否需显式传 0、**下限 2s** 是否真被接受。

- [ ] **Step 6: Go/No-Go 结论**
  把结论追加到 spec 文档末尾「§附录：Phase 0 实测结论」。若保真度不达标 → 停下与用户讨论"框选精确模式"回退，不继续。

**检查点**：结论写入 spec；用户确认 Go 后继续。

---

## Phase 1：纯算法核心（MixCutCore / Swift Testing / TDD）

> 无外部依赖，可 `swift test` 秒级验证，先行完成。运行：`cd /Users/menggang/www/Mixed_cut && swift test --filter <TestType>`

### Task 1: ShotSegmentationEngine（分镜头切分）

**Files:**
- Create: `Sources/MixCutCore/ShotSegmentationEngine.swift`
- Test: `Tests/MixCutCoreTests/ShotSegmentationEngineTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
import Testing
@testable import MixCutCore

struct ShotSegmentationEngineTests {
    // 分镜窗口 [0,8]s，内部两个强切点 3.0/5.5 → 切出 3 个分镜头
    @Test("窗口内 scene cuts 切成有序帧区间")
    func splitsByScenes() {
        let shots = ShotSegmentationEngine.split(
            segmentStart: 0.0, segmentEnd: 8.0,
            sceneCuts: [ShotCut(time: 3.0), ShotCut(time: 5.5)],
            fps: 30.0
        )
        #expect(shots.count == 3)
        #expect(shots[0].startFrame == 0)
        #expect(shots[0].endFrame == 90)      // 3.0*30
        #expect(shots[1].startFrame == 90)
        #expect(shots[2].endFrame == 240)     // 8.0*30
        #expect(shots.map(\.orderIndex) == [1, 2, 3])
    }

    @Test("窗口外/边界处的 cuts 被忽略")
    func ignoresOutOfRangeCuts() {
        let shots = ShotSegmentationEngine.split(
            segmentStart: 2.0, segmentEnd: 6.0,
            sceneCuts: [ShotCut(time: 1.0), ShotCut(time: 6.0), ShotCut(time: 8.0)],
            fps: 25.0
        )
        #expect(shots.count == 1)             // 无有效内部切点 → 整段一个分镜头
        #expect(shots[0].startFrame == 50)    // 2.0*25
        #expect(shots[0].endFrame == 150)     // 6.0*25
    }

    @Test("过近的 cut 合并，不产生 <最小帧数 的碎片")
    func mergesTooCloseCuts() {
        let shots = ShotSegmentationEngine.split(
            segmentStart: 0.0, segmentEnd: 5.0,
            sceneCuts: [ShotCut(time: 0.1), ShotCut(time: 2.5)],  // 0.1 太靠头
            fps: 30.0, minShotSeconds: 0.5
        )
        #expect(shots.count == 2)             // 0.1 被并入首段
        #expect(shots[0].startFrame == 0)
        #expect(shots[0].endFrame == 75)      // 2.5*30
    }
}
```

- [ ] **Step 2: 跑测试确认失败**
  Run: `swift test --filter ShotSegmentationEngineTests`
  Expected: 编译失败（`ShotSegmentationEngine`/`ShotCut` 未定义）

- [ ] **Step 3: 最小实现**

```swift
import Foundation

/// 分镜头切分输入：一个画面切换点（秒，相对源视频时间轴）
public struct ShotCut: Sendable, Equatable {
    public let time: Double
    public init(time: Double) { self.time = time }
}

/// 分镜头切分结果：源视频绝对帧号区间 + 顺序
public struct ShotRange: Sendable, Equatable {
    public let orderIndex: Int   // 1 起
    public let startFrame: Int
    public let endFrame: Int
    public init(orderIndex: Int, startFrame: Int, endFrame: Int) {
        self.orderIndex = orderIndex
        self.startFrame = startFrame
        self.endFrame = endFrame
    }
}

/// 把一条逻辑分镜的时间窗口，按内部画面切换点切成有序物理镜头（纯函数）。
public enum ShotSegmentationEngine {
    public static func split(
        segmentStart: Double,
        segmentEnd: Double,
        sceneCuts: [ShotCut],
        fps: Double,
        minShotSeconds: Double = 0.5
    ) -> [ShotRange] {
        guard fps > 0, segmentEnd > segmentStart else { return [] }
        // 只取严格落在窗口内部的切点，排序去重
        let interior = sceneCuts
            .map(\.time)
            .filter { $0 > segmentStart && $0 < segmentEnd }
            .sorted()
        // 合并过近切点：与上一个已接受切点/窗口起点间隔 >= minShotSeconds 才接受
        var accepted: [Double] = []
        var last = segmentStart
        for t in interior where t - last >= minShotSeconds && segmentEnd - t >= minShotSeconds {
            accepted.append(t)
            last = t
        }
        // 生成帧区间
        let bounds = [segmentStart] + accepted + [segmentEnd]
        var shots: [ShotRange] = []
        for i in 0..<(bounds.count - 1) {
            let sf = FrameTime.frame(seconds: bounds[i], fps: fps)
            let ef = FrameTime.frame(seconds: bounds[i + 1], fps: fps)
            guard ef > sf else { continue }
            shots.append(ShotRange(orderIndex: shots.count + 1, startFrame: sf, endFrame: ef))
        }
        return shots
    }
}
```
> 复用现成 `FrameTime.frame(seconds:fps:)`（`Sources/MixCutCore/FrameTime.swift`）。

- [ ] **Step 4: 跑测试确认通过**
  Run: `swift test --filter ShotSegmentationEngineTests`
  Expected: PASS（3 个用例）

- [ ] **Step 5: 检查点** — 全绿；不 git 提交（见执行前必读 #1）。

---

### Task 2: ShotEditRules（资格 + 占位校验）

**Files:**
- Create: `Sources/MixCutCore/ShotEditRules.swift`
- Test: `Tests/MixCutCoreTests/ShotEditRulesTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
import Testing
@testable import MixCutCore

struct ShotEditRulesTests {
    @Test("时长在 [2,10] 才可编辑")
    func eligibility() {
        #expect(ShotEditRules.isEditable(durationSeconds: 2.0) == true)
        #expect(ShotEditRules.isEditable(durationSeconds: 10.0) == true)
        #expect(ShotEditRules.isEditable(durationSeconds: 1.99) == false)
        #expect(ShotEditRules.isEditable(durationSeconds: 10.1) == false)
    }

    @Test("不可编辑给出中文原因")
    func reason() {
        #expect(ShotEditRules.ineligibleReason(durationSeconds: 12.3)?.contains("10") == true)
        #expect(ShotEditRules.ineligibleReason(durationSeconds: 1.0)?.contains("2") == true)
        #expect(ShotEditRules.ineligibleReason(durationSeconds: 5.0) == nil)
    }

    @Test("占位选择：每坑必选且唯一、顺序完整 → 通过")
    func validSelection() {
        let sel = [1: SlotChoice.original, 2: SlotChoice.variant(UUID()), 3: SlotChoice.original]
        #expect(ShotEditRules.canCompose(slotCount: 3, selections: sel) == true)
    }

    @Test("有坑未选 → 不通过")
    func missingSlot() {
        let sel = [1: SlotChoice.original, 3: SlotChoice.original]
        #expect(ShotEditRules.canCompose(slotCount: 3, selections: sel) == false)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**
  Run: `swift test --filter ShotEditRulesTests` → 编译失败

- [ ] **Step 3: 最小实现**

```swift
import Foundation

public enum SlotChoice: Sendable, Equatable {
    case original
    case variant(UUID)
}

public enum ShotEditRules {
    public static let minSeconds = 2.0
    public static let maxSeconds = 10.0

    public static func isEditable(durationSeconds d: Double) -> Bool {
        d >= minSeconds && d <= maxSeconds
    }

    public static func ineligibleReason(durationSeconds d: Double) -> String? {
        if d > maxSeconds { return "该分镜头 \(String(format: "%.1f", d))s 超过 \(Int(maxSeconds))s 上限，请用帧级调整拆短后再替换" }
        if d < minSeconds { return "该分镜头 \(String(format: "%.1f", d))s 不足 \(Int(minSeconds))s 下限，无法替换" }
        return nil
    }

    /// 占位式：1...slotCount 每个坑都必须有且仅一个选择
    public static func canCompose(slotCount: Int, selections: [Int: SlotChoice]) -> Bool {
        guard slotCount > 0 else { return false }
        for slot in 1...slotCount where selections[slot] == nil { return false }
        return true
    }
}
```

- [ ] **Step 4: 跑测试确认通过** — `swift test --filter ShotEditRulesTests` → PASS

- [ ] **Step 5: 检查点** — 全绿。

---

### Task 3: FrameCountAligner（帧数对齐，防音画漂移 — spec §8.2）

**Files:**
- Create: `Sources/MixCutCore/FrameCountAligner.swift`
- Test: `Tests/MixCutCoreTests/FrameCountAlignerTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
import Testing
@testable import MixCutCore

struct FrameCountAlignerTests {
    @Test("变体帧数多于目标 → trim 掉尾部多余帧")
    func trimsExtra() {
        let plan = FrameCountAligner.plan(actualFrames: 97, targetFrames: 90)
        #expect(plan == .trim(dropTrailing: 7))
    }
    @Test("变体帧数少于目标 → pad 重复末帧补齐")
    func padsShort() {
        let plan = FrameCountAligner.plan(actualFrames: 88, targetFrames: 90)
        #expect(plan == .pad(repeatLast: 2))
    }
    @Test("帧数正好 → 无需处理")
    func exact() {
        #expect(FrameCountAligner.plan(actualFrames: 90, targetFrames: 90) == .none)
    }
}
```

- [ ] **Step 2: 跑测试确认失败** → 编译失败

- [ ] **Step 3: 最小实现**

```swift
import Foundation

/// 把一段视频切片规整到目标帧数的计划（纯计算，实际 trim/pad 由 FFmpeg 层执行）。
public enum FrameAlignPlan: Sendable, Equatable {
    case none
    case trim(dropTrailing: Int)
    case pad(repeatLast: Int)
}

public enum FrameCountAligner {
    public static func plan(actualFrames: Int, targetFrames: Int) -> FrameAlignPlan {
        if actualFrames == targetFrames { return .none }
        return actualFrames > targetFrames
            ? .trim(dropTrailing: actualFrames - targetFrames)
            : .pad(repeatLast: targetFrames - actualFrames)
    }
}
```

- [ ] **Step 4: 跑测试确认通过** — `swift test --filter FrameCountAlignerTests` → PASS

- [ ] **Step 5: 检查点** — `swift test`（全 MixCutCore 套件）全绿。

---

## Phase 2：数据模型（SwiftData）

> **先备份库**（见执行前必读 #3）。@Model 需 Xcode 编译，检查点用 `xcodebuild ... build`。

### Task 4: PhysicalShot / ShotVariant 模型 + Segment 关系

**Files:**
- Create: `MixCut/Models/PhysicalShot.swift`
- Create: `MixCut/Models/ShotVariant.swift`
- Modify: `MixCut/Models/Segment.swift`（加关系 + `sourceSegmentID`，参照现有 `segmentDubs` 声明 `:76-78`）
- Modify: `MixCut/App/MixCutApp.swift`（Schema 注册新模型）

- [ ] **Step 1: 备份库**
  `cp ~/Library/Application\ Support/MixCut.store ~/Library/Application\ Support/MixCut.store.bak`

- [ ] **Step 2: 建 `ShotVariant`（仿 `SegmentDub`）**

```swift
import Foundation
import SwiftData

enum ShotVariantStatus: String, Codable, CaseIterable {
    case pending, uploading, generating, completed, failed
}

@Model
final class ShotVariant {
    @Attribute(.unique) var id: UUID
    var shot: PhysicalShot?            // 反向引用（cascade 在 PhysicalShot 侧声明）
    var prompt: String = ""
    var statusRaw: String = ShotVariantStatus.pending.rawValue
    var status: ShotVariantStatus {
        get { ShotVariantStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }
    var taskId: String?
    var resultVideoPath: String?
    var thumbnailPath: String?
    var friendlyError: String?
    var createdAt: Date

    init(id: UUID = UUID(), prompt: String, createdAt: Date = .now) {
        self.id = id
        self.prompt = prompt
        self.createdAt = createdAt
    }
}
```

- [ ] **Step 3: 建 `PhysicalShot`**

```swift
import Foundation
import SwiftData

@Model
final class PhysicalShot {
    @Attribute(.unique) var id: UUID
    var parentSegment: Segment?
    var orderIndex: Int = 1
    var startFrame: Int = 0            // 源视频绝对帧号
    var endFrame: Int = 0
    var selectedVariantID: UUID?       // nil = 用原分镜头

    @Relationship(deleteRule: .cascade, inverse: \ShotVariant.shot)
    var variants: [ShotVariant] = []

    init(id: UUID = UUID(), orderIndex: Int, startFrame: Int, endFrame: Int) {
        self.id = id
        self.orderIndex = orderIndex
        self.startFrame = startFrame
        self.endFrame = endFrame
    }
}
```

- [ ] **Step 4: 改 `Segment.swift`** — 在现有 `segmentDubs` 关系旁加：

```swift
@Relationship(deleteRule: .cascade, inverse: \PhysicalShot.parentSegment)
var physicalShots: [PhysicalShot] = []

var sourceSegmentID: UUID?   // 合成分镜追溯来源；普通分镜为 nil
```

- [ ] **Step 5: 改 `MixCutApp.swift`** — 把 `PhysicalShot.self, ShotVariant.self` 加进 `Schema([...])`（找到现有 `SegmentDub.self` 所在数组一并加）。

- [ ] **Step 6: 编译验证**
  `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build`
  Expected: BUILD SUCCEEDED；启动 app（`pkill -x MixCut; open <DerivedData>/Build/Products/Debug/MixCut.app`）确认旧库能正常加载（新字段可选/新表，应向后兼容）。

- [ ] **Step 7: 检查点** — 编译通过 + app 正常起、旧项目数据在。

---

## Phase 3：服务层

### Task 5: FileHelper 落盘路径

**Files:** Modify `MixCut/Utilities/FileHelper.swift`（仿 `dubAudioURL` `:63-70`）

- [ ] **Step 1: 加路径方法**

```swift
/// 变体产物：AppSupport/MixCut/ShotVariants/{videoHash}/{shotId}/{variantId}.mp4
static func shotVariantURL(videoHash: String, shotId: UUID, variantId: UUID) throws -> URL {
    let dir = appSupportDirectory
        .appendingPathComponent("ShotVariants", isDirectory: true)
        .appendingPathComponent(videoHash, isDirectory: true)
        .appendingPathComponent(shotId.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("\(variantId.uuidString).mp4")
}
```

- [ ] **Step 2: 编译验证** — `xcodebuild ... build` → SUCCEEDED
- [ ] **Step 3: 检查点**

---

### Task 6: ShotSlicerService（切分镜头 + 落库）

**Files:** Create `MixCut/Services/ShotEdit/ShotSlicerService.swift`

复用 `SceneDetectionService.detectScenes(in:threshold:)`（但只需对**整段视频**跑一次再筛窗口，或对分镜切片跑）+ `ShotSegmentationEngine.split`。

- [ ] **Step 1: 实现（actor）**

```swift
import Foundation

actor ShotSlicerService {
    private let sceneDetector: SceneDetectionService
    init(sceneDetector: SceneDetectionService = SceneDetectionService()) {
        self.sceneDetector = sceneDetector
    }

    /// 对某逻辑分镜切出分镜头帧区间（纯数据；落库由调用方在 @MainActor 做）
    func computeShots(videoPath: String,
                      segmentStart: Double, segmentEnd: Double,
                      fps: Double) async throws -> [ShotRange] {
        let boundaries = try await sceneDetector.detectScenes(in: videoPath, threshold: 0.3)
        let cuts = boundaries.map { ShotCut(time: $0.time) }
        return ShotSegmentationEngine.split(
            segmentStart: segmentStart, segmentEnd: segmentEnd,
            sceneCuts: cuts, fps: fps
        )
    }
}
```
> `detectScenes` 返回 `[SceneBoundary]`（`SceneBoundary.time: Double` 已确认存在，`SceneDetectionService.swift:4`），`split` 内部已过滤只取窗口内部切点，故可直接喂。若性能需要，后续可改为先切出分镜切片再检测（YAGNI，暂不做）。

- [ ] **Step 2: 编译验证** → SUCCEEDED
- [ ] **Step 3: 检查点**

---

### Task 7: Wan25VideoEditClient（DashScope 异步轮询客户端 — 净新增）

**Files:** Create `MixCut/Services/ShotEdit/Wan25VideoEditClient.swift`

> 项目**无现成 HTTP 轮询骨架**。请求/鉴权/下载/错误映射仿 `QwenTTSClient.swift`；事件循环结构仿 `CosyVoiceTTSClient.swift:47-72`（改为 HTTP 轮询）。Base64/oss 走 Phase 0 结论。

- [ ] **Step 1: 实现（actor）**

```swift
import Foundation

actor Wan25VideoEditClient {
    enum ClientError: LocalizedError {
        case missingAPIKey, badResponse(String), taskFailed(String), timeout
        var errorDescription: String? { /* 中文 */ ... }
    }
    private static let submitURL = URL(string: "https://dashscope.aliyuncs.com/api/v1/services/aigc/video-generation/video-synthesis")!
    private static func taskURL(_ id: String) -> URL { URL(string: "https://dashscope.aliyuncs.com/api/v1/tasks/\(id)")! }
    private static let model = "wan2.7-videoedit"   // Phase 0 核对

    private let apiKeyProvider: @Sendable () -> String?
    init(apiKeyProvider: @escaping @Sendable () -> String? = { KeychainHelper.getAPIKey(for: .qwen) }) {
        self.apiKeyProvider = apiKeyProvider
    }

    /// 提交编辑任务 → 轮询 → 返回结果视频 URL（调用方负责下载）
    func edit(videoBase64OrURL media: String, prompt: String,
              onStatus: @Sendable (String) -> Void = { _ in }) async throws -> URL {
        guard let key = apiKeyProvider(), !key.isEmpty else { throw ClientError.missingAPIKey }
        // 1. 提交（X-DashScope-Async: enable）
        var req = URLRequest(url: Self.submitURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("enable", forHTTPHeaderField: "X-DashScope-Async")
        req.httpBody = try Self.buildBody(model: Self.model, media: media, prompt: prompt)
        let taskId = try await Self.submit(req)      // 解析 output.task_id
        onStatus("生成中")
        // 2. 轮询 GET /tasks/{id}，间隔 15s，总超时 ~10min
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 15 * 1_000_000_000)
            let (state, url, msg) = try await Self.query(taskId, key: key)
            switch state {
            case "SUCCEEDED": guard let u = url else { throw ClientError.badResponse("无输出URL") }; return u
            case "FAILED":    throw ClientError.taskFailed(msg ?? "task failed")
            default:          onStatus("生成中")   // PENDING/RUNNING
            }
        }
        throw ClientError.timeout
    }
    // buildBody / submit / query 私有辅助（JSON 解析）...
}
```

- [ ] **Step 2: 编译验证** → SUCCEEDED（网络逻辑不在此单测；契约在 Phase 0 已验证）
- [ ] **Step 3: 检查点**

---

### Task 8: ShotVariantService（切片→生成→下载→落库数据）

**Files:** Create `MixCut/Services/ShotEdit/ShotVariantService.swift`

- [ ] **Step 1: 实现（actor）** — 编排：
  1. `FFmpegRunner.cutSegment(from:start:end:fps:to:)` 切出分镜头 mp4（临时目录）；
  2. 读为 Base64（或走 oss 上传，Phase 0 结论）；
  3. `Wan25VideoEditClient.edit(...)` 拿结果 URL；
  4. `URLSession.download` 下载到 `FileHelper.shotVariantURL(...)`（http→https 绕 ATS，仿 `QwenTTSClient:44-52`）；
  5. `FFmpegRunner.generateThumbnail` 出缩略图；
  6. 返回 `(resultPath, thumbnailPath)`（落库由 VM 在 @MainActor 做）。
  错误统一 `APIErrorClassifier.friendly(_:)`（`AIProvider.swift:85`）。

- [ ] **Step 2: 编译验证** → SUCCEEDED
- [ ] **Step 3: 检查点**

---

### Task 9: ShotCompositionService（帧对齐→concat→合回原音频→建 Segment）

**Files:** Create `MixCut/Services/ShotEdit/ShotCompositionService.swift`

- [ ] **Step 1: 实现（actor）** — 步骤：
  1. 对每个坑取切片来源（原=从源视频 `cutSegment` 切；变体=`resultVideoPath`）；
  2. 对**每一个坑的切片（原切片 & 变体切片一律，spec §8.2 强调"一律"）**用 `ffprobe`/AVFoundation 测实际帧数 → `FrameCountAligner.plan(actual, target)` → FFmpeg trim/pad 到与该分镜头**精确帧数**一致。（原切片虽由 `cutSegment` 按帧切理应精确，但仍测一遍兜底帧漂移。）
  3. `FFmpegRunner.concat([...])` 拼画面轨；
  4. 从**原逻辑分镜**时间段提取原音频（`extractSegmentPCM`/`extractAudio`），mux 覆盖到拼接画面（时长逐帧对齐）；
  5. 算合成 mp4 的 hash → `FileHelper.copyVideoToGlobal` → 返回 `(compositeVideoPath, hash, totalFrames)`（建 Video/Segment 由 VM 做）。

- [ ] **Step 2: 编译验证** → SUCCEEDED
- [ ] **Step 3: 检查点**

---

### Task 10: PromptPresets（预设提示词）

**Files:** Create `MixCut/Services/ShotEdit/PromptPresets.swift`

- [ ] **Step 1: 实现** — 分组常量（换背景/换人物外观/换颜色材质/整体风格，内容取 spec §7）。
- [ ] **Step 2: 编译验证** → SUCCEEDED
- [ ] **Step 3: 检查点**

---

## Phase 4：ViewModel

### Task 11: ShotEditViewModel

**Files:** Create `MixCut/ViewModels/ShotEditViewModel.swift`（仿 `DubbingViewModel` `@MainActor @Observable`）

- [ ] **Step 1: 实现** — 可观察状态：`shots: [PhysicalShot]`（当前分镜的）、`busyVariantIDs: Set<UUID>`、`progress: [UUID:String]`、`selections: [Int: SlotChoice]`、`errorMessage`、`isComposing`。动作：
  - `loadShots(for segment:)`：先查已持久化 `segment.physicalShots`，空则 `ShotSlicerService.computeShots` → 建 `PhysicalShot` 落库；
  - `adjustBoundary(shot:newStartFrame:newEndFrame:)`：帧级微调 + 重算资格；
  - `generateVariant(shot:prompt:)`：资格校验（`ShotEditRules`）→ `ShotVariantService` → 落 `ShotVariant`；
  - `select(slot:choice:)`；
  - `compose(segment:)`：`ShotEditRules.canCompose` → `ShotCompositionService` → 建 Video+Segment（继承 `text/semanticTypes/keywords/positionType/visualDescription` **全部 5 项**，设 `sourceSegmentID`）。
  错误经 `APIErrorClassifier.friendly`；防重入用 `busyVariantIDs`。
  - **资格判定的 fps 来源**：`PhysicalShot` 无 fps 字段；VM 用 `parentSegment.video?.fps` 算 `duration = frameCount / fps` 再传 `ShotEditRules.isEditable(durationSeconds:)`。`video?.fps` 为空/0 时视为不可编辑并提示。

- [ ] **Step 2: 编译验证** → SUCCEEDED
- [ ] **Step 3: 检查点**

---

## Phase 5：UI

> 9:16 铁律；仿 `SegmentVariantInspector`/`SegmentDubControls`；`@State private var vm` + 子视图 `@Bindable`。改完必须编译+重启+**截图自测**。

### Task 12: ShotEditSheet + 子视图

**Files:**
- Create: `MixCut/Views/SegmentLibrary/ShotEditSheet.swift`（全屏 sheet：顶部分镜头轨道 + 选中分镜头的版本区 + 提示词输入/预设 + 「合成」按钮）
- Create: `MixCut/Views/SegmentLibrary/ShotTrackRow.swift`（横向分镜头缩略图 9:16 + 时长 + 资格标记；不可编辑置灰+提示）
- Create: `MixCut/Views/SegmentLibrary/ShotVariantPicker.swift`（单分镜头版本单选：原版 + 各变体缩略图，生成中 ProgressView，失败显 friendlyError，可删/重生成）

- [ ] **Step 1: 实现三个视图** — 数据用 `ThumbnailCache.shared`；调用范式 `Task { await vm.xxx() }`；比例 9:16。
- [ ] **Step 2: 编译 + 重启 app** — `xcodebuild ... build` → `pkill -x MixCut; open <app>`
- [ ] **Step 3: 截图自测** — `screencapture` 看轨道/版本区/预设是否正常、比例 9:16。
- [ ] **Step 4: 检查点**

---

### Task 13: 库入口按钮 + sheet 挂载

**Files:** Modify `MixCut/Views/SegmentLibrary/SegmentLibraryView.swift`

- [ ] **Step 1: 加「分镜头替换」入口**（选中逻辑分镜时可见）+ `.sheet` 挂 `ShotEditSheet`。
  **回归验证（勿破坏，见 CLAUDE.md）**：台词双击编辑、选中复制、卡片右键菜单、多选/批量导出/批量删除、配音变体池、切换项目 `.task(id:)` 联动。
- [ ] **Step 2: 编译 + 重启 + 截图** — 入口位置/点击进 sheet 正常。
- [ ] **Step 3: 检查点**

---

### Task 13b: 合成分镜在库内紧挨原分镜（改分组逻辑）

**Files:** Modify `MixCut/ViewModels/SegmentLibraryViewModel.swift`（`groupedSegments` / `VideoSegmentGroup` 构建处）

> 用户明确要"合成分镜紧挨原分镜之后"（spec §4.3）。当前库按**源视频分组**、组内按 `startTime` 排；合成分镜挂新 Video 会落独立组，做不到相邻。**此改动触及敏感库视图，务必回归验证。**

- [ ] **Step 1: 先读现状** — 通读 `SegmentLibraryViewModel.groupedSegments` 与 `VideoSegmentGroup`，用一句话列出它现在能做的事（分组、组内排序、筛选、多选等），改动只针对分组归属，不顺手重构。

- [ ] **Step 2: 改分组归属 + 组内重排（重排是主验收点）** —
  - `sourceSegmentID` 是 `UUID?`（**非关系属性**），先从当前 `segments` 构 `[UUID: Segment]` 查表解析出来源分镜及其 `video`。
  - 对 `sourceSegmentID != nil` 的合成分镜：分组键改用**来源分镜的 `video`**（而非自身 `video`）。
  - **关键**：合成分镜自带新 video、`startFrame=0` → `startTime=0`，现有全局按 `startTime` 排序会把它甩到组首。必须用**复合排序键 `(锚定用的 startTime = sourceSegment.startTime, 次级序号)`** 让它紧跟在 `sourceSegment` 之后，而不是只改分组键。
  - 若 `sourceSegment` 已被删除（查表 miss），退化为按自身 video 独立分组（不崩）。

- [ ] **Step 3: 编译 + 重启 + 截图** — 造一条合成分镜，确认它出现在原分镜正下方/紧后。

- [ ] **Step 4: 回归验证（CLAUDE.md 铁律，逐项跑）** — 普通分镜分组/组内 startTime 排序不变；多选/全选/批量导出/批量删除；台词双击编辑/选中复制；配音变体池；切换项目 A→B→A 联动刷新、选中状态不串档。

- [ ] **Step 5: 检查点** — 相邻生效 + 上述回归项全部照旧。

---

## Phase 6：端到端集成 + 人工验收

### Task 14: 全链路走查 + 验收清单

- [ ] **Step 1: 全链路（真机 app 手动）**
  选逻辑分镜 → 进 sheet → 分镜头切分展示 → 帧级微调一个分镜头 → 对一个分镜头写提示词生成变体（等异步完成）→ 各坑选定版本 → 合成 → 确认新逻辑分镜**在库内紧挨原分镜之后**（Task 13b 生效）。

- [ ] **Step 2: 下游等价性验收**（spec §3.7）
  对合成分镜跑：配音、台词改写、字幕烧录/遮挡、导出、排列组合选用 —— 确认与普通分镜行为一致，标签继承正确。

- [ ] **Step 3: 音画同步验收**（spec §8）
  合成多坑（含变体）后播放/导出，确认全程音画不漂移（FrameCountAligner 生效）。

- [ ] **Step 4: 切换项目联动验收**
  A→B→A 切换，sheet/库数据正确刷新，多选/选择状态无串档。

- [ ] **Step 5: 边界验收**
  分镜头 >10s / <2s：替换置灰 + 中文提示；置灰分镜头仍能占坑选原版。

- [ ] **Step 6: 汇总** — 列出「已自测通过」与「需用户复测」清单交用户。

---

## 附：与既有代码的关键复用点（避免重复造轮子）

| 需求 | 复用 | 位置 |
|---|---|---|
| 视频切片(setpts防黑屏) | `FFmpegRunner.cutSegment` | `FFmpegRunner.swift:379` |
| 拼接 | `FFmpegRunner.concat` | `:490` |
| 缩略图 | `FFmpegRunner.generateThumbnail` | `:599` |
| 场景切点 | `SceneDetectionService.detectScenes` | `SceneDetectionService.swift:57` |
| 帧↔秒 | `FrameTime.frame(seconds:fps:)` | `Sources/MixCutCore/FrameTime.swift` |
| 变体@Model范式 | `SegmentDub` + Segment cascade | `SegmentDub.swift`, `Segment.swift:76-78` |
| API Key | `KeychainHelper.getAPIKey(for:.qwen)`（=UserDefaults `api_key_qwen`） | `KeychainHelper.swift:17` |
| 请求/下载/ATS | `QwenTTSClient` | `QwenTTSClient.swift:24-62` |
| 事件循环结构 | `CosyVoiceTTSClient` | `CosyVoiceTTSClient.swift:47-72` |
| 错误→中文 | `APIErrorClassifier.friendly` | `AIProvider.swift:85` |
| 落盘/哈希/全局目录 | `FileHelper` + `ImportViewModel.computeFileHash` | `FileHelper.swift`, `ImportViewModel.swift:847` |
| Segment 创建/帧范围 | `ImportViewModel.createSegments` / `Segment.setFrameRange` | `ImportViewModel.swift:507`, `Segment.swift:172` |
| VM/UI 范式 | `DubbingViewModel` / `SegmentVariantInspector` | `DubbingViewModel.swift:6`, `SegmentVariantInspector.swift:4` |
