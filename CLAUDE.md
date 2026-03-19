# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 开发工作方式要求

**必须优先使用已安装的专业 agent 和 skills 来完成 macOS 原生应用的所有开发工作**，包括但不限于：

- **设计/架构**: 使用 `everything-claude-code:planner`、`everything-claude-code:architect` 等做方案设计
- **编码**: 使用 `swiftui-patterns`、`swift-concurrency-6-2`、`swift-actor-persistence` 等 Swift/SwiftUI 专业 skill
- **Code Review**: 使用 `everything-claude-code:code-reviewer` 做代码审查，每次改完代码都要 review
- **安全审查**: 使用 `everything-claude-code:security-reviewer` 检查安全问题
- **Debug**: 使用 `everything-claude-code:build-error-resolver` 修复编译错误
- **测试**: 使用 `everything-claude-code:tdd-guide` 做测试驱动开发
- **发版**: 修复完成后主动用多个 agent 并行审查（代码质量 + 安全 + 架构），确保分发质量

不要手动逐步试错，遇到问题直接调用对应的专业 agent 一步到位解决。

## 项目概述

MixCut 是一款 macOS 原生桌面应用（SwiftUI + SwiftData），面向广告投放团队的 AI 视频混剪工具。用户导入广告素材视频，AI 自动按语义切分镜头并标注类型，然后智能排列组合生成多条差异化的混剪广告视频。

## 构建与运行

- **必须使用 Xcode 编译**（SwiftData 宏依赖 Xcode 编译器）
- 在 Xcode 中通过 `File → Open` 打开 `Package.swift`，或打开 `MixCut.xcodeproj`
- 最低要求：macOS 14.0 (Sonoma)，Swift 5.10+，Xcode 15.0+
- 无第三方 SPM 依赖

### 外部工具依赖（内置于 app bundle，用户无需安装）

- **FFmpeg**: 视频处理（镜头检测、静音检测、缩略图、导出拼接）— 内置于 `Resources/bin/`
- **Whisper (whisper.cpp)**: 本地语音识别（ASR）— 内置于 `Resources/bin/`
- **Whisper 模型**: `ggml-small.bin` (~488MB) — 首次使用时自动下载到 `~/Library/Caches/com.mixcut.app/whisper-models/`

> **核心原则：开箱即用** — 像剪映一样，用户双击即可使用，不需要安装 homebrew、FFmpeg、Whisper 等任何外部依赖。
> `bundle_deps.py` 负责将 FFmpeg/Whisper 二进制及其 dylib 打包到 `MixCut/Resources/bin/` 目录，并修复 dylib 路径为 `@loader_path`。
> 开发期间如果 bundle 内二进制不可用，会 fallback 到系统安装的版本（仅开发便利，不应依赖）。

## 架构

### 分层结构（MVVM + Service Layer）

```
App/          → 入口 + 主路由（MixCutApp, ContentView）
Models/       → SwiftData 模型（6 个 @Model 类，含 ProjectVideo 中间表）
ViewModels/   → @Observable VM，持有 Service 引用，@MainActor
Services/     → actor 隔离的业务逻辑，无 UI 依赖
Views/        → SwiftUI 视图，按功能分子目录
Utilities/    → KeychainHelper, FileHelper
Resources/    → AI Prompt 模板（.md 文件，通过 Bundle 加载）
```

### 数据模型关系

```
Project *──* Video 1──* Segment        （视频全局共享，通过 ProjectVideo 多对多关联）
Project 1──* MixScheme 1──* SchemeSegment *──1 Segment
Project 1──* ProjectVideo *──1 Video   （中间表）
```

- **全局共享**：同一视频（SHA-256 哈希相同）全局只有一个 Video 实体和一组 Segment，多项目共享
- 导入已分析视频秒级完成（直接创建 ProjectVideo 关联，不重复处理）
- 在任何项目中修改分镜，所有项目即时同步
- 视频文件按 hash 存储在全局目录 `AppSupport/MixCut/Videos/{hash}/`
- `Project`: 7 种状态（created → importing → analyzing → ready → generating → completed → archived）
- `Video`: 6 种状态（imported → detectingScenes → transcribing → analyzing → completed → failed）
- `Segment`: 11 种语义类型（SemanticType，支持多个）+ 3 种位置类型（PositionType，单个）

### AI 服务架构

采用 **AIProvider 协议** 支持多提供商（千问 / MiniMax），均通过 OpenAI 兼容 API 调用：

- `AIProvider` 协议 → `OpenAICompatibleClient`（通用 OpenAI 兼容格式，支持千问和 MiniMax）
- `AIProviderManager` 工厂 → 根据 UserDefaults 中保存的设置创建实例（Service 层每次调用动态获取，Settings 变更立即生效）
- API Key 存储在 UserDefaults（已移除 KeychainAccess 依赖，避免开发期钥匙串弹窗）
- 用户在 Settings 窗口（macOS 原生 `Settings` scene）选择提供商和模型

### 核心数据流水线

视频导入后的处理流程（`ImportViewModel.importSingleVideo`）：

1. 复制文件到应用目录 + AVFoundation 提取元数据
2. FFmpeg 生成缩略图
3. **本地分析**（SceneDetectionService）：场景切换检测 + 静音检测 + I-frame 提取
4. **ASR 语音识别**（ASRService）：Whisper 本地执行，输出字级时间戳
5. **AI 语义分析**（AIAnalysisService）：仅发送结构化文本数据给 AI（不发送视频）
6. **四阶段边界优化**（BoundaryOptimizerService）：句子吸附 → 场景对齐 → 静音吸附 → I-frame 对齐

方案生成采用**两步架构**（`SchemeGenerationService`）：
- Step 1: AI 生成策略（风格、受众、叙事结构）
- Step 2: AI 基于策略选择具体分镜组合

### 关键设计决策

- **不直接传视频给 AI**：所有视觉/音频信号由本地 FFmpeg 精确提取，转为结构化数据后传给 AI 做语义决策
- **每步独立容错**：导入流水线每个步骤失败不阻塞后续步骤（元数据/缩略图/ASR/AI 分析各自 try-catch）
- **视频删除即取消**：`cancelledVideoIDs` 集合跟踪已删除视频，处理中的任务会在 checkpoint 处跳过
- **沙盒已关闭**：`com.apple.security.app-sandbox = false`，直接使用 `Process` 调用 FFmpeg/Whisper
- **导航方式**：不使用 NavigationSplitView，而是自定义 `HStack` 布局（固定宽度侧边栏 + 详情区域），通过 `NavigationItem` 枚举 + `@State selectedNavItem` 切换视图

### Prompt 模板

AI 提示词模板存放在 `MixCut/Resources/Prompts/`，通过 `PromptLoader` 从 Bundle 加载：
- `segment_types_definition.md` — 11 种语义类型定义（被 AIAnalysisService 加载）
- `video_recombination_prompt.md` — 方案生成（被 SchemeGenerationService 加载）
- `ad_styles.md` — 10 种广告风格（被 SchemeGenerationService 加载）
- `recombination_principles.md` — 混剪原则（被 SchemeGenerationService 加载）
- `video_segmentation_prompt.md` — 分镜标注参考（未被代码直接引用，prompt 在 AIAnalysisService 中内联构建）

## 开发工作流

- **编译后自动重启应用**: 每次 xcodebuild 编译成功后，必须执行 `pkill -x MixCut; sleep 1; open <DerivedData路径>/Build/Products/Debug/MixCut.app` 自动重启用户的应用
- **DerivedData 路径**: `/Users/menggang/Library/Developer/Xcode/DerivedData/MixCut-byytuggmhodpumcmwnwrtzwkmavr/`
- **每次修改后自动打包 DMG**: 编译成功后，必须自动执行 Release 构建 + DMG 打包，输出到 `~/Desktop/MixCut.dmg`。用户需要随时分发给同事测试，不要等用户手动要求打包。完整流程：
  ```bash
  # 1. Debug 编译 + 重启本地应用
  xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build
  pkill -x MixCut; sleep 1; open <DerivedData>/Build/Products/Debug/MixCut.app
  # 2. Release 编译 + 打包 DMG（后台执行，不阻塞用户）
  xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Release build
  TEMP=$(mktemp -d) && cp -R <DerivedData>/Build/Products/Release/MixCut.app "$TEMP/" && ln -s /Applications "$TEMP/Applications"
  rm -f ~/Desktop/MixCut.dmg && hdiutil create -volname MixCut -srcfolder "$TEMP" -ov -format UDZO ~/Desktop/MixCut.dmg
  rm -rf "$TEMP"
  ```

## 数据模型注意事项

- `Segment.semanticTypesData` 是 `Data?`，通过计算属性 `semanticTypes: [SemanticType]` 读写（JSON 编解码）
- 旧版代码曾用 `semanticType: SemanticType` 单字段存储，已迁移到多类型。旧数据通过 `MixCutApp.fixMissingSemanticTypes()` 在首次启动时修复（填充默认值「过渡」）
- `Segment.keywords` 同理使用 `keywordsData: Data?` + 计算属性
- `Video.asrSentences` 使用 `asrSentencesData: Data?` + 计算属性存储 Whisper 原生句子段

## Git 与发版规则（必须遵守）

- **不要自动提交 git 和发布版本**：修改代码后只做编译+重启+打包 DMG，不要执行 `git add/commit/push` 和 `gh release`。必须等用户验证没问题后，用户明确要求才能提交和发版。
- **不要自作主张 `git tag` 或 `gh release create`**：版本号和发布时机由用户决定。

## 关键开发规则（必须遵守）

### 切换项目时各模块必须联动刷新

所有依赖项目数据的视图，必须同时使用 `onAppear` **和** `onChange(of: project.id)` 来加载数据。仅用 `onAppear` 不够，因为 SwiftUI 在切换项目时不一定重新创建视图（视图复用），导致数据不刷新。

```swift
// ✅ 正确写法
.onAppear { viewModel.loadData(for: project) }
.onChange(of: project.id) { viewModel.loadData(for: project) }

// ❌ 错误写法（切换项目时不会刷新）
.onAppear { viewModel.loadData(for: project) }
```

已修复的视图：SegmentLibraryView、SchemeListView、ExportView。新增视图如果依赖项目数据，必须遵循此模式。

### Schema 变更必须先备份数据库

修改 SwiftData 模型（增删字段、修改关系）前，必须先备份数据库文件：
```bash
cp ~/Library/Application\ Support/default.store ~/Library/Application\ Support/default.store.bak
```
SwiftData 无 VersionedSchema 时，schema 不兼容会导致数据库被清空。

## 已知问题与改进方向

- **数据库保存**: 大量 `try? modelContext?.save()` 吞掉错误，后续应加日志或用户提示
- **并发安全**: 多视频并行导入时共享 ModelContext 可能有竞态风险（当前实际为顺序处理）
- **Schema 版本**: 未使用 SwiftData VersionedSchema，模型结构变更需注意兼容性
- **样式规范**: 已创建 `DesignTokens.swift`（Corner/Spacing/Padding），部分视图已迁移，其余视图待统一

## 开发阶段

当前处于 **Phase 1 MVP 进行中**。
- 素材导入 + AI 分析流水线已完成（8 步处理链）
- 分镜素材库浏览/筛选/微调已完成
- 混剪方案生成 UI + 两步 AI 流程已搭建
- 视频导出功能骨架存在（ExportView + ExportService）
- 端到端方案生成 → 导出流程待验证
详见 `PRODUCT_SPEC.md`。
