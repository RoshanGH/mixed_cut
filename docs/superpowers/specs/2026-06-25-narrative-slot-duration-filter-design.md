# 叙事结构「结构位时长过滤」设计

> 日期:2026-06-25
> 分支:`feature/new-task`(隔离 worktree)
> 状态:设计已与用户对齐,待写实现计划

---

## 1. 背景与目标

MixCut 的「自定义叙事结构」功能里,用户定义若干**结构位(NarrativeSlot)**,每个结构位可挂多个**标签(语义类型)**,系统据此为每个位置筛选候选分镜,再排列组合成多条混剪方案(`MixScheme`),并由 AI 做整体文案连贯性检查后保留通顺的组合。

**本次目标**:给每个结构位**新增一个"时长区间"过滤条件**。某结构位的候选分镜,必须**同时满足**:
1. 标签命中(现有逻辑:分镜标签与结构位标签有交集)
2. **分镜原始播放时长落在该结构位设定的 `[min, max]` 秒区间内(新增)**

两个条件是 **AND**。时长过滤是在标签过滤之外**多加的一道预过滤闸**,让候选池更精准。

### 明确不改的部分(已存在,必须保留)
**组合后的整体文案连贯性检查已经存在**,位于 `SchemeGenerationService.generateNarrativeVariants()` 的 prompt(Rule 4):相邻台词语义衔接、逻辑先后不排反、整体符合信息流节奏(开头抓人→中间种草→结尾促单),不通过的组合直接丢弃。本次**不改动**该流程——时长过滤只让进入组合的候选更精准,组合照常走现有连贯检查。

---

## 2. 现状代码锚点(已探查确认)

| 关注点 | 位置 |
|---|---|
| 结构位模型 `NarrativeSlot { order, tags:[String] }` | `Sources/MixCutCore/NarrativeModels.swift:4` |
| 策略持有结构位 `MixStrategy.narrativeSlots`(JSON 存 `narrativeSlotsData`) | `MixCut/Models/MixStrategy.swift:28-42` |
| 结构编辑器 UI | `MixCut/Views/Schemes/NarrativeStructureEditorView.swift` |
| 加段 `addSlot()` / 选标签 `tagPickerSheet` | NarrativeStructureEditorView.swift:413 / 331 |
| **标签过滤(插入点)** `candidatePool(for:in:)` | `Sources/MixCutCore/NarrativeStructureEngine.swift:12` |
| 候选排序 `topCandidates(limit:)` | NarrativeStructureEngine.swift:17 |
| 逐段构建候选池 + 调生成 | `MixCut/ViewModels/SchemeViewModel.swift:545-667` |
| 排列组合 + AI 连贯自检 | `MixCut/Services/SchemeGeneration/SchemeGenerationService.swift:378-432`(Rule4 @404-408) |
| 结构位序列化 `updateSlots()` | SchemeViewModel.swift:523-528 |
| `SegmentDescriptor` 已带 `.duration` | (NarrativeStructureEngine 使用的描述符类型) |

---

## 3. 设计

### 3.1 数据模型(`NarrativeModels.swift`)
`NarrativeSlot` 增加两个**可选**字段:
```swift
public struct NarrativeSlot: Codable, Equatable, Sendable {
    public var order: Int
    public var tags: [String]
    public var minDuration: Double?   // 新增:最短秒数,nil=不限
    public var maxDuration: Double?   // 新增:最长秒数,nil=不限
}
```
- **可选 + Codable**:旧 `narrativeSlotsData`(无这两字段)解码后两者为 nil → **行为与现状完全一致,旧数据零迁移**。
- 初始化器需保持对旧调用点的兼容(给新参数默认 nil)。

### 3.2 过滤引擎(`NarrativeStructureEngine.candidatePool`)
标签交集过滤后追加时长过滤,**闭区间**:
```swift
public static func candidatePool(for slot: NarrativeSlot, in segments: [SegmentDescriptor]) -> [SegmentDescriptor] {
    let slotTags = Set(slot.tags)
    var pool = segments.filter { !slotTags.isDisjoint(with: Set($0.tags)) }
    if let lo = slot.minDuration { pool = pool.filter { $0.duration >= lo } }
    if let hi = slot.maxDuration { pool = pool.filter { $0.duration <= hi } }
    return pool
}
```
- 只设一端则只卡一端;两端都 nil = 不过滤。
- 秒数允许小数;"时长"= `SegmentDescriptor.duration`(= 分镜 `endTime - startTime`)。
- 不可变:返回新数组,不改入参(符合项目不可变约定)。

### 3.3 UI(`NarrativeStructureEditorView`,每个结构位行)
标签下方一行时长输入:`时长 [min] 秒 ~ [max] 秒`
- 两个小号 `TextField`,数字键盘语义,允许小数,**留空 = 不限**(绑定到可选 Double,空串↔nil)。
- 输入校验:负数、min>max 给轻提示并不落库非法值(min>max 视为无效,提示用户)。
- **实时"匹配 N 条"计数**:每个结构位显示当前(标签 ∩ 时长)能匹配到的分镜数;**N=0 标红**,提醒用户范围太死。计数复用 `candidatePool` 对当前项目分镜跑一遍(本地、轻量)。

### 3.4 序列化(`SchemeViewModel.updateSlots`)
把 `minDuration/maxDuration` 一并写入 `strategy.narrativeSlots`(经由 `NarrativeSlot` 的 Codable 自动处理,确保编辑器本地态 `SlotRow` → `NarrativeSlot` 映射时带上新字段)。

### 3.5 连贯性检查
**不动**。`generateNarrativeVariants` 仍按现有 prompt(Rule 4)做 AI 连贯自检并丢弃不通顺组合。

### 3.6 空池兜底
- 编辑器:靠 3.3 的实时计数 + N=0 标红,让用户在编辑阶段就发现并放宽。
- 生成时:若某段候选为 0,该组合无法成立(沿用现有"段无候选"的处理路径,不新增崩溃风险);必要时在生成入口给一次性提示"某结构位无匹配分镜,请放宽标签或时长"。

---

## 4. 测试(TDD)

`Tests/MixCutCoreTests/` 给 `NarrativeStructureEngine.candidatePool` 加单测(纯函数,易测):
- 只设 min:小于 min 的被排除,等于 min 的保留(闭区间)
- 只设 max:大于 max 的被排除,等于 max 的保留
- 双端:区间内保留、区间外排除、恰好等于边界保留
- 两端 nil:等同纯标签过滤(回归)
- 小数边界(如 5.5)
- 标签不命中即使时长命中也排除(AND 语义)
- 空输入/空池

UI 与序列化部分以手动验证为主(编辑器加段→设时长→保存→重开校验回显;切项目联动;实时计数随调整刷新)。

---

## 5. 范围与非目标
- **范围**:仅"结构位时长过滤"+ 编辑器输入 + 实时计数 + 序列化兼容 + 引擎单测。
- **非目标**:不改连贯性检查逻辑、不改 AI prompt、不动排列组合算法本体、不涉及画面裂变(VACE)那条线。

---

## 6. 风险与注意
- **旧数据兼容**:必须保证旧 `narrativeSlotsData` 解码不报错(可选字段默认 nil)。改 schema 前按项目规矩备份 `MixCut.store`。
- **不破坏现有结构编辑器功能**:加段/删段/拖拽排序/多选标签/保存回显/切项目联动 —— 改完逐项手动回归(项目 CLAUDE.md 的强制 SOP)。
- **实时计数性能**:分镜量大时计数应轻量(纯内存过滤,避免每次按键重算全量时加防抖)。
