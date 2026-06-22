# 分镜级配音 P1 地基（数据模型 + 分镜级 UI）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为分镜级配音功能打好数据地基——给 `Segment` 加「保留原声」与「硬字幕遮挡」属性，新增 `DubVariant`/`SegmentDub` 两个模型，并在分镜素材库给出可拖拽的逐分镜遮挡框 UI。

**Architecture:** SwiftData 模型新增字段全部带默认值（加性迁移安全）；遮挡矩形的几何运算抽到 `MixCutCore` 纯值类型里做 TDD；UI 用自包含的 SwiftUI 组件，嵌进现有分镜卡片，严格 9:16 竖屏。

**Tech Stack:** Swift 6 / SwiftUI / SwiftData / Swift Testing（`MixCutCore` 纯逻辑单测）；Xcode 编译（SwiftData 宏依赖）。

## Global Constraints

- 必须用 Xcode 编译（SwiftData 宏依赖）：`xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build`。
- 编译成功后自动重启：`pkill -x MixCut; sleep 1; open /Users/menggang/Library/Developer/Xcode/DerivedData/MixCut-byytuggmhodpumcmwnwrtzwkmavr/Build/Products/Debug/MixCut.app`。
- 任何视频/缩略图/遮挡预览视图严格 **9:16 竖屏**（width:height = 9:16）。
- 改 SwiftData 模型前**必须先备份库**：`cp ~/Library/Application\ Support/MixCut/MixCut.store ~/Library/Application\ Support/MixCut/MixCut.store.bak`。
- 新增字段一律带默认值（lightweight 迁移要求）；不可变优先（`let`）、value 类型优先、actor 管共享状态。
- 中文交流；注释/commit 用中文。
- 不要自动 `git push` / 发版；commit 可做（计划内每任务结尾 commit），push 与发版等用户发话。
- 纯逻辑单测用 Swift Testing（`import Testing` + `@Test`/`#expect`），放 `Tests/MixCutCoreTests/`。
- SwiftData 模型 / UI / 集成类改动无法单测，验证方式 = 编译 + 重启 + 肉眼/截图核对（见各任务验证步骤）。

---

## 文件结构

| 文件 | 职责 | 动作 |
|---|---|---|
| `Sources/MixCutCore/SubtitleMaskRect.swift` | 遮挡矩形归一化值类型 + 钳制/像素换算/拖拽位移（纯逻辑，可测） | 新建 |
| `Tests/MixCutCoreTests/SubtitleMaskRectTests.swift` | 上面的单测 | 新建 |
| `MixCut/Models/DubEnums.swift` | `DubVariantStatus` / `SegmentDubStatus` / `MaskStyle` 三个枚举 | 新建 |
| `MixCut/Models/DubVariant.swift` | `@Model DubVariant`（某视频的第 K 版配音） | 新建 |
| `MixCut/Models/SegmentDub.swift` | `@Model SegmentDub`（某分镜在某版的配音） | 新建 |
| `MixCut/Models/Segment.swift` | 加 `isVoiceLocked` + 遮挡矩形字段 + 计算属性 | 修改 |
| `MixCut/App/MixCutApp.swift` | 两处 `Schema([...])` 数组各加两个新模型 | 修改 (84-92, 136-140) |
| `MixCut/Views/SegmentLibrary/SubtitleMaskOverlay.swift` | 9:16 预览上的可拖拽/调高遮挡框组件 | 新建 |
| `MixCut/Views/SegmentLibrary/SegmentDubControls.swift` | 「保留原声」「硬字幕遮挡」开关 + 样式选择 + 一键同步按钮 | 新建 |
| `MixCut/Views/SegmentLibrary/SegmentLibraryView.swift` | 把上面两个组件嵌进分镜卡片 | 修改 |

---

## Task 1: 遮挡矩形纯值类型（MixCutCore，TDD）

把"遮挡框"的几何运算（钳制进画面、像素换算、拖拽位移/调高）做成可独立测试的纯值类型。UI 只负责画，运算全在这里。

**Files:**
- Create: `Sources/MixCutCore/SubtitleMaskRect.swift`
- Test: `Tests/MixCutCoreTests/SubtitleMaskRectTests.swift`

**Interfaces:**
- Produces:
  - `struct SubtitleMaskRect: Equatable, Sendable, Codable` 字段 `x/y/width/height: Double`（均归一化 0~1，原点左上）
  - `static let defaultBottomBand: SubtitleMaskRect`（x=0, y=0.80, width=1.0, height=0.12）
  - `func clamped() -> SubtitleMaskRect`（每个分量钳进 [0,1]，并保证 x+width≤1、y+height≤1，width/height 最小 0.02）
  - `func movedBy(dy: Double) -> SubtitleMaskRect`（上下平移后 clamp）
  - `func resizedBy(dHeight: Double) -> SubtitleMaskRect`（改高度后 clamp，底边不超过 1）
  - `func pixelRect(width: Double, height: Double) -> (x: Double, y: Double, width: Double, height: Double)`（× 画面尺寸）

- [ ] **Step 1: 写失败测试**

```swift
// Tests/MixCutCoreTests/SubtitleMaskRectTests.swift
import Testing
@testable import MixCutCore

@Test("默认底部带状区位置正确")
func defaultBottomBand() {
    let r = SubtitleMaskRect.defaultBottomBand
    #expect(r.x == 0.0)
    #expect(r.y == 0.80)
    #expect(r.width == 1.0)
    #expect(r.height == 0.12)
}

@Test("clamped 把越界分量拉回画面内")
func clampedKeepsInside() {
    let r = SubtitleMaskRect(x: -0.2, y: 0.95, width: 1.5, height: 0.3).clamped()
    #expect(r.x >= 0.0 && r.x <= 1.0)
    #expect(r.y >= 0.0 && r.y <= 1.0)
    #expect(r.x + r.width <= 1.0 + 1e-9)
    #expect(r.y + r.height <= 1.0 + 1e-9)
}

@Test("clamped 保证最小高度不塌缩")
func clampedMinHeight() {
    let r = SubtitleMaskRect(x: 0, y: 0.5, width: 1.0, height: 0.0).clamped()
    #expect(r.height >= 0.02)
}

@Test("movedBy 平移后仍在画面内")
func movedByClamps() {
    let r = SubtitleMaskRect.defaultBottomBand.movedBy(dy: 0.5)
    #expect(r.y + r.height <= 1.0 + 1e-9)
}

@Test("resizedBy 增高后底边不出界")
func resizedByClamps() {
    let r = SubtitleMaskRect(x: 0, y: 0.9, width: 1, height: 0.05).resizedBy(dHeight: 0.5)
    #expect(r.y + r.height <= 1.0 + 1e-9)
}

@Test("pixelRect 按画面尺寸换算")
func pixelRectScales() {
    let p = SubtitleMaskRect(x: 0.1, y: 0.5, width: 0.8, height: 0.1)
        .pixelRect(width: 1080, height: 1920)
    #expect(p.x == 108)
    #expect(p.y == 960)
    #expect(p.width == 864)
    #expect(abs(p.height - 192) < 1e-6)
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter SubtitleMaskRectTests`
Expected: 编译失败 / `cannot find 'SubtitleMaskRect' in scope`

- [ ] **Step 3: 写最小实现**

```swift
// Sources/MixCutCore/SubtitleMaskRect.swift
import Foundation

/// 硬字幕遮挡矩形，归一化坐标（0~1，原点左上），与分辨率无关。
public struct SubtitleMaskRect: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// 9:16 竖屏常见底部字幕带
    public static let defaultBottomBand = SubtitleMaskRect(x: 0.0, y: 0.80, width: 1.0, height: 0.12)

    /// 最小尺寸，避免拖塌缩成 0
    private static let minSize = 0.02

    /// 把矩形钳制进 [0,1] 画面，并保证不出界、不塌缩
    public func clamped() -> SubtitleMaskRect {
        let w = min(max(width, Self.minSize), 1.0)
        let h = min(max(height, Self.minSize), 1.0)
        let cx = min(max(x, 0.0), 1.0 - w)
        let cy = min(max(y, 0.0), 1.0 - h)
        return SubtitleMaskRect(x: cx, y: cy, width: w, height: h)
    }

    /// 上下平移后钳制
    public func movedBy(dy: Double) -> SubtitleMaskRect {
        SubtitleMaskRect(x: x, y: y + dy, width: width, height: height).clamped()
    }

    /// 改高度后钳制（底边不出界）
    public func resizedBy(dHeight: Double) -> SubtitleMaskRect {
        SubtitleMaskRect(x: x, y: y, width: width, height: height + dHeight).clamped()
    }

    /// 换算成像素矩形
    public func pixelRect(width pxW: Double, height pxH: Double)
        -> (x: Double, y: Double, width: Double, height: Double) {
        (x * pxW, y * pxH, width * pxW, height * pxH)
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter SubtitleMaskRectTests`
Expected: 全部 PASS

- [ ] **Step 5: 提交**

```bash
git add Sources/MixCutCore/SubtitleMaskRect.swift Tests/MixCutCoreTests/SubtitleMaskRectTests.swift
git commit -m "feat: 新增遮挡矩形归一化值类型 SubtitleMaskRect（含单测）"
```

---

## Task 2: 配音相关枚举

三个状态/样式枚举，单独成文件，供模型与 UI 共用。

**Files:**
- Create: `MixCut/Models/DubEnums.swift`

**Interfaces:**
- Produces:
  - `enum DubVariantStatus: String, Codable, CaseIterable { case draft, generating, ready, failed }`
  - `enum SegmentDubStatus: String, Codable, CaseIterable { case pending, generated, failed }`
  - `enum MaskStyle: String, Codable, CaseIterable, Identifiable { case blur, solid, dim }` + `displayName`

- [ ] **Step 1: 写实现**

```swift
// MixCut/Models/DubEnums.swift
import Foundation

/// 一版配音（DubVariant）的生成状态
enum DubVariantStatus: String, Codable, CaseIterable {
    case draft        // 台词待确认 / 未生成
    case generating   // 改写+配音进行中
    case ready        // 全部生成完成
    case failed       // 整版失败
}

/// 单分镜配音（SegmentDub）的状态
enum SegmentDubStatus: String, Codable, CaseIterable {
    case pending      // 待生成
    case generated    // 已生成音频
    case failed       // 生成失败（可单独重生成）
}

/// 硬字幕遮挡样式
enum MaskStyle: String, Codable, CaseIterable, Identifiable {
    case blur         // 高斯模糊
    case solid        // 纯色
    case dim          // 半透明

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blur: return "模糊"
        case .solid: return "纯色"
        case .dim: return "半透明"
        }
    }
}
```

- [ ] **Step 2: 编译确认通过**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 提交**

```bash
git add MixCut/Models/DubEnums.swift
git commit -m "feat: 新增配音状态与遮挡样式枚举"
```

---

## Task 3: `Segment` 新增字段（保留原声 + 遮挡矩形）

**⚠️ 改前先备份数据库**（Global Constraints）。新字段全部带默认值，老数据 lightweight 迁移到默认值。

**Files:**
- Modify: `MixCut/Models/Segment.swift`

**Interfaces:**
- Consumes: `SubtitleMaskRect`（Task 1）、`MaskStyle`（Task 2）
- Produces（`Segment` 实例上）:
  - `var isVoiceLocked: Bool`（true=保留原声，不可重配）
  - `var hasHardSubtitle: Bool`
  - `var maskRect: SubtitleMaskRect`（计算属性，桥接四个存储 Double）
  - `var maskStyle: MaskStyle`（计算属性，桥接 `maskStyleRaw`）

- [ ] **Step 1: 备份数据库**

Run:
```bash
cp ~/Library/Application\ Support/MixCut/MixCut.store ~/Library/Application\ Support/MixCut/MixCut.store.bak 2>/dev/null; echo done
```
Expected: `done`

- [ ] **Step 2: 加存储字段**

在 `MixCut/Models/Segment.swift` 的 `var createdAt: Date`（第 76 行）之后插入：

```swift
    // MARK: - 配音改写相关（P1）

    /// 是否"保留原声"（明星出镜镜头 = true，不可重配）
    var isVoiceLocked: Bool = false

    /// 原片该分镜是否有硬字幕，需要遮挡
    var hasHardSubtitle: Bool = false

    /// 遮挡矩形（归一化 0~1，原点左上），默认底部带状区
    var maskX: Double = 0.0
    var maskY: Double = 0.80
    var maskWidth: Double = 1.0
    var maskHeight: Double = 0.12

    /// 遮挡样式（MaskStyle.rawValue：blur/solid/dim）
    var maskStyleRaw: String = "blur"
```

- [ ] **Step 3: 加计算属性桥接**

在 Task 3 Step 2 插入块之后，继续添加（仍在 `Segment` 类内）：

```swift
    /// 遮挡矩形（桥接四个归一化 Double）
    var maskRect: SubtitleMaskRect {
        get { SubtitleMaskRect(x: maskX, y: maskY, width: maskWidth, height: maskHeight) }
        set {
            let c = newValue.clamped()
            maskX = c.x; maskY = c.y; maskWidth = c.width; maskHeight = c.height
        }
    }

    /// 遮挡样式
    var maskStyle: MaskStyle {
        get { MaskStyle(rawValue: maskStyleRaw) ?? .blur }
        set { maskStyleRaw = newValue.rawValue }
    }
```

`MixCutCore` 需要被 `Segment.swift` 看到——确认文件顶部已 `import MixCutCore`；若没有，在 `import SwiftData` 下加一行 `import MixCutCore`。

- [ ] **Step 4: 编译确认通过**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: 重启并确认旧数据仍在**

Run:
```bash
pkill -x MixCut; sleep 1; open /Users/menggang/Library/Developer/Xcode/DerivedData/MixCut-byytuggmhodpumcmwnwrtzwkmavr/Build/Products/Debug/MixCut.app
```
人工核对：应用正常启动、原有项目/视频/分镜数据完整可见（lightweight 迁移成功，未清库）。若数据丢失立即从 `MixCut.store.bak` 恢复并排查。

- [ ] **Step 6: 提交**

```bash
git add MixCut/Models/Segment.swift
git commit -m "feat: Segment 新增保留原声开关与硬字幕遮挡矩形字段"
```

---

## Task 4: `DubVariant` 与 `SegmentDub` 模型 + Schema 注册

新增两个 `@Model`，并在 `MixCutApp` 两处 `Schema([...])` 都登记，否则不入库。

**Files:**
- Create: `MixCut/Models/DubVariant.swift`
- Create: `MixCut/Models/SegmentDub.swift`
- Modify: `MixCut/App/MixCutApp.swift`（84-92 与 136-140 两个 Schema 数组）

**Interfaces:**
- Consumes: `DubVariantStatus` / `SegmentDubStatus`（Task 2）、`Video`、`Segment`
- Produces:
  - `@Model DubVariant`：`id/video?/index/name/voiceId/voiceProvider/targetCharsPerSecond/statusRaw/createdAt/segmentDubs`，计算属性 `status: DubVariantStatus`
  - `@Model SegmentDub`：`id/variant?/segment?/rewrittenText/audioFilePath?/audioDuration/atempoFactor/freezePadFrames/statusRaw`，计算属性 `status: SegmentDubStatus`

- [ ] **Step 1: 写 DubVariant 模型**

```swift
// MixCut/Models/DubVariant.swift
import Foundation
import SwiftData

/// 一个视频的「第 K 版配音」，作为整体管理单元（全局共享，挂在 Video 上）
@Model
final class DubVariant {
    @Attribute(.unique) var id: UUID
    var video: Video?
    var index: Int                       // 版本号 1..N
    var name: String                     // "版本A" 可改名
    var voiceId: String                  // TTS 音色 id
    var voiceProvider: String            // minimax / qwen
    var targetCharsPerSecond: Double = 5.0
    var statusRaw: String = "draft"      // DubVariantStatus.rawValue
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \SegmentDub.variant)
    var segmentDubs: [SegmentDub] = []

    var status: DubVariantStatus {
        get { DubVariantStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }

    init(video: Video?, index: Int, name: String, voiceId: String, voiceProvider: String) {
        self.id = UUID()
        self.video = video
        self.index = index
        self.name = name
        self.voiceId = voiceId
        self.voiceProvider = voiceProvider
        self.createdAt = Date()
    }
}
```

- [ ] **Step 2: 写 SegmentDub 模型**

```swift
// MixCut/Models/SegmentDub.swift
import Foundation
import SwiftData

/// 某分镜在某版配音里的产物：改写台词 + 生成音频 + 对齐参数
@Model
final class SegmentDub {
    @Attribute(.unique) var id: UUID
    var variant: DubVariant?
    var segment: Segment?
    var rewrittenText: String = ""
    var audioFilePath: String?           // 未生成时 nil
    var audioDuration: Double = 0
    var atempoFactor: Double = 1.0       // 对齐变速系数（1.0=不变速）
    var freezePadFrames: Int = 0         // 末尾定格补帧数
    var statusRaw: String = "pending"    // SegmentDubStatus.rawValue

    var status: SegmentDubStatus {
        get { SegmentDubStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    init(variant: DubVariant?, segment: Segment?, rewrittenText: String = "") {
        self.id = UUID()
        self.variant = variant
        self.segment = segment
        self.rewrittenText = rewrittenText
    }
}
```

- [ ] **Step 3: 在主 Schema 注册（MixCutApp.swift 84-92）**

把第 84-92 行的 `Schema([...])` 改为加入两个新模型：

```swift
            let schema = Schema([
                Project.self,
                Video.self,
                Segment.self,
                MixStrategy.self,
                MixScheme.self,
                SchemeSegment.self,
                ProjectVideo.self,
                DubVariant.self,
                SegmentDub.self,
            ])
```

- [ ] **Step 4: 在内存兜底 Schema 注册（MixCutApp.swift 136-140）**

把 catch 块里第 136-140 行的 `Schema([...])` 同样补上：

```swift
            let schema = Schema([
                Project.self, Video.self, Segment.self,
                MixStrategy.self, MixScheme.self, SchemeSegment.self,
                ProjectVideo.self,
                DubVariant.self, SegmentDub.self,
            ])
```

- [ ] **Step 5: 编译确认通过**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: 重启并确认数据完整**

Run:
```bash
pkill -x MixCut; sleep 1; open /Users/menggang/Library/Developer/Xcode/DerivedData/MixCut-byytuggmhodpumcmwnwrtzwkmavr/Build/Products/Debug/MixCut.app
```
人工核对：应用正常启动、原有数据完整（新增两个空表的迁移不应清库）。

- [ ] **Step 7: 提交**

```bash
git add MixCut/Models/DubVariant.swift MixCut/Models/SegmentDub.swift MixCut/App/MixCutApp.swift
git commit -m "feat: 新增 DubVariant/SegmentDub 模型并注册到 Schema"
```

---

## Task 5: 可拖拽遮挡框组件 `SubtitleMaskOverlay`

自包含组件：在一个 9:16 预览区域上画一个半透明遮挡框，可上下拖动整体、可拖底部手柄改高度。运算全走 `SubtitleMaskRect`（Task 1）。

**Files:**
- Create: `MixCut/Views/SegmentLibrary/SubtitleMaskOverlay.swift`

**Interfaces:**
- Consumes: `SubtitleMaskRect`（Task 1）
- Produces: `struct SubtitleMaskOverlay: View`，初始化 `init(rect: Binding<SubtitleMaskRect>)`，铺满父容器（父容器负责给 9:16 尺寸）

- [ ] **Step 1: 写组件**

```swift
// MixCut/Views/SegmentLibrary/SubtitleMaskOverlay.swift
import SwiftUI
import MixCutCore

/// 9:16 预览上的可拖拽/可调高遮挡框。父容器需给定 9:16 尺寸。
struct SubtitleMaskOverlay: View {
    @Binding var rect: SubtitleMaskRect

    // 拖拽起始快照，避免累计误差
    @State private var dragStart: SubtitleMaskRect?

    private let handleHeight: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let px = rect.pixelRect(width: w, height: h)

            ZStack(alignment: .topLeading) {
                // 遮挡区域：半透明蓝框，可整体上下拖
                Rectangle()
                    .fill(Color.accentColor.opacity(0.28))
                    .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1.5))
                    .frame(width: px.width, height: px.height)
                    .offset(x: px.x, y: px.y)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let base = dragStart ?? rect
                                if dragStart == nil { dragStart = rect }
                                let dy = Double(value.translation.height) / Double(h)
                                rect = base.movedBy(dy: dy)
                            }
                            .onEnded { _ in dragStart = nil }
                    )

                // 底部调高手柄
                Capsule()
                    .fill(Color.white)
                    .overlay(Capsule().stroke(Color.accentColor, lineWidth: 1.5))
                    .frame(width: 40, height: handleHeight)
                    .position(x: px.x + px.width / 2,
                              y: px.y + px.height)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let base = dragStart ?? rect
                                if dragStart == nil { dragStart = rect }
                                let dH = Double(value.translation.height) / Double(h)
                                rect = base.resizedBy(dHeight: dH)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
        }
    }
}
```

- [ ] **Step 2: 编译确认通过**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 提交**

```bash
git add MixCut/Views/SegmentLibrary/SubtitleMaskOverlay.swift
git commit -m "feat: 新增可拖拽/调高的硬字幕遮挡框组件"
```

---

## Task 6: 分镜配音控件 `SegmentDubControls`

自包含控件：「保留原声」开关、「硬字幕遮挡」开关、遮挡样式选择、「应用到本视频所有分镜」按钮。通过闭包把动作交给上层（上层负责改 `Segment` 并落库），保持组件无持久化依赖、易复用。

**Files:**
- Create: `MixCut/Views/SegmentLibrary/SegmentDubControls.swift`

**Interfaces:**
- Consumes: `MaskStyle`（Task 2）
- Produces: `struct SegmentDubControls: View`，初始化：

```swift
init(
    isVoiceLocked: Binding<Bool>,
    hasHardSubtitle: Binding<Bool>,
    maskStyle: Binding<MaskStyle>,
    onApplyMaskToAll: @escaping () -> Void
)
```

- [ ] **Step 1: 写控件**

```swift
// MixCut/Views/SegmentLibrary/SegmentDubControls.swift
import SwiftUI

/// 分镜卡片上的配音相关控件。无持久化逻辑，动作经 binding/闭包上抛。
struct SegmentDubControls: View {
    @Binding var isVoiceLocked: Bool
    @Binding var hasHardSubtitle: Bool
    @Binding var maskStyle: MaskStyle
    let onApplyMaskToAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $isVoiceLocked) {
                Label("保留原声", systemImage: "lock.fill")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("明星出镜口播等不可替换的镜头，勾选后不参与改写/配音")

            Toggle(isOn: $hasHardSubtitle) {
                Label("硬字幕遮挡", systemImage: "rectangle.dashed")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("原片该分镜已有烧死的字幕，勾选后用遮挡条盖住")

            if hasHardSubtitle {
                Picker("样式", selection: $maskStyle) {
                    ForEach(MaskStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)

                Button(action: onApplyMaskToAll) {
                    Label("应用到本视频所有分镜", systemImage: "square.on.square")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
            }
        }
    }
}
```

- [ ] **Step 2: 编译确认通过**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 提交**

```bash
git add MixCut/Views/SegmentLibrary/SegmentDubControls.swift
git commit -m "feat: 新增分镜配音控件（保留原声/遮挡开关/样式/一键同步）"
```

---

## Task 7: 把控件与遮挡框嵌进分镜卡片

把 Task 5/6 的组件接到 `SegmentLibraryView` 的单个分镜卡片上：控件改 `Segment` 字段并落库；勾选「硬字幕遮挡」后，在该分镜 9:16 预览上叠加遮挡框；实现「应用到本视频所有分镜」。

> 实现前先通读 `MixCut/Views/SegmentLibrary/SegmentLibraryView.swift`，定位单个分镜卡片的子视图（含 9:16 缩略图/预览的那段）。遵守 CLAUDE.md「改动前列出该视图已有能力」SOP：多选/批量导出/批量删除/Equatable 优化/`isHovering`-`isSelected` 控制 BoundaryAdjustRow 显示等**不得破坏**。

**Files:**
- Modify: `MixCut/Views/SegmentLibrary/SegmentLibraryView.swift`

**Interfaces:**
- Consumes: `SubtitleMaskOverlay`（Task 5）、`SegmentDubControls`（Task 6）、`Segment.maskRect/maskStyle/isVoiceLocked/hasHardSubtitle`（Task 3）

- [ ] **Step 1: 在分镜卡片的 9:16 预览上叠加遮挡框**

在卡片里包住缩略图/预览的容器上加 `.overlay`（仅当 `segment.hasHardSubtitle`）。`modelContext` 用视图已有的 `@Environment(\.modelContext)`（若没有则在该视图加 `@Environment(\.modelContext) private var modelContext`）：

```swift
// 在分镜预览容器（9:16）上追加：
.overlay {
    if segment.hasHardSubtitle {
        SubtitleMaskOverlay(rect: Binding(
            get: { segment.maskRect },
            set: { segment.maskRect = $0; try? modelContext.save() }
        ))
    }
}
```

- [ ] **Step 2: 在卡片信息区追加配音控件**

在卡片文字信息区（语义类型/台词那块附近）追加：

```swift
SegmentDubControls(
    isVoiceLocked: Binding(
        get: { segment.isVoiceLocked },
        set: { segment.isVoiceLocked = $0; try? modelContext.save() }
    ),
    hasHardSubtitle: Binding(
        get: { segment.hasHardSubtitle },
        set: { segment.hasHardSubtitle = $0; try? modelContext.save() }
    ),
    maskStyle: Binding(
        get: { segment.maskStyle },
        set: { segment.maskStyle = $0; try? modelContext.save() }
    ),
    onApplyMaskToAll: { applyMaskToAllSegments(of: segment) }
)
```

- [ ] **Step 3: 实现「应用到本视频所有分镜」**

在 `SegmentLibraryView`（或卡片所在视图）内加方法。把当前分镜的遮挡矩形+样式+开关复制到同一视频的所有分镜：

```swift
/// 把 source 分镜的遮挡设置应用到同一视频的所有分镜
private func applyMaskToAllSegments(of source: Segment) {
    guard let video = source.video else { return }
    let rect = source.maskRect
    let style = source.maskStyle
    let hasSub = source.hasHardSubtitle
    for seg in video.segments {
        seg.hasHardSubtitle = hasSub
        seg.maskRect = rect
        seg.maskStyle = style
    }
    try? modelContext.save()
}
```

> 若卡片是独立子视图、拿不到 `video.segments` 与 `modelContext`，则把 `onApplyMaskToAll` 闭包逐层上抛到持有 `modelContext` 的 `SegmentLibraryView` 再执行此方法。

- [ ] **Step 4: 编译确认通过**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: 重启 + 截图人工核对**

Run:
```bash
pkill -x MixCut; sleep 1; open /Users/menggang/Library/Developer/Xcode/DerivedData/MixCut-byytuggmhodpumcmwnwrtzwkmavr/Build/Products/Debug/MixCut.app
```
进入「分镜素材库」，逐项肉眼验证（截图留证）：
1. 每张分镜卡出现「保留原声」「硬字幕遮挡」两个开关。
2. 打开「硬字幕遮挡」→ 出现样式选择 + 预览上出现遮挡框；预览仍是 **9:16**。
3. 拖动遮挡框可上下移、拖底部手柄可改高度，且不越出画面。
4. 点「应用到本视频所有分镜」→ 同视频其它分镜的遮挡框位置一致。
5. 切到别的视频再切回来，开关与遮挡位置被正确持久化。
6. **回归**：多选模式、批量导出/删除、台词双击编辑、卡片右键菜单、BoundaryAdjustRow 显隐 均正常。

- [ ] **Step 6: 提交**

```bash
git add MixCut/Views/SegmentLibrary/SegmentLibraryView.swift
git commit -m "feat: 分镜卡片接入保留原声/硬字幕遮挡控件与可拖拽遮挡框"
```

---

## 自查（spec 覆盖 / 占位符 / 类型一致性）

- **spec 覆盖**：本计划覆盖 spec §4.1（Segment 新字段）、§4.2 `DubVariant`、§4.3 `SegmentDub`、§9 分镜素材库 UI（保留原声开关、遮挡框拖拽、一键同步）。spec 其余章节（§5 改写、§6 TTS/对齐、§7 字幕、§8 导出、DubbingView 编排）属 P2-P5，不在本计划。
- **占位符**：无 TBD/TODO；每个代码步骤均给出完整代码。
- **类型一致性**：`SubtitleMaskRect`(Task1) 被 Segment.maskRect(Task3)/SubtitleMaskOverlay(Task5) 一致使用；`MaskStyle`(Task2) 被 Segment.maskStyle(Task3)/SegmentDubControls(Task6) 一致使用；`DubVariantStatus`/`SegmentDubStatus`(Task2) 被模型(Task4) 一致使用；模型字段名与 spec §4 一致。
