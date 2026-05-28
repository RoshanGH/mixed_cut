# 手动分镜编辑器（自定义方案 + AI 方案手改）

- **日期**：2026-05-28
- **作者**：MixCut 团队（与 Claude 协作）
- **状态**：设计完成，待实现
- **基线版本**：v0.2.6（commit `f068da4`）
- **回滚策略**：在独立分支 `feature/manual-scheme-editor` 上开发；若功能不达预期，可直接回到 v0.2.6 tag 发版

---

## 1. 背景与目标

MixCut 当前已经能把广告成片按语义切成分镜，并由 AI 重新排列组合出多条"混剪方案"。AI 自动化是骨架，但用户对"创作控制权"有真实诉求：

- **场景 A**：用户在分镜素材库浏览时，已经"看中"几个分镜，希望能直接挑选这些分镜组合成一个视频，**不经过 AI 策略**。
- **场景 B**：AI 已生成的某个方案大部分满意，但其中 1-2 个镜头想换或加，希望能在方案详情页直接增删改顺序。

**目标**：在不破坏现有 AI 流水线的前提下，把"AI 排镜头"和"人手排镜头"统一到同一套数据模型与编辑器 UI 中，让用户能在 AI 输出之上做精细化干预，也能从零自定义。

**非目标**：

- 不做分镜内剪辑（trim/裁切）的 UI 升级 —— 现有 `StoryboardTimeRow` 已经能微调 IN/OUT。
- 不引入"分镜复用"（同一分镜在同一方案内出现多次）—— 本期阻止。
- 不做 AI 方案的"原始版本"快照与撤销 —— 仅打"已编辑"标记，不保留原 AI 版。

---

## 2. 总体设计原则

1. **数据模型最小变更**：只在 `MixScheme` 增加 2 个 Bool 字段，不引入新模型实体。
2. **UI 复用最大化**：场景 A 的"调整顺序" Sheet 复用 `StoryboardCard`；场景 B 的分镜库抽屉复用 `SegmentLibraryView` 的卡片渲染。
3. **AI 是锦上添花**：自定义方案的元信息（名称/叙事结构等）由 AI 反推，**反推失败不阻断流程**，落默认名继续可用。
4. **不破坏现有功能**：严格遵循 `CLAUDE.md` 的"切换项目联动""不要在修改过程中破坏已有功能"两条铁律。
5. **版本回滚锚点清晰**：独立分支开发，main 始终保持 v0.2.6 可发版状态。

---

## 3. 数据模型变更

### 3.1 字段增加（共 2 个 Bool）

```swift
@Model
final class MixStrategy: Identifiable {
    // ... 已有字段保持不变 ...

    // 新增：标识这是"自定义组合"分组，不会被 AI 生成流程触碰
    var isCustomGroup: Bool = false
}

@Model
final class MixScheme: Identifiable {
    // ... 已有字段保持不变 ...

    // 新增：true = AI 方案被手动改过
    var isManuallyEdited: Bool = false
}
```

**默认值兜底**：旧数据 `isCustomGroup = false`、`isManuallyEdited = false`，行为与原 AI 方案完全一致，无迁移风险。

> **设计说明**：不再在 `MixScheme` 上加 `isCustom` 字段。判断"是否自定义方案"的方式 = `scheme.strategy?.isCustomGroup == true`。这是单一信息源，避免冗余。

### 3.2 "自定义组合"是真实策略实体

每个项目预创建一个 `MixStrategy`：

```swift
MixStrategy(
    name: "自定义组合",
    style: "",
    description: "手动挑选分镜组合的方案",
    targetAudience: "",
    narrativeStructure: "",
    targetDuration: 0
)
// 然后设置 isCustomGroup = true
```

**创建时机：**

- **新项目**：在 `ProjectViewModel.createProject` 内立即同步创建
- **老项目**：`MixCutApp.init()` 中类似 `fixMissingSemanticTypes()` 增加一次性迁移 `ensureCustomGroupStrategy()`，遍历所有项目，缺一条则补一条

**对 AI 生成流程的影响：**

`SchemeGenerationService` 在写入新策略时，**只创建 `isCustomGroup = false` 的策略**；列出现有策略给 AI 看时也必须过滤掉自定义组合（避免 AI 误以为要往里面填变体）。

```swift
// SchemeViewModel 提供两个派生属性
var aiStrategies: [MixStrategy] {
    strategies.filter { !$0.isCustomGroup }
}

var customGroup: MixStrategy? {
    strategies.first { $0.isCustomGroup }
}
```

### 3.3 编辑动作打标记的规则

所有改动 `schemeSegments` 的方法内部：

```swift
private func markAsEdited(_ scheme: MixScheme) {
    let isCustom = scheme.strategy?.isCustomGroup == true
    guard !isCustom, !scheme.isManuallyEdited else { return }
    scheme.isManuallyEdited = true
}
```

调用点：`insertSegment`、`replaceSegment`、`removeSegment`、`moveSegment`。

> 自定义方案不打"已编辑"标记 —— 它本来就是手拼的。

---

## 4. 场景 A：从分镜库自由组合 → 自定义方案

### 4.1 入口

在 `SegmentLibraryView` 的多选模式工具栏（与"批量导出"并列）新增按钮：

```
[已选 N 项]  [全选][反选][清空]   [📦 批量导出]  [✨ 组合为方案]
```

- 仅当 `selectedSegments.count >= 2` 时高亮可点
- 仅当 `selectedSegments.count == 1` 时灰色显示且 tooltip 提示「至少选择 2 个分镜」

### 4.2 调整顺序 Sheet

点击「组合为方案」→ 弹出模态 Sheet：

```
┌─ 调整顺序（4 个分镜，预计 4.2s）──────────────────┐
│                          [取消]  [生成方案 (4)] │
├──────────────────────────────────────────────┤
│  ⋮┌──┐  ⋮┌──┐  ⋮┌──┐  ⋮┌──┐                    │
│   │#1│   │#2│   │#3│   │#4│                    │
│   └──┘   └──┘   └──┘   └──┘                    │
│   A      B      D      E                       │
│                                                │
│  说明：拖拽 ⋮ 调整顺序                            │
└──────────────────────────────────────────────┘
```

- 横向 `LazyHStack` + `.onMove`（SwiftUI 原生拖拽）
- 默认顺序 = `selectedSegments` 在素材库的渲染顺序
- 顶部右上：`[取消]` 关闭 Sheet，不改动选中集；`[生成方案 (N)]` 触发同步生成

### 4.3 同步生成 + AI 反推

`[生成方案]` 按下后：

1. 按钮转为 loading 状态，禁用其他交互
2. 调用 `SchemeViewModel.createCustomScheme(from: orderedSegments, in: project)`
3. 内部流程：
   - 找到该项目的 `customGroup` 策略（必定存在，由 §3.2 的迁移保证）
   - 创建 `MixScheme(strategy: customGroup, name: "自定义 #\(N)")` + N 个 `SchemeSegment`
   - 调用 `SchemeGenerationService.inferMetadata(for: segments)` 发起 AI 调用
   - 成功 → 更新方案的 `name / narrativeStructure / targetAudience / schemeDescription / style`
   - 失败 → 不改 name，顶部 `ToastCenter` 提示「元信息生成失败，方案已保存为『自定义 #N』」
4. Sheet 关闭 → 切换到「方案」板块 → 选中刚创建的方案 → 显示详情页

### 4.4 AI 反推 Prompt（新文件）

`MixCut/Resources/Prompts/custom_scheme_inference.md`：

```markdown
# 任务

下面是用户手动挑选并排序的 N 个分镜。请根据这些分镜的语义类型、台词和时长，
反推出这条视频的：
1. 方案名称（5-10 字，体现叙事重点）
2. 叙事结构（"X-Y-Z" 三段式，例如"痛点-产品-行动"）
3. 目标受众（简短描述）
4. 方案描述（30-60 字）
5. 风格标签（从已知风格中选最贴近的一个）

## 输入

{{SEGMENTS_JSON}}

## 输出（严格 JSON）

{
  "name": "...",
  "narrativeStructure": "...",
  "targetAudience": "...",
  "schemeDescription": "...",
  "style": "..."
}
```

由 `SchemeGenerationService` 增加一个方法：

```swift
func inferMetadata(for segments: [Segment]) async throws -> CustomSchemeMetadata
```

复用现有 `AIProvider` 调用链路。

---

## 5. 场景 B：在已有方案 storyboard 上增删改

### 5.1 行间「⊕」插入按钮

`SchemeDetailView.storyboardView` 重构 `ForEach`：

```swift
LazyHStack(alignment: .top, spacing: 0) {
    InsertGapButton(position: 1, onTap: { openDrawer(insertAt: 1) })

    ForEach(Array(scheme.orderedSegments.enumerated()), id: \.element.id) { idx, schemeSeg in
        StoryboardCard(schemeSeg: schemeSeg, ...)
        InsertGapButton(position: idx + 2, onTap: { openDrawer(insertAt: idx + 2) })
    }
}
```

`InsertGapButton`：
- 默认状态：宽 12pt，透明
- Hover：宽 28pt，显示「⊕」图标 + 浅色背景
- 点击：触发 `openDrawer(insertAt:)`

### 5.2 卡片上的删除 / 替换按钮

修改 `StoryboardCard`，hover 时右上角浮出两个小图标：

```
┌──────────┐
│  视频    🗑️ 🔄 │
│  预览    │
├──────────┤
│ #1       │
│ 痛点 产品 │
└──────────┘
```

- 🗑️ 删除：直接调 `removeSegment`，前置校验「至少保留 1 条」（详见 5.5）
- 🔄 替换：触发 `openDrawer(replace: schemeSeg)`

**右键菜单**同样提供：「在前插入」「在后插入」「替换为…」「删除」。

### 5.3 SegmentPickerDrawer（新组件）

新文件 `MixCut/Views/Schemes/SegmentPickerDrawer.swift`：

```
┌─ 选择分镜 ────────────────────┐
│ 在 #3 前插入                ✕ │
│ [筛选: 全部 ▼] [搜索...]       │
├──────────────────────────────┤
│ ┌──┐ ┌──┐ ┌──┐ ┌──┐         │
│ │A │ │B │ │C │ │D │         │
│ └──┘ └──┘ └──┘ └──┘         │
│ ┌──┐ ┌──┐ ┌──┐ ┌──┐         │
│ │E │ │F │ │G │ │H │         │
│ └──┘ └──┘ └──┘ └──┘         │
│                              │
│ ⊘ B（已在方案中）            │
└──────────────────────────────┘
```

- 从 `SchemeDetailView` 右侧滑入，宽 320pt
- 关闭方式：✕ 按钮 / 点击空白处 / Esc
- 内容：复用 `SegmentLibraryView` 的卡片渲染（提取 `SegmentCardCompact` 子组件，**这个提取属于本期必要重构**）
- 单选模式：点击一个分镜立即执行操作
- 智能默认筛选：
  - 插入模式：不预设筛选
  - 替换模式：默认按 "与被替换分镜相同语义类型" 过滤（顶部一个「显示全部」开关可清除）
- **已在方案中的分镜置灰**：左上角加圆形「⊘」角标，整卡片 `opacity 0.4` + 禁用点击 + tooltip「该分镜已在方案中」
- 执行成功后：抽屉**保持打开**，顶部 toast 提示「已插入 #N」/「已替换 #M」，便于连续添加多个

### 5.4 重复分镜的双重防御

| 防御层 | 行为 |
|---|---|
| **UI 层** | 抽屉中已在当前方案的分镜整卡片置灰禁用 |
| **ViewModel 层** | `insertSegment` / `replaceSegment` 入口校验 `scheme.schemeSegments` 是否已含 `segment.id`，命中则 return false 并不写库 |
| **用户反馈** | UI 层禁用使大多数情况不会触发；万一被某种方式绕过，toast 提示「该分镜已在方案中」 |

### 5.5 删到 0 个的兜底

`SchemeViewModel.removeSegment`：

```swift
func removeSegment(_ schemeSeg: SchemeSegment, from scheme: MixScheme) -> Bool {
    guard scheme.schemeSegments.count > 1 else {
        ToastCenter.shared.show("方案至少保留 1 个分镜", icon: "exclamationmark.circle.fill")
        return false
    }
    // ... 已有逻辑 ...
    return true
}
```

UI 层在 hover 删除按钮时，若 `count == 1` 则显示 tooltip 「方案至少保留 1 个分镜」，按钮变灰。

### 5.6 拖拽换序

复用已有 `moveSegment(from:to:)`，在 `LazyHStack` 上加 `.onMove` 修饰符。

---

## 6. SchemeViewModel 新增方法（约 50 行）

```swift
// 在指定位置插入分镜（position 从 1 开始）
// 返回 false 表示重复，已 toast 提示
@discardableResult
func insertSegment(_ segment: Segment, at position: Int, in scheme: MixScheme) -> Bool

// 替换某个 SchemeSegment 上的 Segment
// 返回 false 表示新 segment 已在方案中
@discardableResult
func replaceSegment(_ schemeSeg: SchemeSegment, with newSegment: Segment, in scheme: MixScheme) -> Bool

// 从分镜数组创建自定义方案（异步，含 AI 反推）
func createCustomScheme(
    from segments: [Segment],
    in project: Project
) async throws -> MixScheme

// 内部工具
private func markAsEdited(_ scheme: MixScheme)
private func renumberPositions(in scheme: MixScheme)
private func containsSegment(_ segment: Segment, in scheme: MixScheme) -> Bool
```

---

## 7. SchemeListView 改动

左栏渲染所有策略（`isCustomGroup == true` 的"自定义组合"排在 AI 策略**之后**）：

```
┌────────────────────────────────────┐
│ 混剪方案  2 策略·5 视频           +│
├────────────────────────────────────┤
│ ▾ 高冷营销风                       │
│   ├ 变体 1                         │
│   └ 变体 2                         │
│ ▾ 热血塑造                         │
│   ├ 变体 1  ·已修改                 │
│   ├ 变体 2                         │
│   └ 变体 3                         │
│ ▾ ✨ 自定义组合                     │
│   └ 自定义 #1                      │
└────────────────────────────────────┘
```

**渲染细节：**

- 用一个 `ForEach(orderedStrategies)` 统一渲染，`orderedStrategies = aiStrategies + [customGroup].compactMap { $0 }`
- `isCustomGroup` 的策略在分组标题上加 ✨ 图标，区分于 AI 策略
- **空状态**：当 `customGroup.schemes.isEmpty` 时，展开它会显示一个引导卡：
  ```
  ▾ ✨ 自定义组合
    └ ┌──────────────────────────────┐
      │ 还没有自定义组合              │
      │ [去分镜库挑几个分镜试试 →]   │
      └──────────────────────────────┘
  ```
  点击 → 切换到「分镜素材库」板块（不主动开多选模式，让用户自然进入流程）
- "已修改" badge：当 `mixScheme.isManuallyEdited == true` 时显示，淡灰色小字「·已修改」
- 自定义方案的卡片不显示 strategy 名（避免冗余「自定义组合 - 自定义 #1」），仅显示方案名 + 时长 + 分镜数
- "策略数"统计：toolbar 显示 `aiStrategies.count` 而非全部（自定义组合不算策略，否则全新项目会显示"1 策略·0 视频"令人困惑）

**右键菜单的特殊处理：**

- AI 策略支持右键「重命名」「删除策略」
- 自定义组合策略**禁用**这两个操作（它是系统级容器），只能删它下面的具体方案

---

## 8. 影响面 & 风险

| 模块 | 改动 | 风险 | 缓解 |
|---|---|---|---|
| `MixScheme` | 加 1 个 Bool 字段 (`isManuallyEdited`) | 旧数据 false 默认 | 默认值兜底，无破坏 |
| `MixStrategy` | 加 1 个 Bool 字段 (`isCustomGroup`) + 老项目迁移 | 老项目可能漏建 | `MixCutApp.init()` 启动迁移 `ensureCustomGroupStrategy()` |
| `SchemeGenerationService` | AI 生成时过滤掉 `isCustomGroup` 策略 | 不过滤会让 AI 误以为要往里面填 | 在所有读策略列表的位置统一加 filter |
| `SchemeViewModel` | 新增 3 个 public 方法 + 3 个 private | 单测覆盖 | 写单元测试覆盖：插入、替换、删除最后一条、重复阻止、AI 反推失败 |
| `SchemeListView` | 加自定义方案虚拟分组 | 切项目联动 | 用 `.task(id: project.id)` 重新加载，跑 CLAUDE.md 的回归清单 |
| `SchemeDetailView` | 行间 ⊕ + 卡片 hover 按钮 + 拖拽 | 不能伤现有：序号叠加、IN/OUT 微调、台词折叠、SegmentInlinePlayer 性能 | 人工跑一遍：方案选择切换、IN/OUT 调整、播放器加载、删除按钮的 disabled 态 |
| `SegmentLibraryView` | 多选栏加按钮 | 不能伤现有：批量导出、全选/反选/清空、Equatable 性能 | 多选下回归批量导出流程，确保 selectedSegments 正常 |
| `SegmentPickerDrawer` | 全新组件 | 与素材库代码重复 | 提取 `SegmentCardCompact` 公共子组件供两边复用 |
| `SchemeGenerationService` | 新增 inferMetadata 方法 | AI 失败需要降级 | 顶部 banner + 默认名兜底；catch 后不抛 |
| `custom_scheme_inference.md` | 新增 prompt | prompt 输出 JSON 不稳定 | 用 OpenAI 兼容 API 的 `response_format: { type: "json_object" }` 限制；解析失败走兜底 |

---

## 9. 测试策略

### 9.1 单元测试（Swift Testing）

- `SchemeViewModelTests`
  - `insertSegment_atPosition3_shouldRenumberFromPosition3`
  - `insertSegment_existingSegment_shouldReturnFalseAndShowToast`
  - `replaceSegment_withSameType_shouldSucceed`
  - `replaceSegment_withSegmentAlreadyInScheme_shouldReturnFalse`
  - `removeSegment_whenOnlyOneLeft_shouldReturnFalseAndShowToast`
  - `removeSegment_normalCase_shouldRenumber`
  - `markAsEdited_onCustomScheme_shouldRemainFalse`
  - `markAsEdited_onAIScheme_shouldSetTrue`
- `SchemeGenerationServiceTests`
  - `inferMetadata_validInput_shouldReturnFiveFields`
  - `inferMetadata_aiFailure_shouldFallbackToDefault`

### 9.2 人工回归（CLAUDE.md 切项目铁律）

1. 项目 A 创建自定义方案 → 切到项目 B → B 看不到 A 的自定义方案
2. 切回 A → 自定义方案完整
3. AI 方案改一个 → 列表显示「· 已修改」
4. 删除分镜删到 1 个 → 不能再删，按钮禁用
5. 抽屉中已在方案中的分镜 → 置灰不可点
6. AI 反推失败模拟（断网） → 落默认名 + 提示 banner
7. 在自定义方案上继续编辑（再加一条）→ 不会触发 `isManuallyEdited`，但顺序确实变了

---

## 10. 开发阶段

| 阶段 | 内容 | 估时 |
|---|---|---|
| **P0** | 切独立分支 `feature/manual-scheme-editor` | 5min |
| **P1** | 数据模型加字段（备份 DB） + 老项目迁移 `ensureCustomGroupStrategy()` + SchemeViewModel 新增方法 + 单元测试 | 2.5h |
| **P2** | 场景 B：行间 ⊕ + SegmentPickerDrawer + 删除/替换按钮 + 重复防御 | 半天 |
| **P3** | 场景 A：多选工具栏 + 调整顺序 Sheet + AI 反推 prompt + Service 方法 | 半天 |
| **P4** | SchemeListView 自定义分组 + 「已编辑」badge + 切项目联动 | 2h |
| **P5** | 编译 + 人工回归（按 §9.2） + 打 Debug 包 + 打 DMG | 1h |
| **P6** | 用户验收 → 如通过则合 main + 升版本 + 双端发版（GitHub + Gitee） | 用户决定 |

**总计**：约 1.5 天净开发时间。

---

## 11. 回滚预案

- 基线：v0.2.6（commit `f068da4`）
- 开发期一切在 `feature/manual-scheme-editor` 分支上，main 不动
- 若用户验收不通过：
  - 简单路径：`git checkout main` 直接回到 v0.2.6，弃 feature 分支
  - 复杂路径：在 feature 分支上继续迭代直到满意，再合并
- 数据库：新增的两个 Bool 字段（`MixScheme.isManuallyEdited`、`MixStrategy.isCustomGroup`）有默认值，老数据库直接读取无碍；用户回退到 v0.2.6 时，SwiftData 会忽略未知字段（向下兼容）
- 用户在新版本下创建的自定义方案，回退到 v0.2.6 后：「自定义组合」策略和它下面的方案依然存在，只是会被当成"一个普通策略"显示在策略列表里（因为 v0.2.6 不认识 `isCustomGroup`）。**用户应被告知此行为**，但数据不会丢失

---

## 12. 待办（实现阶段处理）

- [ ] 创建 `feature/manual-scheme-editor` 分支
- [ ] 备份 `~/Library/Application Support/default.store` 到 `.bak`
- [ ] 在 `MixCutApp.init()` 添加 `ensureCustomGroupStrategy()` 老项目迁移（参考 `fixMissingSemanticTypes`）
- [ ] `ProjectViewModel.createProject` 内同步创建"自定义组合"策略
- [ ] 提取 `SegmentCardCompact` 公共组件供素材库 + 抽屉复用
- [ ] 编写 `custom_scheme_inference.md` prompt（含 5 个字段输出约束）
- [ ] 排查所有读策略列表的位置（`SchemeGenerationService`、`SchemeListView` 工具栏统计等），确保过滤 `isCustomGroup`

---

**Spec 结束。下一步：用 writing-plans skill 生成 step-by-step 实现计划。**
