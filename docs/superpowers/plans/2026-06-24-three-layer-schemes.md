# G3+G4 三层方案与变体对齐 实现计划

**Goal:** 方案从两层(策略→视频)变三层(策略→视频模板→变体视频);每个模板按非锁定分镜的配音变体做笛卡尔积采样展开成多条变体视频;预览/导出都用所选变体的配音。

**Architecture(最小侵入):** 不新增 @Model 关系实体。MixScheme 仍是「一条可导出的视频」,但新增加法字段 `templateGroupId`/`templateVariantIndex` 把同一原分镜序列的多条变体 MixScheme 归为一个「模板组」。每条变体 MixScheme 各自带不同的 `selectedSegmentDubId` 组合(复用现有 DubExportInput.from / 详情 / 预览,全部按 MixScheme 工作,零改导出核心)。组合由 MixCutCore 纯函数 `VariantCombinationGenerator` 采样生成。

**Tech Stack:** SwiftUI/SwiftData/MixCutCore。

## Global Constraints
- 改 SwiftData 模型前备份 `~/Library/Application Support/MixCut/MixCut.store`;新字段带默认值轻量迁移。
- 不改导出核心(DubExportInput.from(scheme:) 按 selectedSegmentDubId,保持)。
- 组合数设上限并如实展示截断量;锁定/无变体的槽恒用原声(nil)。
- 9:16;只克隆原声;不自动 git 提交/发版。
- 复用 VariantSelector 思路但改为笛卡尔积采样(更多样)。
- 纯逻辑先写 Swift Testing 测试,swift test 绿;新 core 文件注册 pbxproj。

---

### Task 1: VariantCombinationGenerator(纯逻辑,可测)
**Files:** Create `Sources/MixCutCore/VariantCombinationGenerator.swift`; Test `Tests/MixCutCoreTests/VariantCombinationGeneratorTests.swift`; 注册 pbxproj。

**API:**
```swift
public struct SlotOptions: Equatable, Sendable {
    public let isLocked: Bool
    public let dubIds: [UUID]    // 该槽可选变体（空=只有原声）
    public init(isLocked: Bool, dubIds: [UUID])
}
public struct CombinationResult: Equatable, Sendable {
    public let combinations: [[UUID?]]  // 每条 = 每槽选定 dubId(nil=原声)，长度=slots.count
    public let feasibleCount: Int       // 去重后理论可生成总数（笛卡尔积大小）
    public let truncated: Bool          // feasibleCount > limit
}
public enum VariantCombinationGenerator {
    public static func generate(slots: [SlotOptions], limit: Int) -> CombinationResult
}
```
**算法:** 每槽 choices = (isLocked || dubIds空) ? [nil] : dubIds.map{$0}; feasibleCount = ∏ choices.count; take = min(limit, feasibleCount); 用混合进制计数枚举前 take 个组合(确定性、互不相同); truncated = feasibleCount > limit。limit<=0 视为 0 条。

**测试:** 2槽各2变体→feasible4; limit2→取2条且不同; 锁定槽恒nil; 无变体槽恒nil; 全锁定→feasible1只1条全nil; limit大于feasible→只返feasible条 truncated=false; 截断 truncated=true。

---

### Task 2: MixScheme 加模板分组字段(SwiftData 轻量迁移)
**Files:** Modify `MixCut/Models/MixScheme.swift`。先备份 store。
新增:
```swift
var templateGroupId: UUID?        // 同一原分镜序列(模板)的变体共享;nil=旧数据/未分组
var templateVariantIndex: Int = 0 // 模板组内变体序号(0-based)
```
（均加法、带默认值,安全迁移。）

---

### Task 3: 生成改为「模板→K 个变体视频」
**Files:** Modify `MixCut/ViewModels/SchemeViewModel.swift`(generateSchemes 落库段 + createSchemeSegments + assignDubVariants)。
- 每个 composition = 一个模板:`let groupId = UUID()`;算出该序列各槽 SlotOptions(锁定/各分镜 segmentDubs 的 id 按 textVariantIndex 升序),调用 `VariantCombinationGenerator.generate(slots:limit:)`,limit = `maxVariantVideosPerTemplate`(常量,默认 8)。
- 对返回的每条组合 j:创建一条 MixScheme(templateGroupId=groupId, templateVariantIndex=j, variationIndex=模板序号 vi+1, name = "模板名 · 变体X"),克隆该序列的 SchemeSegment（position/segment 同模板),把组合里每槽的 dubId 写进 `selectedSegmentDubId`。
- 整体预算上限:全项目变体视频总数 ≤ `maxTotalVariantVideos`(常量 300),超过停止并记日志/Toast 告知截断。
- 删除原 `assignDubVariants` 的单次分配(被组合生成取代);保留 VariantSelector 文件不动(其它处若引用则保留)。
- Toast/进度如实显示:模板数、变体视频总数、是否截断。

### Task 4: SchemeListView 三层分组展示
**Files:** Modify `MixCut/Views/Schemes/SchemeListView.swift`。
- 策略 section 下,把该策略的 schemes 按 `templateGroupId` 分组(nil 各自成组,兼容旧数据);每组显示一个「模板」行(可展开),展开后列出该组变体视频行(用 templateVariantIndex 标 #1/#2…)。
- 选中某变体视频 → 右侧 SchemeDetailView 照旧(它按单 MixScheme 工作)。
- 三层:策略 → 模板 → 变体视频。保留现有展开/选中/删除交互。

### Task 5: G4 预览/导出对齐选中变体
**Files:** `MixCut/Views/Schemes/SchemeDetailView.swift`(StoryboardCard 预览)、必要时 `SegmentInlinePlayer`。
- 详情页 storyboard 每个分镜卡:播放时,若该槽 selectedSegmentDubId 指向已生成音频的变体,则预览用「原视频画面 + 该变体配音」对齐播放(静音原声、叠加变体音轨);锁定/无变体槽放原声。
- 导出已自动对齐(DubExportInput.from 读 selectedSegmentDubId),仅确认变体视频导出走该路径即可,无需改导出核心。

---

## 验收
- 生成后方案区呈现三层;一个模板展开有多条变体视频。
- 选不同变体视频,详情/预览播放对应配音;导出该变体即得对应配音成片。
- 组合超上限时如实提示截断。
- 全量 swift test 绿;App 编译+重启+截图自测。
