# 自定义叙事结构 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 MixCut「混剪方案」区新增「自定义叙事结构」：用户用系统标签定义有序段位，AI 在每段候选分镜里挑片生成多变体，经台词连贯性校验后只保留通过的。

**Architecture:** 纯匹配/校验/命名逻辑抽到零依赖的 SPM 库 `MixCutCore`（字符串标签驱动，可 `swift test`）；App 在边界把 `Segment`/`SemanticType` 映射为 `SegmentDescriptor`/rawValue。结构复用现有 `MixStrategy`(+`isNarrativeTemplate`+`narrativeSlotsData`) 与 `MixScheme`，生成复用 `SchemeGenerationService` 的批量/去重/解析能力，变体详情零改动复用 `SchemeDetailView`。

**Tech Stack:** Swift 5.10 / SwiftUI / SwiftData / Swift Testing / SPM + Xcode 双构建。

设计依据：`docs/superpowers/specs/2026-06-04-custom-narrative-structure-design.md`

---

## 文件结构

**新增（纯逻辑库 + 测试，走 `swift test`）：**
- `Sources/MixCutCore/NarrativeModels.swift` — `NarrativeSlot`、`SegmentDescriptor` 值类型
- `Sources/MixCutCore/NarrativeStructureEngine.swift` — 纯函数：候选池/上限/校验/命名/Top-N
- `Tests/MixCutCoreTests/NarrativeStructureEngineTests.swift` — 单元测试
- `Package.swift` — 加 `MixCutCore` library target + `MixCutCoreTests` test target；`MixCut` 依赖 `MixCutCore`

**修改（App，走 xcodebuild + 真机验证）：**
- `MixCut/Models/MixStrategy.swift` — +`isNarrativeTemplate`、+`narrativeSlotsData` + 计算属性 `narrativeSlots`
- `MixCut/Services/SchemeGeneration/SchemeGenerationService.swift` — +`generateNarrativeVariants(...)`：组织"段→候选池"目录、构建提示词、调用 AI、用 `MixCutCore` 做程序侧合法性过滤
- `MixCut/ViewModels/SchemeViewModel.swift` — +创建/编辑叙事结构、生成、侧边栏分组数据
- `MixCut/Views/Schemes/SchemeListView.swift` — +"自定义结构"分组与三级展示、编辑器入口
- `MixCut/Views/Schemes/NarrativeStructureEditorView.swift`（新增）— 段位编辑器

---

## Task 0: 建 MixCutCore 库 + 测试 target

**Files:**
- Modify: `Package.swift`
- Create: `Sources/MixCutCore/Placeholder.swift`
- Create: `Tests/MixCutCoreTests/SmokeTest.swift`

- [ ] **Step 1: 改 Package.swift 加 library + test target，App 依赖 core**

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MixCut",
    platforms: [.macOS(.v14)],
    dependencies: [],
    targets: [
        .target(
            name: "MixCutCore",
            dependencies: [],
            path: "Sources/MixCutCore"
        ),
        .executableTarget(
            name: "MixCut",
            dependencies: ["MixCutCore"],
            path: "MixCut",
            resources: [.copy("Resources/Prompts")]
        ),
        .testTarget(
            name: "MixCutCoreTests",
            dependencies: ["MixCutCore"],
            path: "Tests/MixCutCoreTests"
        ),
    ]
)
```

- [ ] **Step 2: 占位文件让 target 非空**

`Sources/MixCutCore/Placeholder.swift`:
```swift
// MixCutCore：纯逻辑库（零 SwiftData/UI 依赖，可独立 swift test）
enum MixCutCorePlaceholder {}
```

`Tests/MixCutCoreTests/SmokeTest.swift`:
```swift
import Testing
@testable import MixCutCore

@Test func smoke() {
    #expect(Bool(true))
}
```

- [ ] **Step 3: 跑 swift test 确认 target 成立**

Run: `swift test 2>&1 | tail -5`
Expected: 编译通过，`smoke` 测试 PASS。

- [ ] **Step 4: 确认 Xcode App 构建仍正常（双构建不破）**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`。
注：若 xcodeproj 未自动链接 `MixCutCore`，在 Xcode 里给 MixCut target 的 "Frameworks, Libraries" 加上 `MixCutCore`（package product），再重跑本步直到 SUCCEEDED。

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/MixCutCore Tests/MixCutCoreTests
git commit -m "chore: 新增 MixCutCore 纯逻辑库 + 测试 target"
```

---

## Task 1: 值类型 NarrativeSlot / SegmentDescriptor

**Files:**
- Create: `Sources/MixCutCore/NarrativeModels.swift`
- Delete: `Sources/MixCutCore/Placeholder.swift`

- [ ] **Step 1: 写值类型**

`Sources/MixCutCore/NarrativeModels.swift`:
```swift
import Foundation

/// 叙事结构中的一段：顺序 + 一组标签（SemanticType 的 rawValue 字符串）
public struct NarrativeSlot: Codable, Equatable, Sendable {
    public var order: Int
    public var tags: [String]
    public init(order: Int, tags: [String]) {
        self.order = order
        self.tags = tags
    }
}

/// 分镜的轻量描述（供匹配/校验，不依赖 SwiftData）
public struct SegmentDescriptor: Equatable, Sendable {
    public let id: UUID
    public let tags: [String]
    public let text: String
    public let duration: Double
    public let quality: Double
    public init(id: UUID, tags: [String], text: String, duration: Double, quality: Double) {
        self.id = id
        self.tags = tags
        self.text = text
        self.duration = duration
        self.quality = quality
    }
}
```

- [ ] **Step 2: 删占位文件**

Run: `rm Sources/MixCutCore/Placeholder.swift`

- [ ] **Step 3: 编译确认**

Run: `swift build 2>&1 | tail -3`
Expected: 编译通过。

- [ ] **Step 4: Commit**

```bash
git add Sources/MixCutCore/NarrativeModels.swift
git rm Sources/MixCutCore/Placeholder.swift
git commit -m "feat(core): 叙事结构值类型 NarrativeSlot/SegmentDescriptor"
```

---

## Task 2: structureName（二级目录名拼接）

**Files:**
- Create: `Sources/MixCutCore/NarrativeStructureEngine.swift`
- Test: `Tests/MixCutCoreTests/NarrativeStructureEngineTests.swift`

- [ ] **Step 1: 写失败测试**

`Tests/MixCutCoreTests/NarrativeStructureEngineTests.swift`:
```swift
import Testing
import Foundation
@testable import MixCutCore

@Test func structureName_joinsTagsByDotAndSlash() {
    let slots = [
        NarrativeSlot(order: 0, tags: ["痛点"]),
        NarrativeSlot(order: 1, tags: ["产品方案"]),
        NarrativeSlot(order: 2, tags: ["效果展示", "信任背书"]),
        NarrativeSlot(order: 3, tags: ["行动号召"]),
    ]
    #expect(NarrativeStructureEngine.structureName(for: slots)
        == "痛点 · 产品方案 · 效果展示/信任背书 · 行动号召")
}

@Test func structureName_sortsByOrder() {
    let slots = [
        NarrativeSlot(order: 2, tags: ["C"]),
        NarrativeSlot(order: 0, tags: ["A"]),
        NarrativeSlot(order: 1, tags: ["B"]),
    ]
    #expect(NarrativeStructureEngine.structureName(for: slots) == "A · B · C")
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter structureName 2>&1 | tail -8`
Expected: 编译失败 / 找不到 `NarrativeStructureEngine`。

- [ ] **Step 3: 写最小实现**

`Sources/MixCutCore/NarrativeStructureEngine.swift`:
```swift
import Foundation

public enum NarrativeStructureEngine {
    /// 二级目录名：各段按 order 排序，段内多标签用 "/"，段间用 " · "
    public static func structureName(for slots: [NarrativeSlot]) -> String {
        slots.sorted { $0.order < $1.order }
            .map { $0.tags.joined(separator: "/") }
            .joined(separator: " · ")
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter structureName 2>&1 | tail -5`
Expected: 2 个测试 PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/MixCutCore/NarrativeStructureEngine.swift Tests/MixCutCoreTests/NarrativeStructureEngineTests.swift
git commit -m "feat(core): structureName 标签拼接二级目录名"
```

---

## Task 3: candidatePool（候选池=标签并集匹配）

**Files:**
- Modify: `Sources/MixCutCore/NarrativeStructureEngine.swift`
- Test: `Tests/MixCutCoreTests/NarrativeStructureEngineTests.swift`

- [ ] **Step 1: 写失败测试（追加）**

追加到 `NarrativeStructureEngineTests.swift`:
```swift
private func seg(_ id: String, _ tags: [String], q: Double = 1, d: Double = 1) -> SegmentDescriptor {
    SegmentDescriptor(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(id)")!,
                      tags: tags, text: "t\(id)", duration: d, quality: q)
}

@Test func candidatePool_matchesUnionOfTags() {
    let segs = [
        seg("01", ["痛点"]),
        seg("02", ["产品方案"]),
        seg("03", ["痛点", "过渡"]),
        seg("04", ["行动号召"]),
    ]
    let slot = NarrativeSlot(order: 0, tags: ["痛点", "产品方案"])
    let pool = NarrativeStructureEngine.candidatePool(for: slot, in: segs)
    #expect(Set(pool.map(\.id)) == Set([seg("01").id, seg("02").id, seg("03").id]))
}

@Test func candidatePool_emptyWhenNoTagOverlap() {
    let segs = [seg("01", ["痛点"])]
    let slot = NarrativeSlot(order: 0, tags: ["行动号召"])
    #expect(NarrativeStructureEngine.candidatePool(for: slot, in: segs).isEmpty)
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter candidatePool 2>&1 | tail -8`
Expected: 找不到 `candidatePool`，编译失败。

- [ ] **Step 3: 写实现（追加到 enum）**

```swift
    /// 候选池：分镜标签与该段标签有交集（并集匹配）即入选
    public static func candidatePool(for slot: NarrativeSlot, in segments: [SegmentDescriptor]) -> [SegmentDescriptor] {
        let slotTags = Set(slot.tags)
        return segments.filter { !slotTags.isDisjoint(with: Set($0.tags)) }
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter candidatePool 2>&1 | tail -5`
Expected: 2 个测试 PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/MixCutCore/NarrativeStructureEngine.swift Tests/MixCutCoreTests/NarrativeStructureEngineTests.swift
git commit -m "feat(core): candidatePool 标签并集匹配候选池"
```

---

## Task 4: topCandidates（按质量/时长截断 Top-N）

**Files:**
- Modify: `Sources/MixCutCore/NarrativeStructureEngine.swift`
- Test: `Tests/MixCutCoreTests/NarrativeStructureEngineTests.swift`

- [ ] **Step 1: 写失败测试（追加）**

```swift
@Test func topCandidates_sortsByQualityThenDurationAndCaps() {
    let segs = [
        seg("01", ["x"], q: 0.5, d: 2),
        seg("02", ["x"], q: 0.9, d: 1),
        seg("03", ["x"], q: 0.9, d: 3),
        seg("04", ["x"], q: 0.7, d: 1),
    ]
    let top = NarrativeStructureEngine.topCandidates(segs, limit: 2)
    // 质量降序，质量相同按时长降序：03(0.9,3) > 02(0.9,1)
    #expect(top.map(\.id) == [seg("03").id, seg("02").id])
}

@Test func topCandidates_limitLargerThanCountReturnsAll() {
    let segs = [seg("01", ["x"]), seg("02", ["x"])]
    #expect(NarrativeStructureEngine.topCandidates(segs, limit: 10).count == 2)
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter topCandidates 2>&1 | tail -8`
Expected: 找不到 `topCandidates`。

- [ ] **Step 3: 写实现（追加）**

```swift
    /// 喂 prompt 前每段取 Top-N：质量降序，质量相同按时长降序，再按 id 稳定排序
    public static func topCandidates(_ pool: [SegmentDescriptor], limit: Int) -> [SegmentDescriptor] {
        let sorted = pool.sorted {
            if $0.quality != $1.quality { return $0.quality > $1.quality }
            if $0.duration != $1.duration { return $0.duration > $1.duration }
            return $0.id.uuidString < $1.id.uuidString
        }
        return Array(sorted.prefix(max(0, limit)))
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter topCandidates 2>&1 | tail -5`
Expected: 2 个测试 PASS。

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): topCandidates 质量/时长排序截断"
```

---

## Task 5: feasibleVariantLimit + isValidVariant

**Files:**
- Modify: `Sources/MixCutCore/NarrativeStructureEngine.swift`
- Test: `Tests/MixCutCoreTests/NarrativeStructureEngineTests.swift`

- [ ] **Step 1: 写失败测试（追加）**

```swift
@Test func feasibleVariantLimit_isProductCappedByRequested() {
    let pools = [[seg("01",["x"]), seg("02",["x"])], [seg("03",["y"])]] // 2 * 1 = 2
    #expect(NarrativeStructureEngine.feasibleVariantLimit(pools: pools, requested: 5) == 2)
    #expect(NarrativeStructureEngine.feasibleVariantLimit(pools: pools, requested: 1) == 1)
}

@Test func feasibleVariantLimit_zeroIfAnyPoolEmpty() {
    let pools = [[seg("01",["x"])], [SegmentDescriptor]()]
    #expect(NarrativeStructureEngine.feasibleVariantLimit(pools: pools, requested: 3) == 0)
}

@Test func isValidVariant_rejectsWrongCountDupOrOutOfPool() {
    let pools = [[seg("01",["x"]), seg("02",["x"])], [seg("03",["y"])]]
    // 合法：每段选 1 个、在各自池内、无重复
    #expect(NarrativeStructureEngine.isValidVariant([seg("01").id, seg("03").id], pools: pools))
    // 段数不符
    #expect(!NarrativeStructureEngine.isValidVariant([seg("01").id], pools: pools))
    // 第 2 段选了不在池里的 id
    #expect(!NarrativeStructureEngine.isValidVariant([seg("01").id, seg("99",["z"]).id], pools: pools))
    // 重复 id
    #expect(!NarrativeStructureEngine.isValidVariant([seg("01").id, seg("01").id], pools: pools))
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter Variant 2>&1 | tail -8`
Expected: 找不到 `feasibleVariantLimit`/`isValidVariant`。

- [ ] **Step 3: 写实现（追加）**

```swift
    /// 可行变体上限 = 各段候选数乘积，封顶到请求数；任一段为空则为 0（溢出安全）
    public static func feasibleVariantLimit(pools: [[SegmentDescriptor]], requested: Int) -> Int {
        guard !pools.isEmpty, pools.allSatisfy({ !$0.isEmpty }) else { return 0 }
        var product = 1
        for p in pools {
            let (r, overflow) = product.multipliedReportingOverflow(by: p.count)
            if overflow { return requested }
            product = r
            if product >= requested { return requested }
        }
        return min(product, requested)
    }

    /// 校验一个变体合法：段数==池数、每段 id 在对应池内、无重复 id
    public static func isValidVariant(_ segmentIDs: [UUID], pools: [[SegmentDescriptor]]) -> Bool {
        guard segmentIDs.count == pools.count else { return false }
        guard Set(segmentIDs).count == segmentIDs.count else { return false }
        for (i, id) in segmentIDs.enumerated() where !pools[i].contains(where: { $0.id == id }) {
            return false
        }
        return true
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test 2>&1 | tail -6`
Expected: 全部测试 PASS（含前面所有）。

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): feasibleVariantLimit + isValidVariant 变体上限与合法性校验"
```

---

## Task 6: MixStrategy 加叙事结构字段

**Files:**
- Modify: `MixCut/Models/MixStrategy.swift`

⚠️ Schema 变更：动手前按 CLAUDE.md 备份库 `cp ~/Library/Application\ Support/MixCut/MixCut.store ~/Library/Application\ Support/MixCut/MixCut.store.bak`（这两个字段都是可选/带默认值，SwiftData 可轻量迁移，但仍先备份）。

- [ ] **Step 1: 加字段 + 计算属性**

在 `MixStrategy` 内（参照同项目 `Segment.semanticTypesData` 的 JSON 计算属性写法）追加：
```swift
    /// true = 用户自定义叙事结构（区别于 AI 策略 / 自定义组合）
    var isNarrativeTemplate: Bool = false

    /// 叙事段位序列（JSON 存储，元素见 MixCutCore.NarrativeSlot）
    var narrativeSlotsData: Data?

    var narrativeSlots: [NarrativeSlot] {
        get {
            guard let data = narrativeSlotsData else { return [] }
            return (try? JSONDecoder().decode([NarrativeSlot].self, from: data)) ?? []
        }
        set {
            narrativeSlotsData = try? JSONEncoder().encode(newValue)
        }
    }
```
并在文件顶部加 `import MixCutCore`。

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 3: 重启确认现有数据不丢（schema 兼容）**

Run: `pkill -x MixCut; sleep 1; open <Debug>/MixCut.app; sleep 4; sqlite3 ~/Library/Application\ Support/MixCut/MixCut.store "SELECT COUNT(*) FROM ZPROJECT;"`
Expected: 项目数与改动前一致（库未被清空）。

- [ ] **Step 4: Commit**

```bash
git add MixCut/Models/MixStrategy.swift
git commit -m "feat: MixStrategy 增 isNarrativeTemplate + narrativeSlots(JSON)"
```

---

## Task 7: SchemeGenerationService 叙事结构生成

**Files:**
- Modify: `MixCut/Services/SchemeGeneration/SchemeGenerationService.swift`

- [ ] **Step 1: 加生成方法（含程序侧合法性过滤）**

新增方法（复用现有 `catalogText` 目录格式与 `CompositionResponse` 解析；提示词用 spec §6.3；每段候选 `topCandidates(limit:30)`）：
```swift
import MixCutCore  // 文件顶部

/// 按叙事结构生成变体：每段候选池挑 1 条 → AI 多变体 + 自检连贯 → 程序侧二次过滤非法变体
/// 返回的每个元素是「按段顺序排列的 segment id 字符串数组」
func generateNarrativeVariants(
    slots: [NarrativeSlot],
    pools: [[SegmentDescriptor]],     // 与 slots 顺序一一对应（已 topCandidates 截断）
    idAliasMap: [UUID: String],       // segment.id → 目录里用的别名(如 "V1_03")
    catalogBySlot: [String],          // 每段渲染好的 "别名|时长|台词" 多行文本
    requested: Int
) async throws -> [[String]] {
    let n = NarrativeStructureEngine.feasibleVariantLimit(
        pools: pools.map { $0 }, requested: requested)
    guard n > 0 else { return [] }

    let structureText = slots.enumerated().map { i, slot in
        "段\(i + 1) [标签:\(slot.tags.joined(separator: "/"))] 候选:\n\(catalogBySlot[i])"
    }.joined(separator: "\n")

    let prompt = """
    你是信息流广告混剪专家。下面是一个固定的「叙事结构」(若干段,顺序不可变),
    每段给了一组候选分镜。任务:为每段从它自己的候选里挑 1 条,组成成片;
    生成 \(n) 个不同变体;对每个变体做台词连贯性自检,只输出连贯的。

    ## 叙事结构(段顺序=成片顺序,固定;你只决定每段选哪条)
    \(structureText)

    ## 硬性规则
    1. 每段必须且只能从【该段自己的候选】里选 1 条;不能借别段候选、不能漏段、不能改段序。
    2. 同一变体内不得重复使用同一条分镜。
    3. 生成 \(n) 个变体,彼此要有差异,不得有两个完全相同的 ID 组合。
    4. 连贯性自检——只输出通过的,不通过的直接丢弃:
       a. 相邻段台词语义衔接,整体像一条完整口播,不跳脱;
       b. ⚠️ 台词逻辑顺序不能排反:若两条台词本身有先后(同句上/下半句、"首先…其次…"),
          后半不能排在前半之前;
       c. 整体符合信息流节奏(开头抓人→中间种草→结尾促单)。

    ## 输出(JSON,只含通过自检的变体)
    {"variants":[{"segments":["V1_03","V1_05","V2_07","V1_09"],"note":"..."}]}
    只输出 JSON。
    """

    let response = try await aiProvider.generateJSON(
        prompt: prompt, responseType: CompositionResponse.self)
    let aliasToID = Dictionary(uniqueKeysWithValues: idAliasMap.map { ($0.value, $0.key) })

    // 程序侧二次过滤：别名→id，再用 MixCutCore.isValidVariant 校验（不只信 AI 自觉）
    var valid: [[String]] = []
    for comp in response.compositions {
        let ids = comp.segments.compactMap { aliasToID[$0] }
        if NarrativeStructureEngine.isValidVariant(ids, pools: pools) {
            valid.append(comp.segments)
        }
    }
    return valid
}
```
注：`CompositionResponse` 的字段名按现有定义对齐（现有用 `compositions`/`segments`，提示词里的 `variants` 需让响应解析兼容——若 `CompositionResponse` 只认 `compositions`，把提示词输出键改为 `compositions` 以复用现有解析，保持一致）。**实现时以现有 `CompositionResponse` 实际字段为准，二选一统一键名。**

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 3: Commit**

```bash
git add MixCut/Services/SchemeGeneration/SchemeGenerationService.swift
git commit -m "feat: 叙事结构变体生成 + 程序侧合法性过滤"
```

---

## Task 8: SchemeViewModel 编排（创建结构 / 生成 / 落库）

**Files:**
- Modify: `MixCut/ViewModels/SchemeViewModel.swift`

- [ ] **Step 1: 加方法**

```swift
import MixCutCore  // 顶部

// 当前项目库内"真实有分镜"的标签集合（供编辑器只列可选标签）
func availableTags(in project: Project) -> [SemanticType] {
    let present = Set(project.videos.flatMap { $0.segments }.flatMap { $0.semanticTypes })
    return SemanticType.allCases.filter { present.contains($0) }
}

// 新建一个空的叙事结构（isNarrativeTemplate strategy），返回它供编辑器编辑
func createNarrativeStructure(in project: Project) -> MixStrategy { /* 建 MixStrategy, isNarrativeTemplate=true, 关联 project, insert, save, 刷新 */ }

// 保存段位 + 重算 name
func updateSlots(_ slots: [NarrativeSlot], for strategy: MixStrategy) {
    strategy.narrativeSlots = slots
    strategy.name = NarrativeStructureEngine.structureName(for: slots)
    modelContext?.safeSave()
}

// 生成：组织 SegmentDescriptor/池/目录 → 调 service → 把通过的变体落成 MixScheme（命名"变体一/二…"）
func generateNarrativeVariants(for strategy: MixStrategy, in project: Project, requested: Int) async { /* 见下注 */ }
```
`generateNarrativeVariants` 内部：
1. 把 `project` 下所有 `Segment` 映射为 `SegmentDescriptor(id, tags: semanticTypes.map(\.rawValue), text, duration: endTime-startTime, quality: qualityScore)`，并建 `id→别名` 映射（沿用现有别名规则）。
2. 对每段 `candidatePool` → `topCandidates(limit: 30)`，渲染每段目录文本（`别名|时长|台词`），不足/为 0 时提示并中止。
3. 调 `service.generateNarrativeVariants(...)`，对返回的合法变体逐个建 `MixScheme`（`name = "变体" + 中文序号`，关联该 strategy，复用现有 SchemeSegment 建法）。
4. 全部未通过 → Toast 提示"未生成连贯变体，建议调整段位标签或增加素材"。

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 3: Commit**

```bash
git add MixCut/ViewModels/SchemeViewModel.swift
git commit -m "feat: SchemeViewModel 叙事结构创建/生成/落库编排"
```

---

## Task 9: 侧边栏"自定义结构"分组 + 入口

**Files:**
- Modify: `MixCut/Views/Schemes/SchemeListView.swift`

- [ ] **Step 1: 加分组渲染**

在策略列表里，把 `isNarrativeTemplate == true` 的策略归到一个"自定义结构"分组标题下，三级展示（模块 → 各结构(name) → 其 `orderedSchemes` 变体），并在分组尾部加 `＋ 添加结构` 按钮（点了 `createNarrativeStructure` 并打开编辑器）。变体行、点击进详情完全复用现有 `SchemeVariationRow` / `selectedScheme` 逻辑。

- [ ] **Step 2: 编译 + 重启 + 截图自测**

Run: `xcodebuild ... build && pkill -x MixCut; open <app>`，然后 `screencapture -l <wid>` 查看"自定义结构"分组与 `＋添加结构` 是否正确显示、现有策略/自定义组合分组未被破坏。
Expected: 截图确认三级结构显示正常，未误伤现有分组。

- [ ] **Step 3: Commit**

```bash
git add MixCut/Views/Schemes/SchemeListView.swift
git commit -m "feat: 方案侧边栏新增「自定义结构」三级分组与入口"
```

---

## Task 10: 叙事结构编辑器视图

**Files:**
- Create: `MixCut/Views/Schemes/NarrativeStructureEditorView.swift`

- [ ] **Step 1: 写编辑器**

按 spec §4：段位列表（拖拽排序、删除、每段候选数实时显示）、`＋加标签`（弹 `viewModel.availableTags(in:)`，已选 chip 可删）、`＋添加一段`、只读预览名（`NarrativeStructureEngine.structureName`）、生成变体数选择、`生成方案` 按钮（无标签/候选 0 段标红 + 禁用）。生成调 `viewModel.generateNarrativeVariants`，loading 复用 `isGenerating`。视图依赖项目数据需遵守"切换项目铁律"（`.task(id: project.id)` 在 body 顶层加载可选标签）。

- [ ] **Step 2: 编译 + 重启 + 真机点验证**

Run: 编译重启后**手动**：加结构 → 加段 → 每段加标签（确认只列库内现存类型）→ 候选数随标签变化 → 拖拽排序 → 预览名实时更新 → 点生成。截图记录。
Expected: 交互正常；候选不足/无标签时禁用并提示。

- [ ] **Step 3: Commit**

```bash
git add MixCut/Views/Schemes/NarrativeStructureEditorView.swift
git commit -m "feat: 叙事结构编辑器视图"
```

---

## Task 11: 端到端人工验收

**Files:** 无（验证）

- [ ] **Step 1: 全链路真机走查（列给用户测的清单）**

1. 新建结构 → 配 3-4 段标签 → 二级目录名 = 标签拼接正确。
2. 生成 → 只出现"通过连贯校验"的变体，命名"变体一/二/三"。
3. 点进变体 → 详情页样式与现有混剪方案完全一致、可预览/微调/导出。
4. 某段候选少时变体数自动收敛并提示；某段无标签时禁用生成。
5. 切换项目：编辑器可选标签、已建结构随项目刷新（切 A→B→A 回切数据正确）。
6. 重启 App：已建结构与变体仍在（落库正确）。

- [ ] **Step 2: 跑全部单元测试回归**

Run: `swift test 2>&1 | tail -6`
Expected: 全 PASS。

- [ ] **Step 3: 最终编译**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`。

---

## 自检（spec 覆盖）

- 三级层级/命名 → Task 9（分组）+ Task 2（structureName）✓
- 数据模型(isNarrativeTemplate/narrativeSlots JSON 不建表) → Task 6 ✓
- 候选池/并集 → Task 3 ✓；Top-N 截断(N=30) → Task 4 + Task 8 ✓
- 变体上限自适应 → Task 5 + Task 8 ✓
- AI 提示词(单次/规则/输出) → Task 7（§6.3）✓
- 程序侧二次合法性过滤 → Task 5(isValidVariant) + Task 7 ✓
- 只保留通过的/全失败提示 → Task 7 + Task 8 ✓
- 编辑器(只列库内标签/候选数/禁用) → Task 8(availableTags) + Task 10 ✓
- 变体详情复用 SchemeDetailView → Task 9（零改动复用）✓
- 切项目联动 → Task 10 ✓
- YAGNI(不做模板复用/手动命名/两次调用) → 计划未含，符合 ✓
