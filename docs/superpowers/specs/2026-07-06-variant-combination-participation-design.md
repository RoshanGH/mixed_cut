# 变体「参与排列组合」逐项开关 — 设计文档

> 日期：2026-07-06
> 状态：设计已与用户逐段对齐，待 spec 评审 → 用户复核 → writing-plans
> 范围：影响**所有配音导出路径**——「混剪方案笛卡尔积导出」**和**「单分镜 / 批量分镜导出」都遵循同一参与规则；不改动分镜头 AI 编辑（ShotVariant）。

---

## 1. 目标与背景

**现状**：配音导出时，每个方案对其各分镜做**笛卡尔积**——每格选项 = `原版 + 该分镜所有已生成的配音/文案变体（effectiveDubVariants）`，全部连乘（锁定镜 ×1）。组合数 = `∏ (1 + 变体数)`，几个分镜各几个变体就瞬间爆炸成几百上千条。

- 组合基数公式在 `DubExportService.SchemeComboPlanner.feasibleCount`（`:112-117`）；实际枚举在 `Sources/MixCutCore/VariantCombinationGenerator.generate`；方案详情页提示 `SchemeDetailView.slotFactors`（`:242-247`）复用同公式。
- **当前唯一的收敛手段是整条分镜 `isVoiceLocked`（那格 ×1）**，没有变体级别的参与控制——只要生成了变体就自动全进笛卡尔积。

**目标**：在变体列表里给**每个变体**一个"是否参与排列组合"的多选框，再加一个固定的「**原版是否参与**」多选框，让用户精确控制每个分镜参与组合的"档数"，从而把导出组合数收敛到可控范围。

---

## 2. 核心规则（所有导出路径统一）

**"导出的一刻才组合"**——无论方案笛卡尔积还是单分镜/批量导出，一个分镜实际导出/参与的"版本集合"都按同一规则计算：没勾选的（原版或变体）导出时就没有它。

对某个分镜，其"参与集合"按如下计算：

1. 若 `isVoiceLocked == true` → 该格恒为 **仅原版（×1）**，忽略下述所有勾选（最高优先级，维持现状）。
2. 否则，参与集合 = `(原版 if originalParticipatesInCombination) ∪ (participatesInCombination == true 的变体)`。
3. **兜底**：若上述集合为空（原版没勾、也没勾任何变体）→ **回退为仅原版（×1）**，保证该分镜始终在混剪结果里、不断档。

组合总数 = 各格"参与集合大小"连乘。

**默认值（决策 A）**：
- 原版默认 **参与**（`originalParticipatesInCombination = true`）。
- 新生成的变体默认 **不参与**（`participatesInCombination = false`，opt-in）。
- 效果：分镜默认只出原版（×1），不炸；用户手动勾选想要的变体才进组合。

**作用范围（决策 B）= 全局**：勾选状态存在共享的 `Segment` / `SegmentDub` 上，对所有用到该分镜的方案统一生效（变体池本就是全局共享）。

---

## 3. 数据模型（新增字段，全局持久化）

- `SegmentDub` 新增：`var participatesInCombination: Bool = false`
  （文件 `MixCut/Models/SegmentDub.swift`）
- `Segment` 新增：`var originalParticipatesInCombination: Bool = true`
  （文件 `MixCut/Models/Segment.swift`）

**Schema 变更**：两个新增可选布尔（带默认值），additive、向后兼容；仍按项目规则改前备份库（当前库已清空，风险为零）。

**不改** `Segment.effectiveDubVariants`（`SegmentDub.swift:47-60`）——它仍返回"所有已生成变体"，供**单分镜批量导出**（`VariantBatchExportService` / `SegmentExportExpander`）等既有用途使用，不受本功能影响。参与过滤只在方案笛卡尔积路径新增一个派生属性。

新增派生属性（供组合路径与 UI 提示共用，避免公式三处重复漂移）：
```
// extension Segment
/// 参与方案笛卡尔积的变体（= effectiveDubVariants 里勾选了参与的）
var combinationDubVariants: [SegmentDub] {
    effectiveDubVariants.filter { $0.participatesInCombination }
}
/// 该分镜参与组合的"档数"（含兜底、锁定语义），单一真源
var combinationSlotCount: Int {
    if isVoiceLocked { return 1 }
    let variants = combinationDubVariants.count
    let base = originalParticipatesInCombination ? 1 : 0
    return max(1, base + variants)   // 兜底 ≥1（回退仅原版）
}
```

---

## 4. 组合引擎改动（MixCutCore，纯逻辑 + TDD）

现状 `VariantCombinationGenerator.generate(slots:limit:includeOriginal:)` 用**全局** `includeOriginal` 决定每格是否含原版（`SlotOptions { isLocked, dubIds }`）。新规则里"原版是否参与"是**逐格**的，故：

- `SlotOptions` 改为：`{ isLocked: Bool, includeOriginal: Bool, dubIds: [UUID] }`。
- 每格实际选项 = `(includeOriginal ? [nil] : []) + dubIds.map(Optional.some)`；若为空 → 回退 `[nil]`（仅原版）。`isLocked` → `[nil]`。
- 移除/弃用全局 `includeOriginal` 参数（改为逐格）。**注意：这会破坏现有 `Tests/MixCutCoreTests/VariantCombinationGeneratorTests.swift`（按旧签名调用），实施计划必须包含"更新旧测试到逐格签名"这一步。**
- `feasibleCount`/上限截断（`feasibleCap`、`maxCombos=256`）逻辑保留。

**调用方 `SchemeComboPlanner.plan`（`DubExportService.swift:119-140`）** 映射每格：
```
SlotOptions(
  isLocked: seg.isVoiceLocked,
  includeOriginal: seg.isVoiceLocked ? true : seg.originalParticipatesInCombination,
  dubIds: seg.isVoiceLocked ? [] : seg.combinationDubVariants.map(\.id)
)
```
`feasibleCount` 改为 `∏ seg.combinationSlotCount`（复用 §3 单一真源）。

**⚠️ 其它必须同步更新的 `SlotOptions` 调用方（否则改签名后编译失败）**：
- `MixCut/App/DebugSelfTest.swift:48-49`：用旧 `SlotOptions(isLocked:dubIds:)` 构造槽 → 改为逐格 `includeOriginal`。
- `DebugSelfTest.swift:123`：手工算 `1 + seg.effectiveDubVariants.count` 的调试计数 → 改用 `seg.combinationSlotCount`（否则调试输出与实际组合数不一致）。

### 4b. 单分镜 / 批量分镜导出（`SegmentExportExpander`，纯逻辑 + TDD）

`Sources/MixCutCore/SegmentExportExpander.swift` 现在把每个 `SegmentExportSource` 展开成"**恒含原版** + 全部 `variants`"（锁定 → 仅原版）。改为遵循同一参与规则：

- `SegmentExportSource` 新增 `includeOriginal: Bool`（App 层从 `Segment.originalParticipatesInCombination` 填；锁定时视为 true）。
- `SegmentExportSource.variants` 由 App 层**只填参与的变体**（= `combinationDubVariants` 对应的 `VariantRef`），不再传全部。
- `expand` 逻辑改为：
  - `isVoiceLocked` → 仅原版；
  - 否则 items = `(includeOriginal ? [原版] : []) + variants`；**若为空 → 回退仅原版**（与笛卡尔积兜底一致）。
  - 命名保持：原版用 base 名，变体用 `_A/_B`（按 `textVariantIndex`）。
- 调用方：实际构造点在 `VariantBatchExportService.swift` 的 `VariantExportInput.from(...)`（`:41` 附近），改用 `combinationDubVariants` + `originalParticipatesInCombination`（锁定时 `includeOriginal` 填 true 即可，expander 锁定分支本就忽略它，无需特殊逻辑）。

效果："某分镜 7 个变体只勾 2 个（原版+1 变体）→ 单/批量导出就只出这 2 条"。**注意：改 `SegmentExportSource` 签名会破坏现有 `SegmentExportExpanderTests`（若有），计划里要含更新旧测试。**

---

## 5. UI 改动

**变体池 `SegmentVariantInspector`（`Views/SegmentLibrary/SegmentVariantInspector.swift`）**：
- 每个**已生成**变体的格子（`cell` `:322` / `versionCard` `:189`）加一个多选框，绑定 `SegmentDub.participatesInCombination`，勾选即写库。
  - 未生成音频的变体不显示勾选框（无音频不进组合，与 `effectiveDubVariants` 一致）。
- 矩阵顶部（或原版所在处）加一个固定的「**原版参与组合**」多选框，绑定 `Segment.originalParticipatesInCombination`。
- 锁定分镜（`isVoiceLocked`）时：勾选框禁用 + 提示"已锁原声，不参与组合"（复用现有 `:99-102` 锁定提示区）。
- 可选：在池底部实时显示"当前该分镜参与 N 档"（= `combinationSlotCount`），让用户直观看到收敛效果。

**方案详情页 `SchemeDetailView`（`MixCut/Views/Schemes/SchemeDetailView.swift:242-259`）**：`slotFactors` / "可生成 N 组合" 提示改用 `combinationSlotCount`，与新规则一致（不再显示被排除的变体）。

**导出页 `ExportView`（`totalComboCount` `:722-726`）**：随 `feasibleCount` 收敛自动变小，无需额外改动逻辑（校验数值即可）。

**批量导出面板 `BatchExportSheet`**：其"将导出 N 条"预览/计数随 `SegmentExportExpander`（现只含参与项）自动收敛；校验计数正确即可。

**回归保护**（勿破坏）：`SegmentVariantInspector` 现有的 生成/试听/重生成/删除、锁定提示；`SchemeDetailView` 的每槽单选下拉（`selectedSegmentDubId`，用于单条预览/导出，与本功能正交，保持不变）。

---

## 6. 非目标（YAGNI）

- 不改 `ShotVariant`（分镜头 AI 画面替换）——占位式手动合成，不参与随机排列组合。
- 不改 `effectiveDubVariants` 本身（它仍返回"所有已生成变体"，供变体池展示等用途）；参与过滤通过新增派生 `combinationDubVariants` 施加于**所有导出路径**（方案笛卡尔积 + 单/批量导出）。
- 不做"每方案独立的参与集"（决策 B 选了全局）。
- 不改 `SchemeSegment.selectedSegmentDubId`（每槽单选，正交语义）。

---

## 7. 测试策略

**纯逻辑单测（`Tests/MixCutCoreTests/VariantCombinationGeneratorTests.swift`，Swift Testing）**：
- **先更新现有测试到逐格 `SlotOptions{isLocked,includeOriginal,dubIds}` 新签名**（旧测试用全局 `includeOriginal`，改签名后必然编译失败 → 计划里作为一个明确步骤）。
- 逐格组合覆盖：原版参与+2 勾选变体 → 3 档；仅勾变体不勾原版 → 只出变体（无 nil）；全不勾（`includeOriginal:false, dubIds:[]`）→ 兜底 1 档（回退 `[nil]`）；锁定 → 1 档。
- 笛卡尔积基数：`3×1×2` 等；`feasibleCap`/`limit` 截断行为不回归。
- **测试边界**：基数与组合逻辑在 `VariantCombinationGenerator`（用 `SlotOptions` 输入）层覆盖即可；`combinationSlotCount`/`combinationDubVariants` 依赖 SwiftData `Segment`，**不进 MixCutCore 纯单测**，改由人工/集成验收（§下）。

**单/批量导出展开测试（`Tests/MixCutCoreTests/SegmentExportExpanderTests.swift`）**：
- 先更新现有测试到 `SegmentExportSource` 含 `includeOriginal` 的新签名。
- 覆盖：原版+2 参与变体 → 3 条；仅变体不含原版 → 只出变体；`includeOriginal:false` 且无变体 → 兜底 1 条（原版）；锁定 → 仅原版。命名（base / `_A`/`_B`）不回归。

**人工验收（app 内）**：
1. 变体池勾选/取消 → 方案详情"可生成 N 组合"实时变化。
2. 只勾 1 个变体 + 原版 → 该分镜 2 档；导出条数符合预期、不爆炸。
3. 全不勾 → 该分镜仍出原版、方案不断档。
4. 锁定分镜 → 勾选禁用、恒 1 档。
5. 生成/试听/重生成/删除、单槽下拉预览等既有功能不受影响。
