# 撤销 / 重做（Undo / Redo）— 设计文档

- 日期：2026-06-04
- 状态：设计已确认，待写实现计划
- 标准：商业化 to C Mac 软件标准（对标剪映 / Final Cut 的撤销体验）

## 一、目标

MixCut 当前**完全没有撤销机制**。本功能提供商业级撤销/重做：

- 系统 **⌘Z 撤销 / ⌘⇧Z 重做**，接进 macOS **编辑菜单**，菜单项带操作名（"撤销 删除分镜"）。
- **多级撤销栈**，可连续 ⌘Z 一路回退、⌘⇧Z 重做。
- 覆盖**所有数据改动**：删项目/视频/分镜/方案/策略、改时间/类型、重命名、拖拽排序；AI 生成方案作为一组可整体撤销。
- 破坏性操作后弹 **Toast「已删除 ✕ · 撤销」**，点"撤销"等同 ⌘Z（照顾不用快捷键的用户，可发现性）。

## 二、核心机制

给 SwiftData 的 `ModelContext` 挂一个我们自己持有的 `UndoManager`：
- `modelContainer.mainContext.undoManager = appUndoManager`（`NSUndoManager` 实例）。
- SwiftData 会**自动**把 insert / delete / 属性变更登记进该 UndoManager，无需逐操作手写 registerUndo。
- 每个用户操作用 `appUndoManager.setActionName("删除分镜")` 命名（决定菜单/Toast 文案）。
- 多个改动属于一个逻辑操作时（如 AI 生成多个方案），用 `beginUndoGrouping` / `endUndoGrouping` 包成一组，⌘Z 一次撤销整组。
- `levelsOfUndo = 0`（不限层数）。

**决策②：单一全局撤销栈**（挂在 mainContext，全 App 共享）。⌘Z 撤销"最近一次改动"，不区分当前项目视图。不做按项目分栈（实现复杂、收益有限）。

## 三、编辑菜单与快捷键

用 SwiftUI `.commands { CommandGroup(replacing: .undoRedo) { ... } }` 自定义"撤销/重做"菜单项：
- 标题动态：`撤销\(undoManager.undoActionName.map { " " + $0 } ?? "")`、重做同理。
- 快捷键：撤销 `⌘Z`，重做 `⌘⇧Z`。
- 启用态：`disabled(!undoManager.canUndo)` / `disabled(!undoManager.canRedo)`。
- 动作：`undoManager.undo()` / `undoManager.redo()`。

> 用自定义 CommandGroup 而非依赖 `@Environment(\.undoManager)`，因为我们用的是自己挂在 mainContext 上的 UndoManager，需直接驱动它，避免响应链不确定性。

撤销/重做后需刷新当前视图数据（各 ViewModel 的 `loadXXX`），因为底层模型被回滚。统一在 undo/redo 后发一个通知（如 `.mixCutDataDidUndo`），相关视图监听并重载当前项目数据（遵守"切换项目铁律"同款重载路径）。

## 四、决策①：延后删除磁盘文件 + 垃圾回收

**问题**：现有删除会**立刻删磁盘文件**，导致即使 SwiftData 记录能撤销恢复，文件也没了（视频放不出）。

**改法**：
1. 所有删除路径**只删 SwiftData 记录，不再 inline 删文件**。涉及：
   - `ProjectViewModel.deleteProject`（原会删视频/缩略图文件）
   - `ImportViewModel.deleteVideo`
   - `SegmentLibraryViewModel.deleteSegment` / `deleteSelectedSegments`（原删分镜缩略图）
   - （`SchemeViewModel.deleteScheme/deleteStrategy/removeSegment` 本就不删磁盘文件，只删记录，天然可撤）
2. 新增**孤儿文件垃圾回收**（GC）：扫描全局视频目录 `AppSupport/MixCut/Videos/` 与缩略图目录，对每个文件检查"是否还有任何 Video/Segment 记录引用它"，**无引用的才删**。
3. GC 触发时机：**App 启动时**（数据库已加载后，在现有启动迁移序列尾部）+ **正常退出时**（`applicationWillTerminate`）。不在删除当下触发（那样就等于没延后）。

**可测纯逻辑**（放进 MixCutCore，单测）：给定"磁盘上的文件路径集合"和"数据库引用的路径集合"，计算出"应删除的孤儿路径集合"。实际文件系统扫描/删除留在 App 层（非纯逻辑，手测）。

**代价**：磁盘空间不在删除瞬间释放，而在下次启动/退出回收。用户可接受（已确认）。

## 五、Toast 撤销浮条

破坏性操作后调用 `ToastCenter` 显示带"撤销"按钮的浮条：
- 文案：`已删除\(name) · 撤销`，点"撤销"→ `appUndoManager.undo()`。
- 若 `ToastCenter` 现不支持 action 按钮，扩展其 API 增加可选 `actionTitle` + `action` 闭包（向后兼容，现有调用不传则无按钮）。
- 浮条自动消失时间沿用现有（撤销仍可走 ⌘Z）。

## 六、范围边界（YAGNI）

**可撤**：项目/视频/分镜/方案/策略的增删、分镜时间/类型/位置编辑、重命名、方案内分镜排序与增删、AI 生成（成组）。

**不纳入撤销**：
- 导入流水线的中间分析过程（下载/ASR/AI 分析）——"撤销导入"= 删除该视频，已被删除可撤覆盖；分析过程本身不做时间旅行。
- 导出（写外部文件，非数据库改动）。
- 多选/筛选/选中等纯 UI 瞬态。
- 设置项（API key、提供商）。

## 七、错误处理与边缘

- 撤销/重做后当前视图必须重载，避免显示已回滚/恢复前的陈旧数据（发通知重载）。
- 跨项目撤销：全局栈下，⌘Z 可能回滚的是其它项目的改动；撤销后若当前项目数据未变则视图无变化（可接受）。Toast 文案带操作名降低困惑。
- GC 安全：只删"确认无任何记录引用"的文件；引用判断要同时考虑 Video.localPath/thumbnailPath 与 Segment.thumbnailPath。判断不确定时**保守不删**（宁可留孤儿，不可误删在用文件）。
- 撤销一个"删除视频"后，磁盘文件因延后清理仍在，记录恢复即可正常播放——这是延后删除的目的。

## 八、测试要点

- **单测（MixCutCore）**：孤儿文件计算 `orphanFiles(onDisk:referenced:)` —— 引用全覆盖时返回空、部分引用、完全无引用、路径大小写/末尾斜杠归一。
- **手测（真机，编译后我自动重启）**：
  1. 删分镜 → ⌘Z 恢复；连续删多个 → 连续 ⌘Z 全恢复；⌘⇧Z 重做。
  2. 删项目/视频 → ⌘Z 恢复，且恢复后视频能播放（验证延后删除生效）。
  3. 改分镜时间/类型、重命名项目 → ⌘Z 撤回。
  4. AI 生成方案 → ⌘Z 一次撤掉整批。
  5. 编辑菜单显示正确的"撤销 X / 重做 X"动态标题与启用态。
  6. Toast"撤销"按钮生效。
  7. 重启后 GC 回收了已删且无引用的文件、未误删在用文件（对比删除前后磁盘）。
  8. 切项目后撤销不串数据、当前视图正确刷新。

## 九、改动清单（概览）

- `MixCutApp`：创建并持有 `appUndoManager`，赋给 `mainContext.undoManager`；`.commands` 加自定义撤销/重做菜单；启动序列尾部 + 退出时调 GC。
- 各删除路径（ProjectVM/ImportVM/SegmentLibraryVM）：移除 inline 删文件，仅删记录；删除前 `setActionName`。
- 其它可撤操作（改时间/类型/重命名/排序/生成）：在操作处 `setActionName`，生成用 undo grouping。
- `FileHelper`：新增 GC 扫描+删除孤儿（调用 MixCutCore 的纯函数判断）。
- `MixCutCore`：新增 `orphanFiles(onDisk:referenced:)` 纯函数 + 单测。
- `ToastCenter`：扩展可选 action 按钮。
- undo/redo 后的数据重载：新增通知 + 相关视图监听重载。

## 十、暂不做

- 按项目分栈的撤销。
- 撤销历史面板（可视化历史列表）。
- 导入/导出过程的撤销。
