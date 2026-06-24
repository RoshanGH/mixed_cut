# GOAL：配音变体三层混剪（端到端，目标模式）

以**目标模式**完成下面这个项目：自主决策、不逐步征求同意、对齐 To C 端商用产品质量；只有遇到真正无法推进的阻塞才停下问我。先做数据模型/方案设计，再实现；每改完一处都自己编译、自测、截图确认，别让我当测试员。

## 背景

MixCut 是 macOS 原生 SwiftUI + SwiftData 的 AI 视频混剪 App（信息流广告，统一 9:16 竖屏）。配音已接入阿里百炼 qwen TTS，采用**只克隆原声**方案：一键改写会自动分离人声→克隆原主播嗓音→用克隆音色生成配音；`isVoiceLocked`（保留原声）分镜不参与配音。相关事实见记忆 `project_dubbing_clone.md`，已写好的设计/计划见 `docs/superpowers/specs/2026-06-24-variant-aware-segment-export-design.md` 与 `docs/superpowers/plans/2026-06-24-variant-aware-segment-export.md`（可复用，但本 GOAL 范围更大，按本文件为准）。

## 目标（按结果验收，不是步骤清单）

### G1. 一键改写默认批量产台词变体，数量可配
- 点「一键改写台词」后，对**所有非锁定**分镜，默认各生成 **N 个台词变体**（每个变体 = 改写台词 + 克隆配音音频，时长对齐到该分镜）。
- `isVoiceLocked`（保留原声）分镜**不产任何变体音频**。
- **N 可配置**：在分镜库配音区提供「变体数量」选择（默认 2，范围合理即可，如 1–5）。改数量后再次一键改写按新数量产出。
- 产出全自动：不需要用户逐分镜手点生成。失败要有可见反馈（复用 Toast / 现有错误提示），不要静默吞错。

### G2. 分镜库导出 = 原版 + 全部变体一起导
- 在分镜素材库多选导出时，每个选中分镜导出 **1 个原版 + 它全部已生成变体**。
- 原版 = 原画面 + 原声 + 原字幕，不动；变体 = 原画面 + 克隆配音 **与原 BGM 切片混音** + 烧录新字幕（按该分镜遮挡设置遮挡旧硬字幕）。
- 锁定分镜只导原版。
- 命名 = 原分镜命名 + 变体编号（如 `{编号}_{视频名}.mp4` / `_A` / `_B`…）。同名冲突自动去重。
- 这块已有详细设计与计划（见上面两个文件，含 `SegmentExportExpander`、`DubSegmentGraphBuilder` 加 BGM、`DubExportService.exportSingleSegment`、`VariantBatchExportService`）。直接落地它，作为 G2 的实现。

### G3. 方案生成变三层（方案 → 视频模板 → 变体视频）
- 方案（混剪策略 + 分镜组合）**仍只基于原分镜生成**——因为各变体台词相似，方案层不必翻倍。
- 排列组合层：方案里每个被选中的分镜，可替换成它的任一变体（原声分镜固定用原声）。于是结构变三层：
  - **方案**（策略 + 一条原分镜序列）
  - **视频模板** = 该方案下的一种分镜序列（沿用现有「一套方案十几个视频」的产物，作为中间层）
  - **变体视频** = 在模板基础上，每个非锁定分镜各取一个变体所形成的具体组合
- 组合数可能爆炸：要有合理的上限/采样策略（例如每模板默认生成有限个变体组合，或按变体笛卡尔积去重并设上限），并把「被截断/采样了多少」如实展示，不要假装全覆盖。
- 复用已有的 `Sources/MixCutCore/VariantSelector.swift`、`SchemeSegment.selectedSegmentDubId`、`DubExportInput`（方案导出已能按槽选定变体）等既有脚手架，能扩展就别重写。

### G4. 预览/导出对齐选中变体
- 预览：选中某变体时，播放用**该变体的配音**（视频画面不变，声音换成变体声音）。
- 导出：按所选变体的配音导出（方案导出读 `selectedSegmentDubId` 已有基础，补齐三层选择与 BGM 混音）。
- 整体交互对齐 To C 商用：清晰的层级切换、当前选中态、播放/导出一致。

## 硬约束（必须遵守，违反即返工）

- **9:16 竖屏**：任何视频/缩略图/预览一律 9:16，禁止 16:9 或正方形。
- **配音 = 只克隆原声**：不加选音色 UI，不引入 CosyVoice 到配音主流程；qwen-vc 无数值语速，对齐走 atempo。
- **AI 提供商只用千问/MiniMax/Claude**，不用 Gemini。
- **API Key 仅运行时经 `KeychainHelper.getAPIKey(for:)` 读取**（存在 UserDefaults），禁止硬编码任何密钥。
- **不自动 git 提交/发版**：只做编译 + 重启 App + 打包 DMG；`git add/commit/push`、`gh release`、`git tag` 一律等我明确要求。
- **改 SwiftData 模型前先备份库**：`cp ~/Library/Application\ Support/MixCut/MixCut.store ~/Library/Application\ Support/MixCut/MixCut.store.bak`；新增字段用默认值做轻量加法迁移，别破坏既有数据。
- **切换项目必须联动刷新**：依赖项目数据的视图用 `.task(id: project.id)`（放 body 顶层，别挂条件分支）或 `onAppear+onChange`。
- **不要修一个坏三个**：改动前先列出受影响视图的既有能力（多选导出、批量删除、行内编辑台词、选中复制、右键菜单、BGM 混音、字幕遮挡三模式、缩略图缓存、强制浅色、启动恢复上次项目），改完逐项回归。
- **纯逻辑走 TDD**：MixCutCore 里的新逻辑（变体展开/命名、组合采样、滤镜图等）先写 Swift Testing 测试再实现，`swift test` 绿。
- **MixCutCore 新文件要注册进 pbxproj**（核心 4 处、App 文件 3 处），否则 Xcode 编译不到。
- **必须用 Xcode 编译**（SwiftData 宏依赖）：`xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build`。
- **自测优先**：每改完 UI 必 编译→`pkill -x MixCut; open <DerivedData>/Build/Products/Debug/MixCut.app`→截图核对；不能验证的列出明确「用户必测项」。
- 编译成功后按项目规则后台出 Release DMG 到 `~/Desktop/MixCut.dmg`。

## 工作方式

1. 先用 planner/architect 思路把**三层数据模型与组合生成**设计清楚（这是最大的新增，G3/G4 依赖它），写进 spec/plan。
2. 按依赖顺序实现：G1（变体批量产出 + 数量设置）→ G2（分镜库变体导出，落地已有计划）→ G3（三层方案与组合）→ G4（预览/导出对齐变体）。
3. 每完成一块：编译 + 自测 + 截图，能写测试的写测试。改完整体用「代码质量 + 安全 + 架构」多角度自查。
4. 全部做完，给我一份「已自测项 + 待我人工验证项」清单，并说明组合上限/采样策略取了什么值。
5. 全程不提交 git、不发版，等我验收。

DerivedData：`/Users/menggang/Library/Developer/Xcode/DerivedData/MixCut-byytuggmhodpumcmwnwrtzwkmavr/`
