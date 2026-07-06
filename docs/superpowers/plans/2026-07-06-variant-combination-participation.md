# 变体「参与排列组合」逐项开关 Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给配音/文案变体加"是否参与导出组合"的逐项多选框 + "原版是否参与"开关，让**所有配音导出路径**（方案笛卡尔积 + 单/批量导出）只导出被勾选的版本，收敛组合数量。

**Architecture:** 纯组合/展开逻辑在 `Sources/MixCutCore`（`VariantCombinationGenerator`、`SegmentExportExpander`，Swift Testing 可脱 Xcode 跑）——把"原版是否参与"从全局参数改为**逐格/逐源**字段；SwiftData 层 `SegmentDub`/`Segment` 加持久化布尔 + 派生单一真源 `combinationDubVariants`/`combinationSlotCount`；各导出计数点与变体池 UI 接上。

**Tech Stack:** Swift 5.10 / SwiftUI / SwiftData / macOS 14；Swift Testing（MixCutCore）；xcodebuild（app 编译，SwiftData 宏需 Xcode）。

**参考 spec：** `docs/superpowers/specs/2026-07-06-variant-combination-participation-design.md`

---

## ⚠️ 执行前必读（项目铁律）

1. **不自动 git 提交**：各 Task 末尾检查点是**编译/测试验证**，不含 git 提交；提交时机由用户定。在 feature 分支上做（当前分支 `feature/shot-level-prompt-edit`，可继续或新开）。
2. **自己先测**：改 UI 后必须 编译 → `pkill -x MixCut; open <app>` → 截图/自测；不可自测的列人工验收项。
3. **MixCutCore 测试**：`cd /Users/menggang/www/Mixed_cut && swift test --filter <Suite>`（秒级，无需 Xcode）。
4. **app 编译**：`xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build`。
5. **Schema 变更**：新增两个带默认值的布尔，additive；库当前已清空，风险为零；仍建议改前 `cp ~/Library/Application\ Support/MixCut/MixCut.store{,.bak}`（如库不存在则跳过）。
6. **勿破坏既有功能**：变体池的生成/试听/重生成/删除/锁定提示；方案详情单槽下拉（`selectedSegmentDubId`）；单分镜批量导出命名。

## 规则（单一，贯穿所有导出路径）

一个分镜实际参与/导出的"版本集合"：
- `isVoiceLocked` → 仅原版（×1，覆盖一切勾选）；
- 否则 = `(原版 if originalParticipatesInCombination) + (participatesInCombination==true 的已生成变体)`；
- 若为空 → 兜底仅原版（×1）。
默认：原版勾选(true)、变体不勾(false)、全局作用域。

---

## 文件结构

**改（MixCutCore 纯逻辑 + 测试）**
- `Sources/MixCutCore/VariantCombinationGenerator.swift` — `SlotOptions` 加 `includeOriginal`；`generate` 去掉全局 `includeOriginal`
- `Tests/MixCutCoreTests/VariantCombinationGeneratorTests.swift` — 更新到新签名 + 新用例
- `Sources/MixCutCore/SegmentExportExpander.swift` — `SegmentExportSource` 加 `includeOriginal`；`expand` 遵循规则 + 兜底
- `Tests/MixCutCoreTests/SegmentExportExpanderTests.swift` — 更新到新签名 + 新用例

**改（SwiftData 模型）**
- `MixCut/Models/SegmentDub.swift` — 加 `participatesInCombination: Bool = false`
- `MixCut/Models/Segment.swift` — 加 `originalParticipatesInCombination: Bool = true` + 派生 `combinationDubVariants`/`combinationSlotCount`

**改（导出接线）**
- `MixCut/Services/Export/DubExportService.swift` — `SchemeComboPlanner.plan`/`feasibleCount`
- `MixCut/Services/…/VariantBatchExportService.swift` — `VariantExportInput.from`
- `MixCut/App/DebugSelfTest.swift` — `:48-49` 新 `SlotOptions`、`:123` 计数
- `MixCut/Views/Schemes/SchemeDetailView.swift` — `slotFactors`（`:242-247`）

**改（UI）**
- `MixCut/Views/SegmentLibrary/SegmentVariantInspector.swift` — 每变体多选框 + 原版多选框

> 无新增文件 → 无需改 xcodeproj。

---

## Phase 1：MixCutCore 纯逻辑（TDD，`swift test`）

### Task 1: VariantCombinationGenerator 逐格 includeOriginal

**Files:**
- Modify: `Sources/MixCutCore/VariantCombinationGenerator.swift`
- Test: `Tests/MixCutCoreTests/VariantCombinationGeneratorTests.swift`

- [ ] **Step 1: 更新测试到新签名 + 加新用例（先让它编译失败）**

把测试文件整体替换为（旧用例保留语义、补新用例）：

```swift
import Testing
import Foundation
@testable import MixCutCore

@Suite("VariantCombinationGenerator")
struct VariantCombinationGeneratorTests {

    private func ids(_ n: Int) -> [UUID] { (0..<n).map { _ in UUID() } }
    private func slot(_ locked: Bool, _ orig: Bool, _ dubs: [UUID]) -> SlotOptions {
        SlotOptions(isLocked: locked, includeOriginal: orig, dubIds: dubs)
    }

    @Test("仅变体（不含原版）：两槽各2变体 feasible=4")
    func twoSlotsTwoVariantsNoOriginal() {
        let r = VariantCombinationGenerator.generate(
            slots: [slot(false, false, ids(2)), slot(false, false, ids(2))], limit: 2)
        #expect(r.feasibleCount == 4)
        #expect(r.combinations.count == 2)
        #expect(r.truncated == true)
        #expect(r.combinations[0] != r.combinations[1])
    }

    @Test("锁定槽恒为 nil（忽略 includeOriginal/变体）")
    func lockedSlotAlwaysNil() {
        let r = VariantCombinationGenerator.generate(
            slots: [slot(true, true, ids(2)), slot(false, false, ids(2))], limit: 10)
        #expect(r.feasibleCount == 2)
        #expect(r.combinations.allSatisfy { $0[0] == nil })
    }

    @Test("原版参与+2变体=3档；仅变体不含原版=2档；混合笛卡尔积=3×2=6")
    func perSlotOriginalMix() {
        let r = VariantCombinationGenerator.generate(
            slots: [slot(false, true, ids(2)), slot(false, false, ids(2))], limit: 100)
        #expect(r.feasibleCount == 6)             // (原+2) × (2)
        #expect(r.combinations.count == 6)
        // 第1槽出现过 nil（原版参与），第2槽从不为 nil（不含原版且有变体）
        #expect(r.combinations.contains { $0[0] == nil })
        #expect(r.combinations.allSatisfy { $0[1] != nil })
    }

    @Test("兜底：不含原版且无变体 → 该槽恒原声(nil)，×1")
    func fallbackEmptyToOriginal() {
        let r = VariantCombinationGenerator.generate(
            slots: [slot(false, false, []), slot(false, true, ids(2))], limit: 10)
        #expect(r.feasibleCount == 3)             // 1(兜底原声) × 3(原+2)
        #expect(r.combinations.allSatisfy { $0[0] == nil })
    }

    @Test("原版参与：每镜=原+2变体=3选项，4镜→3^4=81 且含全原声一条")
    func includeOriginalFullProduct() {
        let slots = (0..<4).map { _ in slot(false, true, ids(2)) }
        let r = VariantCombinationGenerator.generate(slots: slots, limit: 1000)
        #expect(r.feasibleCount == 81)
        #expect(r.combinations.count == 81)
        #expect(r.combinations.contains { $0.allSatisfy { $0 == nil } })
        let keys = r.combinations.map { $0.map { $0?.uuidString ?? "o" }.joined(separator: ",") }
        #expect(Set(keys).count == 81)
    }

    @Test("全锁定：只1条全 nil")
    func allLocked() {
        let r = VariantCombinationGenerator.generate(
            slots: [slot(true, true, ids(2)), slot(true, true, ids(2))], limit: 10)
        #expect(r.feasibleCount == 1)
        #expect(r.combinations == [[nil, nil]])
        #expect(r.truncated == false)
    }

    @Test("limit 大于 feasible 不截断")
    func limitExceedsFeasible() {
        let r = VariantCombinationGenerator.generate(slots: [slot(false, false, ids(2))], limit: 99)
        #expect(r.feasibleCount == 2)
        #expect(r.combinations.count == 2)
        #expect(r.truncated == false)
    }

    @Test("limit<=0 返回空")
    func zeroLimit() {
        let r = VariantCombinationGenerator.generate(slots: [slot(false, true, ids(2))], limit: 0)
        #expect(r.combinations.isEmpty)
    }
}
```

- [ ] **Step 2: 跑测试确认失败** — `swift test --filter VariantCombinationGenerator`（编译失败：`SlotOptions` 无 `includeOriginal`、`generate` 仍要 `includeOriginal` 参数）

- [ ] **Step 3: 改实现** `Sources/MixCutCore/VariantCombinationGenerator.swift`：
  - `SlotOptions` 改为：
```swift
public struct SlotOptions: Equatable, Sendable {
    public let isLocked: Bool
    public let includeOriginal: Bool   // 该槽原版(nil)是否作为一个可选项
    public let dubIds: [UUID]
    public init(isLocked: Bool, includeOriginal: Bool, dubIds: [UUID]) {
        self.isLocked = isLocked
        self.includeOriginal = includeOriginal
        self.dubIds = dubIds
    }
}
```
  - `generate` 去掉全局 `includeOriginal` 参数，改逐格：
```swift
public static func generate(slots: [SlotOptions], limit: Int) -> CombinationResult {
    let choices: [[UUID?]] = slots.map { slot in
        if slot.isLocked { return [nil] }
        let variants = slot.dubIds.sorted { $0.uuidString < $1.uuidString }.map { Optional($0) }
        let withOriginal = (slot.includeOriginal ? [UUID?.none] : []) + variants
        return withOriginal.isEmpty ? [nil] : withOriginal   // 兜底原声
    }
    // …以下 feasible/枚举逻辑保持不变…
}
```
  （`feasibleCap`、枚举循环、`CombinationResult` 均不变。）

- [ ] **Step 4: 跑测试确认通过** — `swift test --filter VariantCombinationGenerator` → 全 PASS

- [ ] **Step 5: 检查点** — 全绿；不 git 提交。

---

### Task 2: SegmentExportExpander 遵循参与规则

**Files:**
- Modify: `Sources/MixCutCore/SegmentExportExpander.swift`
- Test: `Tests/MixCutCoreTests/SegmentExportExpanderTests.swift`

- [ ] **Step 1: 更新测试到新签名 + 新用例（先失败）**

```swift
import Testing
@testable import MixCutCore

@Suite("SegmentExportExpander")
struct SegmentExportExpanderTests {
    private func src(_ locked: Bool, _ orig: Bool, _ variants: [VariantRef], seq: Int = 1, name: String = "v") -> SegmentExportSource {
        SegmentExportSource(segmentKey: "s\(seq)", sequenceNumber: seq, videoName: name,
                            isVoiceLocked: locked, includeOriginal: orig, variants: variants)
    }
    private let a = VariantRef(dubKey: "a", textVariantIndex: 0)
    private let b = VariantRef(dubKey: "b", textVariantIndex: 1)

    @Test("原版参与 + 2 变体 → 3 条，命名正确")
    func originalPlusTwo() {
        let out = SegmentExportExpander.expand([src(false, true, [a, b], seq: 2, name: "clip")])
        #expect(out.map(\.fileName) == ["2_clip.mp4", "2_clip_A.mp4", "2_clip_B.mp4"])
        #expect(out.map(\.dubKey) == [nil, "a", "b"])
    }

    @Test("仅变体不含原版 → 只出变体")
    func variantsOnly() {
        let out = SegmentExportExpander.expand([src(false, false, [a, b])])
        #expect(out.map(\.dubKey) == ["a", "b"])
        #expect(out.allSatisfy { $0.dubKey != nil })
    }

    @Test("不含原版且无变体 → 兜底仅原版")
    func fallbackOriginal() {
        let out = SegmentExportExpander.expand([src(false, false, [])])
        #expect(out.count == 1)
        #expect(out[0].dubKey == nil)
    }

    @Test("锁定 → 仅原版，忽略 includeOriginal/变体")
    func lockedOnlyOriginal() {
        let out = SegmentExportExpander.expand([src(true, false, [a])])
        #expect(out.count == 1)
        #expect(out[0].dubKey == nil)
    }

    @Test("变体乱序按 textVariantIndex 升序产出 A/B")
    func sorted() {
        let out = SegmentExportExpander.expand([src(false, true,
            [VariantRef(dubKey: "second", textVariantIndex: 1),
             VariantRef(dubKey: "first", textVariantIndex: 0)], seq: 3)])
        #expect(out.map(\.fileName) == ["3_v.mp4", "3_v_A.mp4", "3_v_B.mp4"])
        #expect(out.map(\.dubKey) == [nil, "first", "second"])
    }

    @Test("字母映射") func letterMapping() {
        #expect(SegmentExportExpander.letter(for: 0) == "A")
        #expect(SegmentExportExpander.letter(for: 26) == "V26")
    }
}
```

- [ ] **Step 2: 跑失败** — `swift test --filter SegmentExportExpander`（`SegmentExportSource` 无 `includeOriginal`）

- [ ] **Step 3: 改实现** `Sources/MixCutCore/SegmentExportExpander.swift`：
  - `SegmentExportSource` 加字段：
```swift
public let includeOriginal: Bool
public init(segmentKey: String, sequenceNumber: Int, videoName: String,
            isVoiceLocked: Bool, includeOriginal: Bool, variants: [VariantRef]) {
    self.segmentKey = segmentKey; self.sequenceNumber = sequenceNumber
    self.videoName = videoName; self.isVoiceLocked = isVoiceLocked
    self.includeOriginal = includeOriginal; self.variants = variants
}
```
  - `expand` 改为：
```swift
public static func expand(_ sources: [SegmentExportSource]) -> [SegmentExportPlanItem] {
    var out: [SegmentExportPlanItem] = []
    for s in sources {
        let sorted = s.variants.sorted { $0.textVariantIndex < $1.textVariantIndex }
        let wantOriginal = s.isVoiceLocked || s.includeOriginal
        let variantItems = s.isVoiceLocked ? [] : sorted
        // 兜底：既不含原版也无变体 → 仅原版
        let emitOriginal = wantOriginal || variantItems.isEmpty
        if emitOriginal {
            out.append(SegmentExportPlanItem(segmentKey: s.segmentKey, dubKey: nil,
                fileName: "\(s.sequenceNumber)_\(s.videoName).mp4"))
        }
        for v in variantItems {
            out.append(SegmentExportPlanItem(segmentKey: s.segmentKey, dubKey: v.dubKey,
                fileName: "\(s.sequenceNumber)_\(s.videoName)_\(letter(for: v.textVariantIndex)).mp4"))
        }
    }
    return out
}
```
  （`letter(for:)` 不变。）

- [ ] **Step 4: 跑通过** — `swift test --filter SegmentExportExpander` → 全 PASS
- [ ] **Step 5: 全套回归** — `swift test`（确认没碰坏其它 MixCutCore 套件）
- [ ] **Step 6: 检查点**

---

## Phase 2：SwiftData 模型

### Task 3: 参与字段 + 派生单一真源

**Files:**
- Modify: `MixCut/Models/SegmentDub.swift`（加字段）
- Modify: `MixCut/Models/Segment.swift`（加字段 + 派生属性）

- [ ] **Step 1: `SegmentDub` 加字段** — 在字段区（`:8-25` 附近）加：
```swift
/// 是否参与导出组合（默认不参与，opt-in）
var participatesInCombination: Bool = false
```

- [ ] **Step 2: `Segment` 加字段 + 派生** — 加：
```swift
/// 原版是否参与导出组合（默认参与）
var originalParticipatesInCombination: Bool = true
```
并在 `extension Segment`（与 `effectiveDubVariants` 同处，`SegmentDub.swift:47-60` 附近或 Segment.swift 内均可）加：
```swift
/// 参与导出组合的变体（= effectiveDubVariants 里勾选参与的）。所有导出路径的单一真源。
var combinationDubVariants: [SegmentDub] {
    effectiveDubVariants.filter { $0.participatesInCombination }
}
/// 该分镜参与组合的"档数"（含锁定/兜底语义）。
var combinationSlotCount: Int {
    if isVoiceLocked { return 1 }
    let base = originalParticipatesInCombination ? 1 : 0
    return max(1, base + combinationDubVariants.count)   // 兜底 ≥1
}
```
> 不改 `effectiveDubVariants` 本身（仍返回全部已生成变体，供变体池展示/单槽下拉用）。

- [ ] **Step 3: 加进 Schema? 不需要**（未新增 @Model，仅加字段；SwiftData 自动纳入。库已清空无迁移。）

- [ ] **Step 4: 编译** — `xcodebuild … Debug build` → BUILD SUCCEEDED
- [ ] **Step 5: 检查点**

---

## Phase 3：接入所有导出/计数路径

### Task 4: 方案笛卡尔积（SchemeComboPlanner）

**Files:** Modify `MixCut/Services/Export/DubExportService.swift`（`SchemeComboPlanner`，`:112-140`）

- [ ] **Step 1: `feasibleCount` 改用单一真源**（`:112-117`）：
```swift
static func feasibleCount(for scheme: MixScheme) -> Int {
    scheme.orderedSegments.reduce(1) { acc, ss in
        guard let seg = ss.segment else { return acc }
        return acc * seg.combinationSlotCount
    }
}
```
- [ ] **Step 2: `plan` 的 `SlotOptions` 映射改逐格**（`:123-127`）：
```swift
SlotOptions(
    isLocked: seg.isVoiceLocked,
    includeOriginal: seg.isVoiceLocked ? true : seg.originalParticipatesInCombination,
    dubIds: seg.isVoiceLocked ? [] : seg.combinationDubVariants.map(\.id)
)
```
并把 `generate(..., includeOriginal: true)` 调用改为 `generate(slots:limit:)`（去掉全局参数，`:127`）。
- [ ] **Step 3: 文件名后缀查找**（`:134` 用 dubId 找变体名）仍从 `effectiveDubVariants` 查即可（combinationDubVariants ⊆ effectiveDubVariants，查得到）。确认不报错。
- [ ] **Step 4: 编译** → SUCCEEDED
- [ ] **Step 5: 检查点**（DebugSelfTest 有 3 处：`:48-49`、`:51`、`:123`）

### Task 5: 单/批量导出（VariantExportInput.from）

**Files:** Modify `MixCut/Services/…/VariantBatchExportService.swift`（`VariantExportInput.from`，`:41` 附近）

- [ ] **Step 1: 构造 `SegmentExportSource` 时改用参与集**：
```swift
SegmentExportSource(
    segmentKey: …, sequenceNumber: …, videoName: …,
    isVoiceLocked: seg.isVoiceLocked,
    includeOriginal: seg.originalParticipatesInCombination,
    variants: seg.combinationDubVariants.map { VariantRef(dubKey: $0.id.uuidString, textVariantIndex: $0.textVariantIndex) }
)
```
（`dubKey` 用现有构造里相同的键；照原代码 `variants` 原本怎么取 dubKey 就怎么取，只把来源从 `effectiveDubVariants` 换成 `combinationDubVariants` 并补 `includeOriginal`。）
- [ ] **Step 2: 编译** → SUCCEEDED
- [ ] **Step 3: 检查点**

### Task 6: DebugSelfTest 同步（否则编译失败）

**Files:** Modify `MixCut/App/DebugSelfTest.swift`

- [ ] **Step 1:** `:48-49` 的 `SlotOptions(isLocked:dubIds:)` → 补 `includeOriginal:`（调试语义用 `true` 即可）。
- [ ] **Step 2:** `:51` 的 `generate(slots:limit:256, includeOriginal: true)` → 删掉 `includeOriginal: true` 实参（全局参数已移除，改为逐格；此处槽已在 `:48-49` 设 `includeOriginal`）。
- [ ] **Step 3:** `:123` 的 `1 + seg.effectiveDubVariants.count` → 改 `seg.combinationSlotCount`。
- [ ] **Step 4: 编译** → SUCCEEDED（此 Task 主要是修编译中断点）
- [ ] **Step 4: 检查点**

### Task 7: 计数显示跟随收敛

**Files:** Modify `MixCut/Views/Schemes/SchemeDetailView.swift`（`slotFactors` `:242-247`）

- [ ] **Step 1:** `slotFactors` 每格因子从 `1 + seg.effectiveDubVariants.count`（锁定×1）改为 `seg.combinationSlotCount`。"可生成 N 组合"提示随之正确。
- [ ] **Step 2:** `ExportView.totalComboCount`（`:722-726`）调用 `feasibleCount`，自动收敛——只需**校验**数值正确，无需改代码。`BatchExportSheet` 计数走 `SegmentExportExpander`，同样自动收敛，校验即可。
- [ ] **Step 3: 编译** → SUCCEEDED
- [ ] **Step 4: 检查点**

---

## Phase 4：变体池 UI 勾选

### Task 8: SegmentVariantInspector 多选框

**Files:** Modify `MixCut/Views/SegmentLibrary/SegmentVariantInspector.swift`

- [ ] **Step 1: 先读现状** — 通读该文件，一句话列出现有能力（矩阵：行=改写版/列=音色；每格 生成/试听/重生成/删除；锁定提示）。改动只加勾选，不动这些。
- [ ] **Step 2: 每个已生成变体格加多选框** — 勾选框**只对 `segment.effectiveDubVariants` 里的 dub 渲染**（不是全部 `segmentDubs`），从结构上避免与 `combinationDubVariants`(过滤 effectiveDubVariants) 的去重错位——因 effectiveDubVariants 已按 `textVariantIndex` 去重、优先保留克隆原声那条；勾到"非 effective"的重复条不会生效。在 `cell`（`:322`）/`versionCard`（`:189`）里对这些 dub 显示 `Toggle`/checkbox 绑定 `dub.participatesInCombination`，setter 里 `try? modelContext.save()`。
- [ ] **Step 3: 加「原版参与组合」固定多选框** — 在矩阵顶部（表头处）放一个 checkbox 绑定 `segment.originalParticipatesInCombination` + 保存。
- [ ] **Step 4: 锁定态处理** — `segment.isVoiceLocked` 时两类勾选框 `.disabled(true)`，复用现有锁定提示区（`:99-102`）文案补"已锁原声，不参与组合"。
- [ ] **Step 5:（可选）实时档数** — 池底部显示 `segment.combinationSlotCount`（"当前参与 N 档"）。
- [ ] **Step 6: 编译 + 重启 + 截图自测** — `xcodebuild … build` → `pkill -x MixCut; open <app>` → 进分镜库选一个有变体的分镜（需先有配音变体；若库中无，可在有变体的分镜上验证；无变体则至少验证"原版参与"框与锁定禁用）→ 截图确认勾选框渲染、可勾、锁定禁用。
- [ ] **Step 7: 回归自测** — 生成/试听/重生成/删除、锁定提示仍正常。
- [ ] **Step 8: 检查点**

---

## Phase 5：端到端验收

### Task 9: 全链路校验 + 人工验收清单

- [ ] **Step 1: MixCutCore 全绿** — `swift test`（Task1/2 + 全套无回归）。
- [ ] **Step 2: app 编译 + 启动** — build → 重启 → 无崩。
- [ ] **Step 3: 人工验收（app 内，需有配音变体的分镜）**
  1. 变体池勾/取消变体、切换"原版参与" → 方案详情"可生成 N 组合"实时变化、数值 = ∏ combinationSlotCount。
  2. 某分镜只勾原版+1 变体（共 2）→ 方案该格 2 档；批量/单分镜导出该分镜只出这 2 条（文件数正确）。
  3. 全不勾（原版+变体都取消）→ 该分镜仍出原版、方案不断档、批量导出出 1 条原版。
  4. 锁定分镜 → 勾选禁用、恒 1 档。
  5. 方案笛卡尔积导出条数 = 收敛后的 feasibleCount，不再爆炸。
  6. 既有：生成/试听/重生成/删除、单槽下拉预览、单分镜导出命名（base/_A/_B）不回归。
- [ ] **Step 4: 汇总** — 列"已自测通过"与"需用户复测"清单交用户。

---

## 附：关键复用/改动点对照

| 需求 | 位置 |
|---|---|
| 笛卡尔积引擎 | `Sources/MixCutCore/VariantCombinationGenerator.swift` |
| 单/批量展开 | `Sources/MixCutCore/SegmentExportExpander.swift` |
| 方案组合入口/计数 | `DubExportService.swift`(SchemeComboPlanner `:112-140`) |
| 批量导出构造 | `VariantBatchExportService.swift`(VariantExportInput.from `:41`) |
| 调试计数 | `DebugSelfTest.swift:48-49,123` |
| 方案详情计数 | `SchemeDetailView.swift:242-247` |
| 变体池 UI | `SegmentVariantInspector.swift`(cell `:322` / versionCard `:189` / 锁定提示 `:99-102`) |
| 现有变体读取（不改） | `Segment.effectiveDubVariants`(`SegmentDub.swift:47-60`) |
