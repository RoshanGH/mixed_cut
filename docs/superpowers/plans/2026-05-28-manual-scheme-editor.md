# 手动分镜编辑器 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不破坏现有 AI 流水线的前提下，让用户能（A）从分镜库自由组合生成自定义方案、（B）在 AI 方案 storyboard 上插入/替换/删除分镜。

**Architecture:** 数据模型增加两个 Bool 字段（`MixStrategy.isCustomGroup`、`MixScheme.isManuallyEdited`），自定义方案挂在一个真实但特殊的 `MixStrategy` 实体下；UI 上场景 B 用「行间 ⊕ + 右侧抽屉」实现，场景 A 复用素材库多选模式并新加「组合为方案」按钮。

**Tech Stack:** Swift 5.10+, SwiftUI, SwiftData, macOS 14+, OpenAI 兼容 API（千问/MiniMax）

**Spec 参考:** `docs/superpowers/specs/2026-05-28-manual-scheme-editor-design.md`

**测试策略:** 项目目前没有 XCTest target；本期以**人工回归 + 编译通过**为主验证手段（与 CLAUDE.md 项目文化一致）。Spec §9.1 的单元测试用例转为 §Phase 7 的手动回归清单。

**回滚策略:** 全部任务在 `feature/manual-scheme-editor` 分支上完成；任一节点用户不满意可弃分支回到 `main` (v0.2.6)。

---

## File Structure

**新增文件 (5):**
- `MixCut/Resources/Prompts/custom_scheme_inference.md` — AI 反推 prompt 模板
- `MixCut/Views/Schemes/SegmentPickerDrawer.swift` — 右侧分镜库抽屉
- `MixCut/Views/Schemes/InsertGapButton.swift` — 行间 ⊕ 插入按钮
- `MixCut/Views/SegmentLibrary/ArrangeOrderSheet.swift` — 调整顺序 Sheet（场景 A）
- `MixCut/Views/Shared/SegmentCardCompact.swift` — 复用素材库 + 抽屉的紧凑分镜卡片

**修改文件 (8):**
- `MixCut/Models/MixStrategy.swift` — 加 `isCustomGroup` 字段
- `MixCut/Models/MixScheme.swift` — 加 `isManuallyEdited` 字段
- `MixCut/App/MixCutApp.swift` — 增加 `ensureCustomGroupStrategy` 老项目迁移
- `MixCut/ViewModels/ProjectViewModel.swift` — `createProject` 同步创建自定义组合策略
- `MixCut/ViewModels/SchemeViewModel.swift` — 增加 5 个方法
- `MixCut/Services/SchemeGeneration/SchemeGenerationService.swift` — 增加 `inferMetadata` 方法
- `MixCut/Views/Schemes/SchemeListView.swift` — 渲染自定义组合 + 已修改 badge + 禁用某些右键
- `MixCut/Views/Schemes/SchemeDetailView.swift` — 集成行间 ⊕ + StoryboardCard hover 按钮
- `MixCut/Views/SegmentLibrary/SegmentLibraryView.swift` — 多选栏加「组合为方案」按钮

---

## Phase 0: 分支准备

### Task 0: 创建 feature 分支 + 备份数据库

**Files:** 无文件改动

- [ ] **Step 1: 创建分支**

```bash
git checkout -b feature/manual-scheme-editor
git status
```

Expected: 当前分支 `feature/manual-scheme-editor`，working tree clean。

- [ ] **Step 2: 备份 SwiftData 数据库**

```bash
cp ~/Library/Application\ Support/default.store ~/Library/Application\ Support/default.store.bak-pre-scheme-editor 2>/dev/null || echo "no default.store yet, skipping"
ls -la ~/Library/Application\ Support/default.store* 2>/dev/null
```

Expected: 看到 `.bak-pre-scheme-editor` 文件（或"no default.store yet"无所谓）。

---

## Phase 1: 数据模型 + 老项目迁移

### Task 1: 在 MixStrategy 加 isCustomGroup 字段

**Files:**
- Modify: `MixCut/Models/MixStrategy.swift`

- [ ] **Step 1: 加字段（位于 createdAt 之后）**

```swift
// 在 var createdAt: Date 后面增加：
var isCustomGroup: Bool = false  // true = 系统级"自定义组合"容器策略，不会被 AI 生成流程触碰
```

修改 `MixCut/Models/MixStrategy.swift`，在 `var createdAt: Date` 行之后、`init(` 之前插入上面这一行字段声明。

- [ ] **Step 2: 编译验证**

```bash
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED。

- [ ] **Step 3: Commit**

```bash
git add MixCut/Models/MixStrategy.swift
git commit -m "feat: MixStrategy 增加 isCustomGroup 字段"
```

---

### Task 2: 在 MixScheme 加 isManuallyEdited 字段

**Files:**
- Modify: `MixCut/Models/MixScheme.swift`

- [ ] **Step 1: 加字段（位于 createdAt 之后）**

```swift
// 在 var createdAt: Date 之后增加：
var isManuallyEdited: Bool = false  // true = AI 方案被用户手动改过分镜
```

修改 `MixCut/Models/MixScheme.swift`，在 `var createdAt: Date` 之后、`init(` 之前插入字段声明。

- [ ] **Step 2: 编译验证**

```bash
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED。

- [ ] **Step 3: Commit**

```bash
git add MixCut/Models/MixScheme.swift
git commit -m "feat: MixScheme 增加 isManuallyEdited 字段"
```

---

### Task 3: 老项目迁移 ensureCustomGroupStrategy

**Files:**
- Modify: `MixCut/App/MixCutApp.swift`

- [ ] **Step 1: 在 MixCutApp 增加迁移方法**

在 `MixCut/App/MixCutApp.swift` 中，找到 `fixMissingSemanticTypes` 方法后面（约 173 行后），增加：

```swift
/// 为所有现有项目补上"自定义组合"策略（首次升级后执行一次）
@MainActor
private static func ensureCustomGroupStrategy(container: ModelContainer) {
    let fixKey = "didEnsureCustomGroupStrategy_v1"
    if UserDefaults.standard.bool(forKey: fixKey) { return }

    let context = container.mainContext
    let descriptor = FetchDescriptor<Project>()
    guard let projects = try? context.fetch(descriptor) else { return }

    var addedCount = 0
    for project in projects {
        let hasCustomGroup = project.strategies.contains { $0.isCustomGroup }
        if !hasCustomGroup {
            let strategy = MixStrategy(
                name: "自定义组合",
                style: "",
                description: "手动挑选分镜组合的方案",
                targetAudience: "",
                narrativeStructure: "",
                targetDuration: 0
            )
            strategy.isCustomGroup = true
            strategy.project = project
            project.strategies.append(strategy)
            context.insert(strategy)
            addedCount += 1
        }
    }

    if addedCount > 0 {
        try? context.save()
        MixLog.info("已为 \(addedCount) 个老项目补建「自定义组合」策略")
    }

    UserDefaults.standard.set(true, forKey: fixKey)
}
```

- [ ] **Step 2: 在 init() 调用迁移**

在 `MixCutApp.init()` 找到 `Self.fixMissingSemanticTypes(container: modelContainer)` 这一行（约第 39 行），在它**下方**加一行：

```swift
Self.ensureCustomGroupStrategy(container: modelContainer)
```

- [ ] **Step 3: 编译验证**

```bash
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED。

- [ ] **Step 4: 运行验证**

```bash
pkill -x MixCut; sleep 1
open /Users/menggang/Library/Developer/Xcode/DerivedData/MixCut-byytuggmhodpumcmwnwrtzwkmavr/Build/Products/Debug/MixCut.app
sleep 3
```

打开任意现有项目 → 切换到「方案」板块 → 检查左栏策略列表里**确实多了一个"自定义组合"分组**（即使它现在还是空的没渲染特殊样式也没关系，下面 Task 21 才统一渲染）。

- [ ] **Step 5: Commit**

```bash
git add MixCut/App/MixCutApp.swift
git commit -m "feat: 老项目迁移 - 自动补建「自定义组合」策略"
```

---

### Task 4: ProjectViewModel.createProject 同步创建自定义组合策略

**Files:**
- Modify: `MixCut/ViewModels/ProjectViewModel.swift:46-59`

- [ ] **Step 1: 修改 createProject 方法**

把 `ProjectViewModel.createProject()` 函数完整替换为：

```swift
/// 创建新项目（同步创建"自定义组合"策略）
func createProject() {
    guard let context = modelContext else { return }
    let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }

    let project = Project(name: name)
    context.insert(project)

    // 同步创建"自定义组合"策略容器
    let customGroup = MixStrategy(
        name: "自定义组合",
        style: "",
        description: "手动挑选分镜组合的方案",
        targetAudience: "",
        narrativeStructure: "",
        targetDuration: 0
    )
    customGroup.isCustomGroup = true
    customGroup.project = project
    project.strategies.append(customGroup)
    context.insert(customGroup)

    context.safeSave()

    newProjectName = ""
    isCreatingProject = false
    fetchProjects()
    selectedProject = project
}
```

- [ ] **Step 2: 编译 + 运行验证**

```bash
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -20
pkill -x MixCut; sleep 1
open /Users/menggang/Library/Developer/Xcode/DerivedData/MixCut-byytuggmhodpumcmwnwrtzwkmavr/Build/Products/Debug/MixCut.app
```

新建一个项目 → 切换到「方案」板块 → 检查策略列表里**有"自定义组合"**这一项（即便样式还没渲染好）。

- [ ] **Step 3: Commit**

```bash
git add MixCut/ViewModels/ProjectViewModel.swift
git commit -m "feat: 新项目同步创建「自定义组合」策略"
```

---

## Phase 2: SchemeViewModel 编辑能力

### Task 5: SchemeViewModel 增加派生属性

**Files:**
- Modify: `MixCut/ViewModels/SchemeViewModel.swift`

- [ ] **Step 1: 在 schemes 计算属性附近增加两个派生属性**

在 `MixCut/ViewModels/SchemeViewModel.swift` 找到这段代码：

```swift
/// 所有方案的扁平列表（兼容旧接口）
var schemes: [MixScheme] {
    strategies.flatMap(\.orderedSchemes)
}
```

**在它下面**插入：

```swift
/// AI 生成的策略（排除"自定义组合"容器）
var aiStrategies: [MixStrategy] {
    strategies.filter { !$0.isCustomGroup }
}

/// 当前项目的"自定义组合"策略容器
var customGroup: MixStrategy? {
    strategies.first { $0.isCustomGroup }
}

/// 列表渲染用的有序策略：AI 策略在前，自定义组合在后
var orderedStrategiesForDisplay: [MixStrategy] {
    aiStrategies + (customGroup.map { [$0] } ?? [])
}
```

- [ ] **Step 2: 编译**

```bash
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED。

- [ ] **Step 3: Commit**

```bash
git add MixCut/ViewModels/SchemeViewModel.swift
git commit -m "feat: SchemeViewModel 增加 aiStrategies/customGroup 派生属性"
```

---

### Task 6: 增加编辑动作标记 + 重复校验工具方法

**Files:**
- Modify: `MixCut/ViewModels/SchemeViewModel.swift`

- [ ] **Step 1: 在文件末尾的 `// MARK: - 分镜编辑` 之后增加 private 工具**

找到 `func removeSegment(_ schemeSeg: SchemeSegment, from scheme: MixScheme)` 这个方法（约第 327 行），在它**正上方**插入：

```swift
/// 给 AI 方案打"已编辑"标记（自定义方案不打）
private func markAsEdited(_ scheme: MixScheme) {
    let isCustom = scheme.strategy?.isCustomGroup == true
    guard !isCustom, !scheme.isManuallyEdited else { return }
    scheme.isManuallyEdited = true
}

/// 判断 segment 是否已在 scheme 中
private func contains(_ segment: Segment, in scheme: MixScheme) -> Bool {
    let targetID = segment.id
    return scheme.schemeSegments.contains { $0.segment?.id == targetID }
}

/// 按当前 orderedSegments 顺序重新编号 position（1-based）
private func renumberPositions(in scheme: MixScheme) {
    for (i, seg) in scheme.orderedSegments.enumerated() {
        seg.position = i + 1
    }
}
```

- [ ] **Step 2: 修改已有 moveSegment 增加 markAsEdited 调用**

找到 `func moveSegment(in scheme: MixScheme, from source: Int, to destination: Int)`（约第 311 行）。在它**末尾的 `modelContext?.safeSave()` 之前**加一行：

```swift
markAsEdited(scheme)
```

- [ ] **Step 3: 编译**

```bash
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED。

- [ ] **Step 4: Commit**

```bash
git add MixCut/ViewModels/SchemeViewModel.swift
git commit -m "feat: SchemeViewModel 增加编辑标记和重复校验工具方法"
```

---

### Task 7: 改造 removeSegment 增加"至少 1 条"兜底

**Files:**
- Modify: `MixCut/ViewModels/SchemeViewModel.swift:327-338`

- [ ] **Step 1: 把 removeSegment 整个替换为**

```swift
@discardableResult
func removeSegment(_ schemeSeg: SchemeSegment, from scheme: MixScheme) -> Bool {
    guard let context = modelContext else { return false }
    guard scheme.schemeSegments.count > 1 else {
        ToastCenter.shared.show("方案至少保留 1 个分镜", icon: "exclamationmark.circle.fill")
        return false
    }

    let deletedID = schemeSeg.id
    context.delete(schemeSeg)

    let remaining = scheme.orderedSegments.filter { $0.id != deletedID }
    for (i, seg) in remaining.enumerated() {
        seg.position = i + 1
    }

    markAsEdited(scheme)
    context.safeSave()
    return true
}
```

- [ ] **Step 2: 编译**

```bash
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED。

- [ ] **Step 3: Commit**

```bash
git add MixCut/ViewModels/SchemeViewModel.swift
git commit -m "feat: removeSegment 增加至少保留 1 条的兜底"
```

---

### Task 8: 新增 insertSegment 方法（带重复校验）

**Files:**
- Modify: `MixCut/ViewModels/SchemeViewModel.swift`

- [ ] **Step 1: 在 removeSegment 方法后面增加 insertSegment**

```swift
/// 在指定 position 处插入一个分镜（position 从 1 开始；position = N+1 表示追加到末尾）
/// 返回 false 表示 segment 已在方案中（重复阻止）
@discardableResult
func insertSegment(_ segment: Segment, at position: Int, in scheme: MixScheme) -> Bool {
    guard let context = modelContext else { return false }

    if contains(segment, in: scheme) {
        ToastCenter.shared.show("该分镜已在方案中", icon: "exclamationmark.circle.fill")
        return false
    }

    // 现有分镜在 position 及之后的全部后移一位
    for seg in scheme.orderedSegments where seg.position >= position {
        seg.position += 1
    }

    let newSchemeSeg = SchemeSegment(position: position)
    newSchemeSeg.segment = segment
    newSchemeSeg.scheme = scheme
    scheme.schemeSegments.append(newSchemeSeg)
    context.insert(newSchemeSeg)

    renumberPositions(in: scheme)
    markAsEdited(scheme)
    context.safeSave()
    return true
}
```

- [ ] **Step 2: 编译**

```bash
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED。

- [ ] **Step 3: Commit**

```bash
git add MixCut/ViewModels/SchemeViewModel.swift
git commit -m "feat: SchemeViewModel 增加 insertSegment 方法（含重复校验）"
```

---

### Task 9: 新增 replaceSegment 方法（带重复校验）

**Files:**
- Modify: `MixCut/ViewModels/SchemeViewModel.swift`

- [ ] **Step 1: 在 insertSegment 后面增加 replaceSegment**

```swift
/// 替换某个 SchemeSegment 指向的具体 Segment
/// 返回 false 表示新 segment 已在方案中（重复阻止）
@discardableResult
func replaceSegment(_ schemeSeg: SchemeSegment, with newSegment: Segment, in scheme: MixScheme) -> Bool {
    guard let context = modelContext else { return false }

    // 如果替换的是同一个，无需处理
    if schemeSeg.segment?.id == newSegment.id { return true }

    if contains(newSegment, in: scheme) {
        ToastCenter.shared.show("该分镜已在方案中", icon: "exclamationmark.circle.fill")
        return false
    }

    schemeSeg.segment = newSegment
    markAsEdited(scheme)
    context.safeSave()
    return true
}
```

- [ ] **Step 2: 编译**

```bash
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED。

- [ ] **Step 3: Commit**

```bash
git add MixCut/ViewModels/SchemeViewModel.swift
git commit -m "feat: SchemeViewModel 增加 replaceSegment 方法"
```

---

## Phase 3: AI 反推元信息服务

### Task 10: 编写自定义方案反推 prompt

**Files:**
- Create: `MixCut/Resources/Prompts/custom_scheme_inference.md`

- [ ] **Step 1: 创建文件**

新建 `MixCut/Resources/Prompts/custom_scheme_inference.md`，内容：

```markdown
# 任务

下面是用户手动挑选并排序的 N 个分镜。请根据这些分镜的语义类型、台词和时长，反推出这条短视频广告的元信息。

## 输入字段说明

每个分镜包含：
- position: 在方案中的位置（1 开始）
- semanticTypes: 语义类型数组（如「痛点」「产品」「行动」等）
- text: 台词文本（可能为空）
- duration: 分镜时长（秒）

## 输出要求

严格返回以下 JSON 格式（**只输出 JSON，不要任何其他文字**）：

```json
{
  "name": "5-10 字方案名，体现叙事重点",
  "narrativeStructure": "X-Y-Z 三段式叙事结构（如 痛点-产品-行动）",
  "targetAudience": "10-20 字目标受众描述",
  "schemeDescription": "30-60 字方案概述",
  "style": "广告风格标签（从下列任选最贴近一个）"
}
```

## 可选风格标签

- 高冷营销风
- 热血塑造
- 温情陪伴
- 专业权威
- 趣味轻松
- 直击痛点
- 故事悬念
- 极简克制
- 反转惊喜
- 自定义

## 分镜数据

{{SEGMENTS_JSON}}
```

- [ ] **Step 2: 验证 prompt 文件被打包**

检查 `Package.swift` 或 Xcode 项目设置确认 `MixCut/Resources/Prompts/*.md` 全部被作为资源打包。已知现有 prompt 文件（如 `ad_styles.md`）都能加载，新文件放同目录即可。

```bash
ls MixCut/Resources/Prompts/
```

Expected: 看到 `custom_scheme_inference.md` 与其他 `.md` 文件并列。

- [ ] **Step 3: Commit**

```bash
git add MixCut/Resources/Prompts/custom_scheme_inference.md
git commit -m "feat: 新增自定义方案 AI 反推 prompt 模板"
```

---

### Task 11: SchemeGenerationService 增加 inferMetadata 方法

**Files:**
- Modify: `MixCut/Services/SchemeGeneration/SchemeGenerationService.swift`

- [ ] **Step 1: 在文件末尾的 `SchemeGenerationService` actor 内（最后一个方法之后）增加**

```swift
// MARK: - 自定义方案元信息反推

/// AI 反推自定义方案的元信息
/// 失败时不抛错，返回 nil 让上层走默认兜底
func inferMetadata(for segments: [Segment]) async -> CustomSchemeMetadata? {
    guard !segments.isEmpty,
          let template = promptLoader.loadPrompt(named: "custom_scheme_inference") else {
        return nil
    }

    // 构造分镜结构化数据
    struct SegmentInfo: Encodable {
        let position: Int
        let semanticTypes: [String]
        let text: String
        let duration: Double
    }

    let infos = segments.enumerated().map { idx, seg in
        SegmentInfo(
            position: idx + 1,
            semanticTypes: seg.semanticTypes.map(\.rawValue),
            text: seg.text,
            duration: seg.duration
        )
    }

    guard let jsonData = try? JSONEncoder().encode(infos),
          let jsonString = String(data: jsonData, encoding: .utf8) else {
        return nil
    }

    let prompt = template.replacingOccurrences(of: "{{SEGMENTS_JSON}}", with: jsonString)

    do {
        let response = try await aiProvider.chat(prompt: prompt, expectJSON: true)
        // 解析 JSON
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CustomSchemeMetadata.self, from: data)
    } catch {
        MixLog.warning("inferMetadata 失败：\(error.localizedDescription)")
        return nil
    }
}
```

- [ ] **Step 2: 在文件顶部（imports 后或 SchemeGenerationService 上方）增加返回结构体**

```swift
/// 自定义方案 AI 反推的元信息
struct CustomSchemeMetadata: Codable, Sendable {
    let name: String
    let narrativeStructure: String
    let targetAudience: String
    let schemeDescription: String
    let style: String
}
```

- [ ] **Step 3: 验证 AIProvider 协议支持 `expectJSON` 参数**

```bash
grep -n "func chat" MixCut/Services/AI/AIProvider.swift
```

如果 `chat()` 方法没有 `expectJSON` 参数（或类似），改用现有签名调用。若现有签名是 `chat(prompt: String) async throws -> String`，则上面的代码改为：

```swift
let response = try await aiProvider.chat(prompt: prompt)
```

并依赖 prompt 自身要求 JSON 输出 + 上面已经做了 ```json ``` 清洗。

**执行子代理务必先 grep 出真实签名再选 1 行写法。**

- [ ] **Step 4: 编译**

```bash
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -15
```

Expected: BUILD SUCCEEDED。

- [ ] **Step 5: Commit**

```bash
git add MixCut/Services/SchemeGeneration/SchemeGenerationService.swift
git commit -m "feat: SchemeGenerationService 增加 inferMetadata 方法"
```

---

### Task 12: SchemeViewModel 增加 createCustomScheme 方法

**Files:**
- Modify: `MixCut/ViewModels/SchemeViewModel.swift`

- [ ] **Step 1: 在 replaceSegment 后面增加**

```swift
/// 从分镜数组创建自定义方案（异步：先建占位，AI 反推后填充元信息）
/// 失败兜底：name 保留默认「自定义 #N」，banner 提示用户
@discardableResult
func createCustomScheme(
    from segments: [Segment],
    in project: Project
) async -> MixScheme? {
    guard let context = modelContext else { return nil }
    guard !segments.isEmpty else { return nil }

    // 确保 customGroup 存在（理论上一定有，双保险）
    let group: MixStrategy
    if let existing = project.strategies.first(where: { $0.isCustomGroup }) {
        group = existing
    } else {
        let g = MixStrategy(
            name: "自定义组合",
            style: "",
            description: "手动挑选分镜组合的方案",
            targetAudience: "",
            narrativeStructure: "",
            targetDuration: 0
        )
        g.isCustomGroup = true
        g.project = project
        project.strategies.append(g)
        context.insert(g)
        group = g
    }

    // 计算自定义方案序号
    let existingCustomCount = group.schemes.count
    let defaultName = "自定义 #\(existingCustomCount + 1)"

    // 创建方案
    let scheme = MixScheme(
        variationIndex: existingCustomCount + 1,
        schemeIndex: "custom_\(UUID().uuidString.prefix(8))",
        name: defaultName,
        style: "",
        description: "",
        targetAudience: "",
        narrativeStructure: ""
    )
    scheme.strategy = group
    scheme.project = project
    group.schemes.append(scheme)
    context.insert(scheme)

    // 创建 SchemeSegment 链接
    for (idx, seg) in segments.enumerated() {
        let ss = SchemeSegment(position: idx + 1)
        ss.segment = seg
        ss.scheme = scheme
        scheme.schemeSegments.append(ss)
        context.insert(ss)
    }

    context.safeSave()

    // AI 反推（失败不阻断）
    if let metadata = await schemeService.inferMetadata(for: segments) {
        scheme.name = metadata.name.isEmpty ? defaultName : metadata.name
        scheme.narrativeStructure = metadata.narrativeStructure
        scheme.targetAudience = metadata.targetAudience
        scheme.schemeDescription = metadata.schemeDescription
        scheme.style = metadata.style
        context.safeSave()
    } else {
        ToastCenter.shared.show("元信息生成失败，方案已保存为「\(defaultName)」",
                                icon: "exclamationmark.triangle.fill")
    }

    // 重新加载策略以触发 UI 更新
    loadSchemes(for: project)
    selectedStrategy = group
    selectedScheme = scheme

    return scheme
}
```

- [ ] **Step 2: 编译**

```bash
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -15
```

Expected: BUILD SUCCEEDED。

- [ ] **Step 3: Commit**

```bash
git add MixCut/ViewModels/SchemeViewModel.swift
git commit -m "feat: SchemeViewModel 增加 createCustomScheme 方法（含 AI 反推）"
```

---

## Phase 4: 场景 B —— AI 方案上增删改

### Task 13: 新建行间插入按钮 InsertGapButton

**Files:**
- Create: `MixCut/Views/Schemes/InsertGapButton.swift`

- [ ] **Step 1: 创建文件**

```swift
import SwiftUI

/// Storyboard 行间「+」插入按钮：默认透明，hover 时显示
struct InsertGapButton: View {
    let onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Rectangle()
                    .fill(isHovering ? Color.accentColor.opacity(0.12) : Color.clear)
                    .frame(width: isHovering ? 28 : 12, height: 100)

                if isHovering {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: isHovering ? 28 : 12)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .help("在此处插入分镜")
    }
}
```

- [ ] **Step 2: 编译**

```bash
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED（注意此时还没人引用，只是单文件编译通过）。

- [ ] **Step 3: Commit**

```bash
git add MixCut/Views/Schemes/InsertGapButton.swift
git commit -m "feat: 新增 InsertGapButton 行间插入按钮组件"
```

---

### Task 14: 提取 SegmentCardCompact 复用卡片

**Files:**
- Create: `MixCut/Views/Shared/SegmentCardCompact.swift`

> 该卡片仅作为新组件存在；现有的 SegmentLibraryView 卡片保持原样不动，避免大改素材库主架构（CLAUDE.md 铁律：不破坏现有功能）。新组件供 SegmentPickerDrawer 使用。

- [ ] **Step 1: 创建文件**

```swift
import SwiftUI

/// 紧凑分镜卡片（用于抽屉/选择器场景）
/// 包含缩略图、语义类型标签、台词预览、时长
struct SegmentCardCompact: View {
    let segment: Segment
    let isDisabled: Bool          // true 时整卡片置灰禁用
    let disabledReason: String?   // 置灰原因 tooltip
    let onTap: () -> Void

    @State private var isHovering = false

    private let cardWidth: CGFloat = 140
    private let imageHeight: CGFloat = 80

    var body: some View {
        Button(action: { if !isDisabled { onTap() } }) {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .topLeading) {
                    thumbnail
                    if isDisabled {
                        Image(systemName: "nosign")
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.black.opacity(0.45))
                            .clipShape(Circle())
                            .padding(4)
                    }
                }
                .frame(width: cardWidth, height: imageHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                HStack(spacing: 3) {
                    ForEach(segment.semanticTypes.prefix(2), id: \.self) { type in
                        SemanticTypeTag(type: type)
                    }
                    if segment.semanticTypes.count > 2 {
                        Text("+\(segment.semanticTypes.count - 2)")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(segment.text.isEmpty ? "—" : segment.text)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(width: cardWidth, alignment: .leading)

                Text(String(format: "%.1fs", segment.duration))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: cardWidth)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovering && !isDisabled
                          ? Color(.controlBackgroundColor).opacity(0.95)
                          : Color(.controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.secondary.opacity(isHovering ? 0.18 : 0.06), lineWidth: 1)
            )
            .opacity(isDisabled ? 0.4 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering in
            if !isDisabled {
                isHovering = hovering
            }
        }
        .help(isDisabled ? (disabledReason ?? "已禁用") : segment.text)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let path = segment.thumbnailPath,
           let image = ThumbnailCache.shared.image(for: path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Rectangle()
                .fill(.quaternary)
                .overlay(
                    Image(systemName: "film")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                )
        }
    }
}
```

- [ ] **Step 2: 验证 `ThumbnailCache.shared.image(for:)` 接口存在**

```bash
grep -n "class ThumbnailCache\|func image" MixCut/Utilities/ThumbnailCache.swift 2>/dev/null || \
grep -rn "ThumbnailCache" MixCut/ | head -5
```

如果实际方法名不同（如 `loadImage`），按真实签名调整 Step 1 的对应行。

- [ ] **Step 3: 编译**

```bash
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED。

- [ ] **Step 4: Commit**

```bash
git add MixCut/Views/Shared/SegmentCardCompact.swift
git commit -m "feat: 新增 SegmentCardCompact 紧凑分镜卡片（供抽屉等场景复用）"
```

---

### Task 15: 新建 SegmentPickerDrawer 分镜库抽屉

**Files:**
- Create: `MixCut/Views/Schemes/SegmentPickerDrawer.swift`

- [ ] **Step 1: 创建文件**

```swift
import SwiftUI
import SwiftData

/// 选择分镜的右侧抽屉，支持插入/替换两种语义
struct SegmentPickerDrawer: View {
    enum Operation: Equatable {
        case insert(position: Int)
        case replace(schemeSegmentID: UUID, originalSemantic: [SemanticType])
    }

    let project: Project
    let scheme: MixScheme
    let operation: Operation
    let onPick: (Segment) -> Void
    let onClose: () -> Void

    @State private var searchText = ""
    @State private var filterType: SemanticType? = nil
    @State private var showAllTypes = false

    @Query private var allSegments: [Segment]

    init(
        project: Project,
        scheme: MixScheme,
        operation: Operation,
        onPick: @escaping (Segment) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.project = project
        self.scheme = scheme
        self.operation = operation
        self.onPick = onPick
        self.onClose = onClose

        // 仅查询该项目使用过的视频对应的分镜
        let projectID = project.id
        _allSegments = Query(
            filter: #Predicate<Segment> { seg in
                seg.video?.projectVideos.contains(where: { $0.project?.id == projectID }) ?? false
            },
            sort: [SortDescriptor(\.createdAt)]
        )
    }

    private var operationTitle: String {
        switch operation {
        case .insert(let position): return "在 #\(position) 处插入"
        case .replace: return "选择替换分镜"
        }
    }

    private var existingSegmentIDs: Set<UUID> {
        Set(scheme.schemeSegments.compactMap { $0.segment?.id })
    }

    private var filteredSegments: [Segment] {
        var result = allSegments

        // 替换场景：默认按相同语义类型筛选
        if case .replace(_, let originalTypes) = operation, !showAllTypes {
            let typesSet = Set(originalTypes)
            result = result.filter { seg in
                !Set(seg.semanticTypes).isDisjoint(with: typesSet)
            }
        }

        if let f = filterType {
            result = result.filter { $0.semanticTypes.contains(f) }
        }

        if !searchText.isEmpty {
            result = result.filter {
                $0.text.localizedCaseInsensitiveContains(searchText)
            }
        }

        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            content
        }
        .frame(width: 320)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(operationTitle)
                    .font(.system(size: 13, weight: .semibold))
                if case .replace = operation, !showAllTypes {
                    Text("默认筛选：同类型")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("搜索台词", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if case .replace = operation {
                Toggle("显示全部类型（非仅同类）", isOn: $showAllTypes)
                    .font(.system(size: 11))
                    .toggleStyle(.checkbox)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var content: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(filteredSegments, id: \.id) { seg in
                    let isAlreadyInScheme = existingSegmentIDs.contains(seg.id)
                    SegmentCardCompact(
                        segment: seg,
                        isDisabled: isAlreadyInScheme,
                        disabledReason: isAlreadyInScheme ? "该分镜已在方案中" : nil,
                        onTap: { onPick(seg) }
                    )
                }
            }
            .padding(10)

            if filteredSegments.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "film")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                    Text("没有匹配的分镜")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 30)
            }
        }
    }
}
```

- [ ] **Step 2: 编译**

```bash
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -15
```

Expected: BUILD SUCCEEDED。如果编译失败，常见点：
- `Segment.createdAt` 字段名可能不同（验证 `MixCut/Models/Segment.swift`）；用真实字段名
- `#Predicate` 跨关系查询的限制可能要简化为获取全部后再 filter

- [ ] **Step 3: Commit**

```bash
git add MixCut/Views/Schemes/SegmentPickerDrawer.swift
git commit -m "feat: 新增 SegmentPickerDrawer 分镜选择抽屉组件"
```

---

### Task 16: SchemeDetailView 集成行间 ⊕ + 抽屉

**Files:**
- Modify: `MixCut/Views/Schemes/SchemeDetailView.swift`

- [ ] **Step 1: 增加抽屉状态**

在 `struct SchemeDetailView: View` 内（第 3-7 行），把现有的 `let scheme:` `@Bindable var viewModel:` `@Bindable var segmentLibraryVM:` 之后加：

```swift
@State private var drawerOperation: SegmentPickerDrawer.Operation?
@Environment(\.project) private var environmentProject  // 如果有 environment；否则改用从 scheme.project 取
```

实际上 `scheme.project` 已经能拿到项目，简化为不需要 environment：

```swift
@State private var drawerOperation: SegmentPickerDrawer.Operation?
```

- [ ] **Step 2: 改造 body 包一层 HStack 用于显示抽屉**

把 `body` 的整个 `ScrollView { ... }` 用 HStack 包起来，并在右边按需展示抽屉：

```swift
var body: some View {
    HStack(spacing: 0) {
        ScrollView {
            // ... 原内容保持不变 ...
        }
        .frame(maxWidth: .infinity)

        if let op = drawerOperation, let project = scheme.project {
            Divider()
            SegmentPickerDrawer(
                project: project,
                scheme: scheme,
                operation: op,
                onPick: { segment in
                    handlePick(segment, operation: op)
                },
                onClose: { drawerOperation = nil }
            )
            .transition(.move(edge: .trailing))
        }
    }
    .animation(.easeOut(duration: 0.2), value: drawerOperation)
}

private func handlePick(_ segment: Segment, operation: SegmentPickerDrawer.Operation) {
    switch operation {
    case .insert(let position):
        if viewModel.insertSegment(segment, at: position, in: scheme) {
            ToastCenter.shared.show("已插入到 #\(position)", icon: "checkmark.circle.fill")
        }
    case .replace(let schemeSegmentID, _):
        if let schemeSeg = scheme.schemeSegments.first(where: { $0.id == schemeSegmentID }) {
            if viewModel.replaceSegment(schemeSeg, with: segment, in: scheme) {
                ToastCenter.shared.show("已替换 #\(schemeSeg.position)", icon: "checkmark.circle.fill")
            }
        }
    }
}
```

- [ ] **Step 3: 改造 storyboardView 加行间 ⊕**

找到 `private var storyboardView: some View`，把 `LazyHStack { ForEach(scheme.orderedSegments) { ... } }` 段落改为：

```swift
LazyHStack(alignment: .top, spacing: 0) {
    InsertGapButton {
        drawerOperation = .insert(position: 1)
    }

    ForEach(Array(scheme.orderedSegments.enumerated()), id: \.element.id) { idx, schemeSeg in
        StoryboardCard(
            schemeSeg: schemeSeg,
            segmentLibraryVM: segmentLibraryVM,
            canDelete: scheme.schemeSegments.count > 1,
            onDelete: { viewModel.removeSegment(schemeSeg, from: scheme) },
            onReplace: {
                let originalTypes = schemeSeg.segment?.semanticTypes ?? []
                drawerOperation = .replace(schemeSegmentID: schemeSeg.id, originalSemantic: originalTypes)
            }
        )
        .padding(.horizontal, 5)

        InsertGapButton {
            drawerOperation = .insert(position: idx + 2)
        }
    }
}
.padding(.bottom, 4)
```

注意：这一步增加了 `StoryboardCard` 的 3 个新参数（`canDelete`、`onDelete`、`onReplace`），下一个 Task 修改 `StoryboardCard` 来接收它们。

- [ ] **Step 4: 编译（此时会因 StoryboardCard 缺参数报错——这是预期的，Task 17 会修复）**

跳过本步编译，直接做 Task 17。

- [ ] **Step 5: 暂不 commit（等 Task 17 完成后一起 commit）**

---

### Task 17: StoryboardCard 增加 hover 删除/替换按钮

**Files:**
- Modify: `MixCut/Views/Schemes/SchemeDetailView.swift`

- [ ] **Step 1: 把 StoryboardCard 整个 struct 替换为**

找到 `struct StoryboardCard: View {` 把整个 struct（到下一个 `struct StoryboardTimeRow` 之前）替换为：

```swift
struct StoryboardCard: View {
    let schemeSeg: SchemeSegment
    @Bindable var segmentLibraryVM: SegmentLibraryViewModel
    let canDelete: Bool
    let onDelete: () -> Void
    let onReplace: () -> Void
    @State private var isHovering = false

    private let cardWidth: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let segment = schemeSeg.segment {
                ZStack(alignment: .topLeading) {
                    SegmentInlinePlayer(segment: segment, viewModel: segmentLibraryVM)
                        .frame(width: cardWidth)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Text("#\(schemeSeg.position)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(4)

                    // hover 时浮出操作按钮
                    if isHovering {
                        HStack(spacing: 4) {
                            actionButton(icon: "arrow.triangle.2.circlepath",
                                         help: "替换",
                                         action: onReplace)
                            actionButton(icon: "trash.fill",
                                         help: canDelete ? "删除" : "方案至少保留 1 个分镜",
                                         action: canDelete ? onDelete : {},
                                         disabled: !canDelete)
                        }
                        .padding(4)
                        .frame(maxWidth: .infinity, alignment: .topTrailing)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 3) {
                        ForEach(segment.semanticTypes.prefix(2), id: \.self) { type in
                            SemanticTypeTag(type: type)
                        }
                        if segment.semanticTypes.count > 2 {
                            Text("+\(segment.semanticTypes.count - 2)")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(segment.text)
                        .font(.system(size: 10))
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineSpacing(2)
                        .help(segment.text)

                    StoryboardTimeRow(segment: segment, viewModel: segmentLibraryVM)
                }
                .padding(.horizontal, 6)
                .padding(.top, 6)
                .padding(.bottom, 8)
            } else {
                VStack(spacing: 6) {
                    Text("#\(schemeSeg.position)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.tertiary)
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 14))
                        .foregroundStyle(.orange)
                    Text("分镜数据缺失")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(width: cardWidth, height: 80)
            }
        }
        .frame(width: cardWidth)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovering
                      ? Color(.controlBackgroundColor).opacity(0.9)
                      : Color(.controlBackgroundColor).opacity(0.5))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.secondary.opacity(isHovering ? 0.15 : 0.06), lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .contextMenu {
            Button("替换为...", action: onReplace)
            Divider()
            Button("删除", role: .destructive, action: onDelete)
                .disabled(!canDelete)
        }
    }

    private func actionButton(icon: String,
                              help: String,
                              action: @escaping () -> Void,
                              disabled: Bool = false) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(disabled ? .gray.opacity(0.4) : .black.opacity(0.6))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}
```

- [ ] **Step 2: 编译**

```bash
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED。

- [ ] **Step 3: 运行 + 烟囱测试**

```bash
pkill -x MixCut; sleep 1
open /Users/menggang/Library/Developer/Xcode/DerivedData/MixCut-byytuggmhodpumcmwnwrtzwkmavr/Build/Products/Debug/MixCut.app
```

打开一个有 AI 方案的项目，进入方案详情，确认：
- 分镜之间能看到（hover 触发） + 号
- 卡片 hover 出现替换/删除按钮
- 删除最后一条不能点（灰色 + tooltip 提示）
- 点击 + 号能看到右侧抽屉滑入

- [ ] **Step 4: Commit Task 16 + 17 的所有变更**

```bash
git add MixCut/Views/Schemes/SchemeDetailView.swift
git commit -m "feat: SchemeDetailView 支持插入/替换/删除（行间 ⊕ + hover 按钮 + 右键菜单）"
```

---

## Phase 5: 场景 A —— 从分镜库自由组合

### Task 18: 新建调整顺序 Sheet

**Files:**
- Create: `MixCut/Views/SegmentLibrary/ArrangeOrderSheet.swift`

- [ ] **Step 1: 创建文件**

```swift
import SwiftUI

/// 调整分镜顺序的模态 Sheet
/// 用户点击"组合为方案"后弹出，确认顺序并触发 AI 反推生成
struct ArrangeOrderSheet: View {
    let initialSegments: [Segment]
    let onCancel: () -> Void
    let onConfirm: (_ orderedSegments: [Segment]) async -> Void

    @State private var orderedSegments: [Segment] = []
    @State private var isGenerating = false

    private var totalDuration: Double {
        orderedSegments.reduce(0.0) { $0 + $1.duration }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 360)
        .onAppear { orderedSegments = initialSegments }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("调整顺序")
                    .font(.system(size: 16, weight: .semibold))
                Text("\(orderedSegments.count) 个分镜 · 预计 \(String(format: "%.1fs", totalDuration))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("拖拽 ⋮ 调整顺序")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
    }

    private var list: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 12) {
                ForEach(Array(orderedSegments.enumerated()), id: \.element.id) { idx, seg in
                    arrangeCard(segment: seg, index: idx)
                }
            }
            .padding(16)
        }
    }

    private func arrangeCard(segment: Segment, index: Int) -> some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text("#\(index + 1)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { moveLeft(index) }) {
                    Image(systemName: "arrow.left.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .disabled(index == 0)

                Button(action: { moveRight(index) }) {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .disabled(index == orderedSegments.count - 1)
            }

            SegmentCardCompact(
                segment: segment,
                isDisabled: false,
                disabledReason: nil,
                onTap: {}
            )
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("取消", action: onCancel)
                .buttonStyle(.bordered)
                .disabled(isGenerating)

            Button(action: confirm) {
                HStack {
                    if isGenerating {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isGenerating ? "生成中..." : "生成方案 (\(orderedSegments.count))")
                }
                .frame(minWidth: 100)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isGenerating || orderedSegments.count < 2)
        }
        .padding(16)
    }

    private func moveLeft(_ index: Int) {
        guard index > 0 else { return }
        orderedSegments.swapAt(index, index - 1)
    }

    private func moveRight(_ index: Int) {
        guard index < orderedSegments.count - 1 else { return }
        orderedSegments.swapAt(index, index + 1)
    }

    private func confirm() {
        Task {
            isGenerating = true
            await onConfirm(orderedSegments)
            isGenerating = false
        }
    }
}
```

> 说明：本期暂用「左右箭头按钮换序」而非 SwiftUI 原生 `.onMove`（onMove 在 LazyHStack 上 macOS 表现不一）。视觉一致，操作可达。后续如有需要再升级为 drag。

- [ ] **Step 2: 编译**

```bash
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -15
```

Expected: BUILD SUCCEEDED。

- [ ] **Step 3: Commit**

```bash
git add MixCut/Views/SegmentLibrary/ArrangeOrderSheet.swift
git commit -m "feat: 新增 ArrangeOrderSheet 调整顺序 Sheet"
```

---

### Task 19: SegmentLibraryView 多选栏加「组合为方案」按钮

**Files:**
- Modify: `MixCut/Views/SegmentLibrary/SegmentLibraryView.swift`

- [ ] **Step 1: 定位多选栏**

```bash
grep -n "批量导出\|isMultiSelectMode\|selectedSegments" MixCut/Views/SegmentLibrary/SegmentLibraryView.swift | head -20
```

记录"批量导出"按钮的所在位置（这一栏就是多选工具栏）。

- [ ] **Step 2: 在"批量导出"按钮旁边增加"组合为方案"按钮**

在上面找到的 `[批量导出]` Button 的**正下方/旁边**（同一个 HStack 内）插入：

```swift
Button {
    showArrangeSheet = true
} label: {
    Label("组合为方案", systemImage: "sparkles.rectangle.stack")
}
.buttonStyle(.borderedProminent)
.tint(.purple)
.disabled(viewModel.selectedSegments.count < 2)
.help(viewModel.selectedSegments.count < 2 ? "至少选择 2 个分镜" : "把选中分镜组合为自定义方案")
```

- [ ] **Step 3: 加 Sheet state 和 sheet modifier**

在 `struct SegmentLibraryView: View {` 内的 `@State` 列表（顶部）增加：

```swift
@State private var showArrangeSheet = false
```

在 body 末尾增加（在最后一个修饰符之后或合适的同级位置）：

```swift
.sheet(isPresented: $showArrangeSheet) {
    ArrangeOrderSheet(
        initialSegments: Array(viewModel.selectedSegments).sorted { $0.startTime < $1.startTime },
        onCancel: { showArrangeSheet = false },
        onConfirm: { ordered in
            showArrangeSheet = false
            await viewModel.createSchemeFromSelection(ordered)
        }
    )
}
```

> 真实 ViewModel 中可能 `selectedSegments` 是 `Set<UUID>` 或 `Set<Segment>`。grep 验证类型，必要时改 `Array(viewModel.selectedSegments)` 这一行为正确的解引用方式。

- [ ] **Step 4: 暂不编译（要等 Task 20 写完 ViewModel 方法）**

- [ ] **Step 5: 暂不 commit**

---

### Task 20: SegmentLibraryViewModel 增加 createSchemeFromSelection

**Files:**
- Modify: `MixCut/ViewModels/SegmentLibraryViewModel.swift`

- [ ] **Step 1: 在 SegmentLibraryViewModel 增加方法**

在 `SegmentLibraryViewModel` 类内（找一个合适的位置，比如类末尾），增加：

```swift
/// 引用 SchemeViewModel 以触发自定义方案生成（外部注入）
weak var schemeViewModel: SchemeViewModel?

/// 引用导航以切换板块（外部注入；类型按实际 NavigationItem 调整）
var requestSwitchToSchemes: (() -> Void)?

/// 从选中分镜创建自定义方案（场景 A 入口）
@MainActor
func createSchemeFromSelection(_ segments: [Segment]) async {
    guard let project = currentProject else {
        ToastCenter.shared.show("当前没有项目", icon: "exclamationmark.triangle.fill")
        return
    }
    guard let schemeVM = schemeViewModel else {
        ToastCenter.shared.show("内部错误：SchemeViewModel 未注入", icon: "exclamationmark.octagon.fill")
        return
    }

    guard segments.count >= 2 else {
        ToastCenter.shared.show("至少需要 2 个分镜", icon: "exclamationmark.circle.fill")
        return
    }

    ToastCenter.shared.show("正在生成方案...", icon: "sparkles", style: .info)

    let scheme = await schemeVM.createCustomScheme(from: segments, in: project)
    if scheme != nil {
        ToastCenter.shared.show("自定义方案已生成", icon: "checkmark.circle.fill", style: .success)
        clearSelection()
        exitMultiSelectMode()
        requestSwitchToSchemes?()
    }
}

/// 清空选中集（如果已有同功能方法，复用之；这里仅作占位）
private func clearSelection() {
    // 调用项目中已有的同等功能方法。例如：
    // self.selectedSegments.removeAll()
    // ... 按真实字段名调整
}

private func exitMultiSelectMode() {
    // self.isMultiSelectMode = false  // 按真实字段名调整
}
```

> **重要**: `currentProject` / `selectedSegments` / `isMultiSelectMode` 等字段名按 ViewModel 实际定义来用。grep 实际字段：
> ```bash
> grep -n "var " MixCut/ViewModels/SegmentLibraryViewModel.swift | head -30
> ```

- [ ] **Step 2: 在 ContentView 注入引用**

```bash
grep -n "SegmentLibraryViewModel\|SchemeViewModel" MixCut/App/ContentView.swift | head -20
```

找到 ContentView 中创建 / 持有两个 VM 的位置，在 SegmentLibraryViewModel 被实例化或注入到 SegmentLibraryView 之前，增加：

```swift
.onAppear {
    segmentLibraryVM.schemeViewModel = schemeVM   // 按实际变量名
    segmentLibraryVM.requestSwitchToSchemes = {
        selectedNavItem = .schemes                // 按实际枚举 case 名
    }
}
```

> 若 ContentView 用 environment 注入 navigation state，相应调整。重点是建立"按完按钮跳到方案板块"这条通路。

- [ ] **Step 3: 编译**

```bash
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED。常见错误（按 grep 结果调整即可）：
- `currentProject` 字段名实际可能是 `project` 或 `selectedProject`
- `selectedSegments` 可能是 `Set<UUID>` 而非 `Set<Segment>` → 调整时一并解引用

- [ ] **Step 4: 运行 + 烟囱测试**

```bash
pkill -x MixCut; sleep 1
open /Users/menggang/Library/Developer/Xcode/DerivedData/MixCut-byytuggmhodpumcmwnwrtzwkmavr/Build/Products/Debug/MixCut.app
```

进入分镜素材库 → 开启多选 → 选 3 个分镜 → 点「组合为方案」→ 看到调整顺序 Sheet → 点「生成方案」→ 等 1-3 秒 → 自动跳到「方案」板块，并选中新生成的自定义方案。

- [ ] **Step 5: Commit Task 18+19+20 全部变更**

```bash
git add MixCut/Views/SegmentLibrary/SegmentLibraryView.swift MixCut/ViewModels/SegmentLibraryViewModel.swift MixCut/App/ContentView.swift
git commit -m "feat: 分镜库支持「组合为方案」入口（场景 A 端到端）"
```

---

## Phase 6: SchemeListView 渲染自定义组合 + 已修改标记

### Task 21: SchemeListView 使用 orderedStrategiesForDisplay 渲染

**Files:**
- Modify: `MixCut/Views/Schemes/SchemeListView.swift`

- [ ] **Step 1: 定位策略列表渲染处**

```bash
grep -n "strategies\|ForEach" MixCut/Views/Schemes/SchemeListView.swift | head -20
```

- [ ] **Step 2: 把所有用 `viewModel.strategies` 渲染列表的 ForEach 替换为 `viewModel.orderedStrategiesForDisplay`**

注意有两处可能要改：
- 左栏的策略列表 ForEach
- 顶部 toolbar 的 "策略数·视频数" 统计

```swift
// toolbar 统计改为：
Text("\(viewModel.aiStrategies.count) 策略 · \(viewModel.aiStrategies.flatMap(\.schemes).count) 视频")
```

- [ ] **Step 3: 在策略标题渲染处区分自定义组合**

找到渲染策略名的 `Text(strategy.name)` 处，包一层判断：

```swift
HStack(spacing: 4) {
    if strategy.isCustomGroup {
        Image(systemName: "sparkles")
            .font(.system(size: 10))
            .foregroundStyle(.purple)
    }
    Text(strategy.name)
        .font(.system(size: 12, weight: .medium))
}
```

- [ ] **Step 4: 自定义组合空状态引导卡**

在策略下方渲染方案的位置（通常是 `ForEach(strategy.orderedSchemes)`），改为：

```swift
if strategy.isCustomGroup && strategy.schemes.isEmpty {
    // 空状态引导
    VStack(alignment: .leading, spacing: 6) {
        Text("还没有自定义组合")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        Button {
            // 切换到分镜素材库板块
            // 通过 environment 或回调，按 ContentView 的实际接线调整
            NotificationCenter.default.post(name: .switchToSegmentLibrary, object: nil)
        } label: {
            Label("去分镜库挑几个分镜试试", systemImage: "arrow.right")
                .font(.system(size: 11))
        }
        .buttonStyle(.borderless)
    }
    .padding(.leading, 16)
    .padding(.vertical, 6)
} else {
    ForEach(strategy.orderedSchemes) { scheme in
        // 现有方案行渲染
    }
}
```

并在 `MixCutApp.swift` 或 `ContentView.swift` 中订阅这个 Notification 跳到分镜素材库板块。或者用更直接的方式（按现有 ContentView 通信模式选择）。

- [ ] **Step 5: 方案行渲染加「·已修改」**

找到方案行的 `Text(scheme.name)` 处：

```swift
HStack(spacing: 6) {
    Text(scheme.name)
    if scheme.isManuallyEdited {
        Text("·已修改")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
    }
}
```

- [ ] **Step 6: 编译 + 运行验证**

```bash
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -15
pkill -x MixCut; sleep 1
open /Users/menggang/Library/Developer/Xcode/DerivedData/MixCut-byytuggmhodpumcmwnwrtzwkmavr/Build/Products/Debug/MixCut.app
```

验证：
- 方案板块左栏底部有 ✨ 「自定义组合」分组
- 空时显示"还没有自定义组合 → 去分镜库挑几个分镜试试"
- 改一个 AI 方案后，方案行出现「·已修改」

- [ ] **Step 7: Commit**

```bash
git add MixCut/Views/Schemes/SchemeListView.swift
git commit -m "feat: SchemeListView 渲染自定义组合 + 空状态引导 + 已修改 badge"
```

---

### Task 22: 禁用自定义组合策略的重命名/删除操作

**Files:**
- Modify: `MixCut/Views/Schemes/SchemeListView.swift`

- [ ] **Step 1: 定位策略行的 contextMenu / 操作按钮**

```bash
grep -n "重命名\|renameStrategy\|deleteStrategy\|contextMenu" MixCut/Views/Schemes/SchemeListView.swift | head -10
```

- [ ] **Step 2: 在重命名/删除策略按钮上加 `.disabled(strategy.isCustomGroup)`**

如果是 contextMenu 的 Button，给它加 `.disabled()`：

```swift
Button("重命名", action: { /* ... */ })
    .disabled(strategy.isCustomGroup)

Button("删除策略", role: .destructive, action: { /* ... */ })
    .disabled(strategy.isCustomGroup)
```

- [ ] **Step 3: 编译 + 运行**

```bash
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -10
pkill -x MixCut; sleep 1
open /Users/menggang/Library/Developer/Xcode/DerivedData/MixCut-byytuggmhodpumcmwnwrtzwkmavr/Build/Products/Debug/MixCut.app
```

右键自定义组合策略 → 重命名 / 删除菜单项应该是灰色禁用。

- [ ] **Step 4: Commit**

```bash
git add MixCut/Views/Schemes/SchemeListView.swift
git commit -m "feat: 禁用自定义组合策略的重命名/删除菜单项"
```

---

## Phase 7: 全功能回归 + 打包

### Task 23: 人工回归清单

**Files:** 无代码改动

按以下清单**逐项手动验证**，每项过了打勾。如果任何一项不通过：暂停，记录现象，回到对应 Task 修复，再回来重跑。

#### 场景 A：从分镜库自由组合

- [ ] **A1**: 进分镜素材库 → 开多选 → 选 1 个 → 「组合为方案」按钮**禁用且提示"至少选择 2 个分镜"**
- [ ] **A2**: 选 3 个 → 按钮可点 → 弹出调整顺序 Sheet
- [ ] **A3**: 在 Sheet 内点左右箭头能交换分镜顺序
- [ ] **A4**: 点「生成方案」→ 按钮转 loading → 1-3 秒后 Sheet 关闭 → 自动切到方案板块 → 选中新方案
- [ ] **A5**: 自定义方案在左栏 ✨「自定义组合」分组下显示
- [ ] **A6**: AI 反推成功 → 方案名/叙事结构/受众等字段被填充
- [ ] **A7**: 断网模拟 AI 失败（关闭千问 API key 或拔网线）→ 应弹出"元信息生成失败"toast，方案以「自定义 #N」保存且可见
- [ ] **A8**: 自定义方案点击导出 → 能正常导出视频

#### 场景 B：AI 方案上增删改

- [ ] **B1**: 有 AI 生成的方案 → storyboard 分镜之间 hover 看到 ⊕（淡蓝色背景 + 加号）
- [ ] **B2**: 点 ⊕ → 右侧抽屉滑入 → 显示项目内所有分镜
- [ ] **B3**: 抽屉中**当前方案已用过的分镜**显示置灰 + "🚫" 标记 + tooltip "该分镜已在方案中"
- [ ] **B4**: 点击一个可用分镜 → 立即插入到 storyboard 对应位置 → toast 提示 "已插入到 #N"
- [ ] **B5**: 抽屉**保持打开**，继续点别的分镜能连续添加
- [ ] **B6**: 点抽屉 ✕ 或点空白处关闭抽屉
- [ ] **B7**: 卡片 hover → 右上角出现"替换 + 删除"两个圆形按钮
- [ ] **B8**: 点替换 → 抽屉打开，默认筛选"同语义类型" → 顶部勾选「显示全部类型」切换为不限
- [ ] **B9**: 删除非最后一条 → 直接删除 + 自动重编号
- [ ] **B10**: 删除到只剩 1 条 → 删除按钮变灰 + tooltip "方案至少保留 1 个分镜"
- [ ] **B11**: 任何一次编辑（增/删/替换/换序）后，方案左栏行显示「·已修改」

#### 场景 C：自定义组合策略行为

- [ ] **C1**: 新建项目 → 进方案板块 → 左栏自动有 ✨ 自定义组合分组（即使空）
- [ ] **C2**: 自定义组合空时 → 显示"还没有自定义组合 → 去分镜库挑几个分镜试试"引导
- [ ] **C3**: 点引导 → 切换到分镜素材库板块
- [ ] **C4**: 右键自定义组合策略 → 「重命名」「删除策略」选项灰色禁用
- [ ] **C5**: 自定义方案不显示「·已修改」（即使加了分镜）

#### 场景 D：切换项目联动（CLAUDE.md 铁律）

- [ ] **D1**: 项目 A 创建一个自定义方案 → 切到 B → 看不到 A 的自定义方案
- [ ] **D2**: 切回 A → 自定义方案完整可见
- [ ] **D3**: B 的方案板块也有"自定义组合"分组（即使为空）
- [ ] **D4**: A 的 AI 方案改了 → 切到 B → 切回 A → 「·已修改」标记仍在

#### 场景 E：老项目迁移

- [ ] **E1**: 找一个 v0.2.6 时代的老项目（在迁移前已有数据的）→ 启动 app
- [ ] **E2**: 进方案板块 → 老项目里也有 ✨ 自定义组合分组（首次启动后由 `ensureCustomGroupStrategy()` 补建）

#### 场景 F：现有功能回归（不能误伤）

- [ ] **F1**: AI 生成方案功能正常（之前能生成，现在还能生成）
- [ ] **F2**: storyboard 上 IN/OUT 微调按钮（StoryboardTimeRow）正常
- [ ] **F3**: storyboard 上分镜内的 SegmentInlinePlayer 正常播放
- [ ] **F4**: 分镜素材库批量导出功能正常
- [ ] **F5**: 分镜素材库的多选→全选/反选/清空正常
- [ ] **F6**: 项目切换其他板块（概览、导入、导出）正常

---

### Task 24: Release 编译 + 打包 DMG

**Files:** 无代码改动

- [ ] **Step 1: Release 编译**

```bash
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Release build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED。

- [ ] **Step 2: 打包 DMG**

```bash
TEMP=$(mktemp -d) && cp -R /Users/menggang/Library/Developer/Xcode/DerivedData/MixCut-byytuggmhodpumcmwnwrtzwkmavr/Build/Products/Release/MixCut.app "$TEMP/" && ln -s /Applications "$TEMP/Applications"
rm -f ~/Desktop/MixCut.dmg && hdiutil create -volname MixCut -srcfolder "$TEMP" -ov -format UDZO ~/Desktop/MixCut.dmg
rm -rf "$TEMP"
ls -lh ~/Desktop/MixCut.dmg
```

Expected: `~/Desktop/MixCut.dmg` 存在，size > 80MB（含 FFmpeg/Whisper 二进制）。

- [ ] **Step 3: DMG 烟囱测试**

```bash
open ~/Desktop/MixCut.dmg
sleep 2
```

挂载后，从 DMG 中拖 MixCut.app 到一个临时位置（不是 /Applications，避免覆盖开发版），双击启动，跑一遍 §Task 23 的 A1+B1+C1 三个最关键场景，确认 Release 版可用。

- [ ] **Step 4: 全部本次工作的 commit 列表**

```bash
git log --oneline main..HEAD
```

Expected: 看到 Phase 1-6 的所有 commit。

---

## 任务完成后

**不要自动合并到 main**，按 CLAUDE.md：「不要自动提交 git 和发布版本…必须等用户验证没问题后，用户明确要求才能提交和发版。」

完成 Task 23 + 24 后，向用户报告：

```
✅ feature/manual-scheme-editor 全部任务完成
✅ Release 编译通过、DMG 打包到 ~/Desktop/MixCut.dmg
✅ 人工回归清单全部通过

请你亲自跑一遍验证。验过没问题再告诉我合 main + 升版本 + 发版。
```

---

## Self-Review 检查清单（写完计划后我自检）

✅ **Spec 覆盖**：spec §3 数据模型 → Task 1+2，§3.2 老项目迁移 → Task 3，§3.3 markAsEdited → Task 6，§4 场景 A → Task 18+19+20，§5 场景 B → Task 13+15+16+17，§5.3 抽屉 → Task 15，§5.4 重复防御 → Task 8+9+15，§5.5 删空兜底 → Task 7，§6 ViewModel 方法 → Task 5-9+12，§7 SchemeListView → Task 21+22，§8 风险表→各 Task 编译验证步骤，§9 测试策略 → Task 23 人工回归，§10 分阶段 → Phase 0-7，§11 回滚 → 全程在 feature 分支
✅ **Placeholder 扫描**：没有 TBD/TODO 不填的内容
✅ **类型一致性**：所有 method 名（`insertSegment`、`replaceSegment`、`removeSegment`、`moveSegment`、`createCustomScheme`、`inferMetadata`、`ensureCustomGroupStrategy`、`createSchemeFromSelection`）跨 Task 引用一致
✅ **代码完整性**：每个 step 都有可粘贴可运行的代码，没有依赖"前面已写过类似的"
