# 叙事结构「结构位时长过滤」Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给叙事结构的每个结构位增加可选的「时长区间」过滤(min~max 秒),候选分镜须同时满足标签命中且原始时长落在区间内。

**Architecture:** 在纯函数核心 `MixCutCore`(可 `swift test`)里给 `NarrativeSlot` 加两个可选字段并在 `candidatePool` 做时长过滤;编辑器 UI 加两个数字输入框 + 时长感知的实时候选计数;序列化与生成流程因复用 `candidatePool`/Codable 而自动生效,改动最小。原有 AI 连贯性检查完全不动。

**Tech Stack:** Swift 5.10 / SwiftUI / SwiftData / Swift Testing(`swift test` 跑 MixCutCore;UI 需 Xcode 编译)

**Spec:** `docs/superpowers/specs/2026-06-25-narrative-slot-duration-filter-design.md`

---

## 文件结构(改动清单)

| 文件 | 动作 | 职责 |
|---|---|---|
| `Sources/MixCutCore/NarrativeModels.swift` | 改 | `NarrativeSlot` 加 `minDuration/maxDuration: Double?`(可选,旧数据兼容) |
| `Sources/MixCutCore/NarrativeStructureEngine.swift` | 改 | `candidatePool` 标签过滤后追加时长闭区间过滤 |
| `Tests/MixCutCoreTests/NarrativeStructureEngineTests.swift` | 改 | 新增时长过滤 + Codable 兼容单测 |
| `MixCut/Views/Schemes/NarrativeStructureEditorView.swift` | 改 | `SlotRow` 加时长字段;映射;两个数字输入框;计数与校验时长感知 |
| `MixCut/ViewModels/SchemeViewModel.swift` | 不改(确认) | `updateSlots`/`generateNarrativeVariants` 经 Codable + `candidatePool` 自动带上时长 |

---

## Task 1: 数据模型加可选时长字段(含 Codable 旧数据兼容)

**Files:**
- Modify: `Sources/MixCutCore/NarrativeModels.swift:4-11`
- Test: `Tests/MixCutCoreTests/NarrativeStructureEngineTests.swift`

- [ ] **Step 1: 写失败测试 —— 旧 JSON(无时长键)能解码且时长为 nil + 新字段往返**

加到 `NarrativeStructureEngineTests.swift` 末尾:

```swift
@Test func narrativeSlot_decodesLegacyJSONWithoutDurationAsNil() throws {
    // 旧数据:没有 minDuration/maxDuration 键
    let legacy = #"{"order":0,"tags":["痛点"]}"#.data(using: .utf8)!
    let slot = try JSONDecoder().decode(NarrativeSlot.self, from: legacy)
    #expect(slot.minDuration == nil)
    #expect(slot.maxDuration == nil)
    #expect(slot.tags == ["痛点"])
}

@Test func narrativeSlot_durationRoundTrips() throws {
    let slot = NarrativeSlot(order: 1, tags: ["x"], minDuration: 5, maxDuration: 7.5)
    let data = try JSONEncoder().encode(slot)
    let back = try JSONDecoder().decode(NarrativeSlot.self, from: data)
    #expect(back.minDuration == 5)
    #expect(back.maxDuration == 7.5)
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd /Users/menggang/.config/superpowers/worktrees/Mixed_cut/new-task && swift test --filter NarrativeStructureEngineTests`
Expected: 编译失败(`NarrativeSlot` 无 `minDuration` 参数)

- [ ] **Step 3: 改模型**

`NarrativeModels.swift` 把 `NarrativeSlot` 改为:

```swift
public struct NarrativeSlot: Codable, Equatable, Sendable {
    public var order: Int
    public var tags: [String]
    /// 该段候选分镜的最短时长(秒),nil=不限
    public var minDuration: Double?
    /// 该段候选分镜的最长时长(秒),nil=不限
    public var maxDuration: Double?
    public init(order: Int, tags: [String], minDuration: Double? = nil, maxDuration: Double? = nil) {
        self.order = order
        self.tags = tags
        self.minDuration = minDuration
        self.maxDuration = maxDuration
    }
}
```

> 合成 Codable 对 Optional 缺键自动按 nil 处理 → 旧 `narrativeSlotsData` 解码不报错。`init` 给新参数默认值 → 所有旧调用点(`NarrativeSlot(order:tags:)`)继续编译。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter NarrativeStructureEngineTests`
Expected: 上面两条 PASS,原有测试不回归

- [ ] **Step 5: 提交**

```bash
git add Sources/MixCutCore/NarrativeModels.swift Tests/MixCutCoreTests/NarrativeStructureEngineTests.swift
git commit -m "feat(narrative): NarrativeSlot 增加可选时长区间字段(向后兼容)"
```

---

## Task 2: candidatePool 时长闭区间过滤

**Files:**
- Modify: `Sources/MixCutCore/NarrativeStructureEngine.swift:12-15`
- Test: `Tests/MixCutCoreTests/NarrativeStructureEngineTests.swift`

- [ ] **Step 1: 写失败测试**

加到测试文件(`seg` 助手已存在,`d:` 即 duration):

```swift
@Test func candidatePool_filtersByMinDurationInclusive() {
    let segs = [seg("01", ["x"], d: 4.9), seg("02", ["x"], d: 5.0), seg("03", ["x"], d: 6)]
    let slot = NarrativeSlot(order: 0, tags: ["x"], minDuration: 5)
    let pool = NarrativeStructureEngine.candidatePool(for: slot, in: segs)
    #expect(Set(pool.map(\.id)) == Set([seg("02").id, seg("03").id])) // 含 5.0,排除 4.9
}

@Test func candidatePool_filtersByMaxDurationInclusive() {
    let segs = [seg("01", ["x"], d: 5), seg("02", ["x"], d: 7), seg("03", ["x"], d: 7.1)]
    let slot = NarrativeSlot(order: 0, tags: ["x"], maxDuration: 7)
    let pool = NarrativeStructureEngine.candidatePool(for: slot, in: segs)
    #expect(Set(pool.map(\.id)) == Set([seg("01").id, seg("02").id])) // 含 7,排除 7.1
}

@Test func candidatePool_filtersByBothBoundsAndDecimals() {
    let segs = [seg("01", ["x"], d: 4), seg("02", ["x"], d: 5.5), seg("03", ["x"], d: 8)]
    let slot = NarrativeSlot(order: 0, tags: ["x"], minDuration: 5, maxDuration: 7)
    let pool = NarrativeStructureEngine.candidatePool(for: slot, in: segs)
    #expect(pool.map(\.id) == [seg("02").id]) // 仅 5.5 落区间
}

@Test func candidatePool_nilDurationMeansNoDurationFilter() {
    let segs = [seg("01", ["x"], d: 1), seg("02", ["x"], d: 99)]
    let slot = NarrativeSlot(order: 0, tags: ["x"]) // min/max 均 nil
    #expect(NarrativeStructureEngine.candidatePool(for: slot, in: segs).count == 2)
}

@Test func candidatePool_durationFilterStillRequiresTagMatch() {
    let segs = [seg("01", ["y"], d: 6)] // 时长命中但标签不命中
    let slot = NarrativeSlot(order: 0, tags: ["x"], minDuration: 5, maxDuration: 7)
    #expect(NarrativeStructureEngine.candidatePool(for: slot, in: segs).isEmpty)
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter NarrativeStructureEngineTests`
Expected: 新增 5 条 FAIL(当前 candidatePool 不看时长)

- [ ] **Step 3: 改 candidatePool**

`NarrativeStructureEngine.swift` 替换 `candidatePool`:

```swift
    /// 候选池:分镜标签与该段标签有交集(并集匹配),且时长落在该段 [min,max] 闭区间内
    public static func candidatePool(for slot: NarrativeSlot, in segments: [SegmentDescriptor]) -> [SegmentDescriptor] {
        let slotTags = Set(slot.tags)
        var pool = segments.filter { !slotTags.isDisjoint(with: Set($0.tags)) }
        if let lo = slot.minDuration { pool = pool.filter { $0.duration >= lo } }
        if let hi = slot.maxDuration { pool = pool.filter { $0.duration <= hi } }
        return pool
    }
```

- [ ] **Step 4: 跑测试确认通过(含全量回归)**

Run: `swift test`
Expected: 全部 PASS(原 67+ 条 + 新增 7 条)

- [ ] **Step 5: 提交**

```bash
git add Sources/MixCutCore/NarrativeStructureEngine.swift Tests/MixCutCoreTests/NarrativeStructureEngineTests.swift
git commit -m "feat(narrative): candidatePool 增加时长闭区间过滤"
```

---

## Task 3: 编辑器本地态 SlotRow 携带时长 + 映射 + 计数时长感知

**Files:**
- Modify: `MixCut/Views/Schemes/NarrativeStructureEditorView.swift`(SlotRow:12 / .task 映射:48-50 / normalizedSlots:390 / candidateCount:396 / addSlot:413)

> 本任务只做"数据贯通"(让时长在本地态↔库之间流转、让计数把时长算进去),UI 输入框留到 Task 4。每步后用 Xcode 编译验证(无 swift test 覆盖 UI 层)。

- [ ] **Step 1: SlotRow 加时长字段**(12-15)

```swift
    private struct SlotRow: Identifiable {
        let id = UUID()
        var tags: [String]
        var minDuration: Double? = nil
        var maxDuration: Double? = nil
    }
```

- [ ] **Step 2: .task 里 NarrativeSlot→SlotRow 映射带上时长**(48-50)

```swift
            slots = strategy.narrativeSlots
                .sorted { $0.order < $1.order }
                .map { SlotRow(tags: $0.tags, minDuration: $0.minDuration, maxDuration: $0.maxDuration) }
```

- [ ] **Step 3: normalizedSlots 映射带上时长**(390-394)

```swift
    private var normalizedSlots: [NarrativeSlot] {
        slots.enumerated().map { i, row in
            NarrativeSlot(order: i, tags: row.tags, minDuration: row.minDuration, maxDuration: row.maxDuration)
        }
    }
```

- [ ] **Step 4: candidateCount 改为按整段(含时长)计算**

把 `candidateCount(forTags:)`(396-398)替换为按 SlotRow 计:

```swift
    private func candidateCount(for row: SlotRow) -> Int {
        let slot = NarrativeSlot(order: 0, tags: row.tags, minDuration: row.minDuration, maxDuration: row.maxDuration)
        return NarrativeStructureEngine.candidatePool(for: slot, in: descriptors).count
    }
```

同步改两个调用点:
- `slotRow(index:row:)` 第 138 行:`let candidateCount = candidateCount(for: row)`
- `canGenerate` 第 314 行:把 `candidateCount(forTags: $0.tags) > 0` 改为对每个 slot 用新签名。注意第 314 行遍历的是 `normalizedSlots`([NarrativeSlot]),改为直接用引擎:

```swift
        return normalizedSlots.allSatisfy {
            !$0.tags.isEmpty && !NarrativeStructureEngine.candidatePool(for: $0, in: descriptors).isEmpty
        }
```

- [ ] **Step 5: 编译验证**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build`(在 worktree 目录)
Expected: BUILD SUCCEEDED(若 `candidateCount(forTags:)` 还有遗漏调用点,按报错补改)

- [ ] **Step 6: 提交**

```bash
git add MixCut/Views/Schemes/NarrativeStructureEditorView.swift
git commit -m "feat(narrative): 编辑器本地态贯通时长字段,候选计数时长感知"
```

---

## Task 4: 编辑器 UI —— 两个时长输入框 + 校验

**Files:**
- Modify: `MixCut/Views/Schemes/NarrativeStructureEditorView.swift`(slotRow 视图 ~151-197;新增 Double?↔String 绑定助手)

- [ ] **Step 1: 加一个 Double?↔String 绑定助手**(放到文件内私有方法区,如 396 附近)

```swift
    /// 把可选秒数与输入框文本互转:空串↔nil;非法输入忽略(保留原值)
    private func durationBinding(for index: Int, keyPath: WritableKeyPath<SlotRow, Double?>) -> Binding<String> {
        Binding(
            get: {
                guard index < slots.count, let v = slots[index][keyPath: keyPath] else { return "" }
                // 整数去掉小数尾巴,小数保留
                return v.rounded() == v ? String(Int(v)) : String(v)
            },
            set: { newText in
                guard index < slots.count else { return }
                let trimmed = newText.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    slots[index][keyPath: keyPath] = nil
                } else if let d = Double(trimmed), d >= 0 {
                    slots[index][keyPath: keyPath] = d
                } // 非法(负数/非数字)忽略,不写入
                persist()
            }
        )
    }
```

- [ ] **Step 2: 在 slotRow 的标签区下方插入时长输入行**

在 `slotRow` 的 `VStack(alignment: .leading, spacing: 8)` 内、候选数 `HStack` 之前,加一行:

```swift
                // 时长区间过滤(留空=不限)
                HStack(spacing: 6) {
                    Image(systemName: "timer").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("时长").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("不限", text: durationBinding(for: index, keyPath: \.minDuration))
                        .frame(width: 44).textFieldStyle(.roundedBorder).font(.system(size: 11))
                    Text("~").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("不限", text: durationBinding(for: index, keyPath: \.maxDuration))
                        .frame(width: 44).textFieldStyle(.roundedBorder).font(.system(size: 11))
                    Text("秒").font(.system(size: 11)).foregroundStyle(.secondary)
                    if let lo = row.minDuration, let hi = row.maxDuration, lo > hi {
                        Label("最短>最长", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
```

> `index` 与 `row` 在 `slotRow(index:row:)` 签名里都有,可直接用。

- [ ] **Step 3: 编译**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: 重启 App 自测(截图)**

```bash
pkill -x MixCut; sleep 1; open <DerivedData>/Build/Products/Debug/MixCut.app
```
打开 方案 → 自定义叙事结构编辑器,逐项目视检测:
- [ ] 每个结构位标签下方出现「时长 [ ] ~ [ ] 秒」两个框,初始留空显示"不限"
- [ ] 输入 min=5、max=7,候选数随之变化(变少);清空恢复
- [ ] min 填 7、max 填 5 → 出现「最短>最长」橙色提示
- [ ] 候选数=0 时序号圈/边框标红(复用现有 isInvalid)
- 用 `screencapture -l <window-id> /tmp/dur.png` 截图确认

- [ ] **Step 5: 提交**

```bash
git add MixCut/Views/Schemes/NarrativeStructureEditorView.swift
git commit -m "feat(narrative): 结构位时长区间输入框 + 非法区间提示"
```

---

## Task 5: 序列化与生成链路确认 + 全量回归

**Files:**
- Verify only: `MixCut/ViewModels/SchemeViewModel.swift:523`(updateSlots)、`:545`(generateNarrativeVariants)

- [ ] **Step 1: 确认 updateSlots 无需改**

读 `updateSlots(_ slots: [NarrativeSlot], for:)`:它接收 `[NarrativeSlot]` 并写入 `strategy.narrativeSlots`。`NarrativeSlot` 现已带时长 + Codable → 自动序列化。**确认无需改动**(若它内部重建了 NarrativeSlot 丢字段,则补齐)。

- [ ] **Step 2: 确认生成链路时长生效**

读 `generateNarrativeVariants`:确认它对每段调用 `NarrativeStructureEngine.candidatePool(for: slot, ...)` 传的是 `strategy.narrativeSlots` 里的真实 slot(带时长),`SegmentDescriptor` 的 `duration` 已由 `endTime-startTime` 填充(:574)。→ 过滤自动生效,**确认无需改动**。

- [ ] **Step 3: 端到端手动验证(关键回归)**

重启 App,在自定义叙事结构里:
- [ ] 设某段 5~7 秒 → 保存 → 关闭重开编辑器,时长**回显正确**(序列化往返 OK)
- [ ] 切到另一个项目再切回:时长设置仍在、候选数按新项目刷新(切项目铁律)
- [ ] 点生成变体:确认生成出的方案里,该结构位选用的分镜时长确实落在 5~7 秒
- [ ] 把范围卡到没有候选 → 该段标红 → 生成按钮不可用 / 给提示(沿用现有 canGenerate)
- [ ] **回归现有功能**(CLAUDE.md SOP):加段/删段/拖拽排序/多选标签/标签删除/保存/AI 连贯检查生成 全部仍正常

- [ ] **Step 4: 全量核心测试**

Run: `swift test`
Expected: 全绿

- [ ] **Step 5: Release 打包(按项目惯例,供分发测试)**

```bash
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Release build
# 按 CLAUDE.md 的 DMG 流程打包到 ~/Desktop/MixCut.dmg
```

- [ ] **Step 6: 提交(若 ViewModel 确有微调)**

```bash
git add -A && git commit -m "chore(narrative): 时长过滤端到端验证与序列化确认"
```

---

## 完成定义(DoD)
- `swift test` 全绿,含新增时长过滤 + Codable 兼容单测
- 编辑器能为每段设时长区间、留空=不限、非法区间有提示、候选计数时长感知
- 设置可序列化往返、切项目联动、生成时确实按时长过滤
- 原有结构编辑功能 + AI 连贯性检查 零回归(已手动逐项确认)
- 旧 `narrativeSlotsData` 数据零迁移可正常打开
