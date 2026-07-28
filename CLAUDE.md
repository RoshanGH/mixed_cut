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

> **用户约定**：用户说「MC」即指 MixCut 本应用。凡是"MC 的项目 / 让 MC 导入 / MC 导出"等说法，一律指调用本机 mixcut MCP 服务（http://127.0.0.1:8787/mcp，13 个工具）操作 MixCut。

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
> 内置二进制均为**静态自包含 universal（arm64 + x86_64）**，无外部 dylib，支持 Intel Mac。
> 由 `./scripts/build_universal_binaries.sh` 生成（下载静态 ffmpeg + 源码编 whisper/demucs + `lipo` 合并）；
> `bundle_deps.py` 现为校验器（检查 4 个二进制是否就位且双架构）。`Resources/bin/` 为 gitignored 本地产物。
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
- **每次修改后自动打包 DMG**: 编译成功后，必须自动执行 Release 构建 + DMG 打包，输出到 `~/Desktop/MixCut-v<版本号>.dmg`。用户需要随时分发给同事测试，不要等用户手动要求打包。
- **⚠️ 产物文件名必须带版本号**：`MixCut-v0.9.1.dmg`，**绝不允许**打成 `MixCut.dmg`。桌面上会同时存在多个版本的包，不带版本号根本分不清哪个是哪个，也没法直接传网盘。卷名（`-volname`）同样带版本号。
- **打包前先 bump 版本号**：哪怕只是打测试包、不发版，版本号也要正常往后递增，不要停在旧版本号上。
  ```bash
  # 0. bump 版本号（VERSION 文件 + pbxproj 的两处 MARKETING_VERSION 必须一致）
  # 1. Debug 编译 + 重启本地应用
  xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build
  pkill -x MixCut; sleep 1; open <DerivedData>/Build/Products/Debug/MixCut.app
  # 2. Release 编译 + 打包 DMG（后台执行，不阻塞用户）
  # ⚠️ 必须带 universal 参数，否则默认只编本机 arm64，Intel Mac 装了报「不支持此应用程序」
  xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Release \
    -destination 'generic/platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build
  V=$(cat VERSION)
  TEMP=$(mktemp -d) && cp -R <DerivedData>/Build/Products/Release/MixCut.app "$TEMP/" && ln -s /Applications "$TEMP/Applications"
  rm -f ~/Desktop/MixCut-v${V}.dmg
  hdiutil create -volname "MixCut ${V}" -srcfolder "$TEMP" -ov -format UDZO ~/Desktop/MixCut-v${V}.dmg
  rm -rf "$TEMP"
  ```

  > **发版前务必校验 DMG 内主程序是 universal**：`lipo -archs <app>/Contents/MacOS/MixCut` 应为 `x86_64 arm64`。
  > 普通 `xcodebuild ... Release build`（不带 `-destination generic + ARCHS`）只出 arm64，会悄悄丢掉 Intel 支持。
  > 同时校验 DMG 内 `CFBundleShortVersionString` == 目标版本号（挂载后用 PlistBuddy 读），别只信构建目录。

## 自己先测试，别让用户当测试员（必须遵守 ⚠️⚠️⚠️）

**改完代码必须先自己跑、自己看、自己点，确认没问题再交给用户**。具体要求：

1. **每次改 UI 后必须**：编译 → `pkill -x MixCut; open <app>` 重启 → 用 `screencapture -l <window-id> /tmp/check.png` 截图查看效果，或自己用 LSP/编译反馈反复验证
2. **不能验证的**（比如需要鼠标交互、播放视频、跨多个视图状态切换等），列出明确的"用户必须测试项"清单，注明每项验证步骤
3. **绝对不允许**："看上去应该没问题"、"理论上能跑"、"等你测一下"这种把验证甩给用户的话
4. **每个 commit 之前**必须确认本次改动**自己肉眼看过/截过图**，不光是编译通过

> **背景**：之前我多次只编译就 commit，结果 UI 完全坏掉用户才发现。这是浪费用户时间的根因，必须杜绝。

## 视频显示比例（必须遵守 ⚠️）

**MixCut 的所有视频素材都是信息流广告，目标投放在手机端，统一使用 9:16 竖屏比例**。

任何展示视频画面 / 缩略图 / 视频预览的视图，**必须使用 9:16 竖屏比例**（手机端纵向），不能使用 16:9 横屏或正方形比例。具体约束：

- 缩略图卡片：宽高比 = 9:16（例如 width=140 → height≈250）
- 内嵌播放器（`SegmentInlinePlayer`、`SegmentPreview` 等）：同样使用 9:16
- 不要为了"塞下两行台词"而压扁视频区域；要么调整卡片整体尺寸，要么把台词放到视频下方

如果新增任何展示视频或视频缩略图的视图，**审查时必须验证比例是 9:16**，不是请立刻调整。已经存在的视图也应该按这个规则审计修正。

## 数据模型注意事项

- `Segment.semanticTypesData` 是 `Data?`，通过计算属性 `semanticTypes: [SemanticType]` 读写（JSON 编解码）
- 旧版代码曾用 `semanticType: SemanticType` 单字段存储，已迁移到多类型。旧数据通过 `MixCutApp.fixMissingSemanticTypes()` 在首次启动时修复（填充默认值「过渡」）
- `Segment.keywords` 同理使用 `keywordsData: Data?` + 计算属性
- `Video.asrSentences` 使用 `asrSentencesData: Data?` + 计算属性存储 Whisper 原生句子段

## Git 与发版规则（必须遵守）

- **不要自动提交 git 和发布版本**：修改代码后只做编译+重启+打包 DMG，不要执行 `git add/commit/push` 和 `gh release`。必须等用户验证没问题后，用户明确要求才能提交和发版。
- **不要自作主张 `git tag` 或 `gh release create`**：版本号和发布时机由用户决定。

### 分发方式（v0.7.1 起，现行）：DMG 走百度网盘，release 只放下载页链接

DMG 内置 Whisper 大模型约 **1.6GB**，GitHub 附件慢、Gitee 附件硬上限 100MB，两边都不适合放包。
现行分发链路是 **固定下载页 + versions.json + 用户提供的网盘分享链接**：

- **下载页**：http://47.119.175.47/mixcut/ （nginx `location ^~ /mixcut/` → `/www/wwwroot/dlpage/`）
- **版本库**：`/www/wwwroot/dlpage/versions.json`，结构 `{"mac":[{version,date,size,url},…], "win":[…]}`，
  每平台一个数组、**最新在最前**；主按钮取 `[0]`，弹窗列出全部历史版本（老链接一律保留）。
- **发新版 = 往对应数组最前面 prepend 一条**，改完即时生效。

**⚠️ 各自的职责边界（务必分清，我曾搞错）**：

| 谁 | 做什么 |
|---|---|
| 我（Claude） | 只负责：bump 版本 → 打带版本号的 DMG → 提交/推送/打 tag → 发 GitHub + Gitee release（**正文指向下载页，不传附件**） |
| 用户 | 把桌面上的 DMG 传到**百度网盘**，把分享链接（含提取码）发给我 |
| 我（拿到链接后） | 把链接 prepend 进服务器的 `versions.json` |

> **绝对不要自作主张把 DMG 上传到服务器 `/dl/`**。那是早期方案的遗留兜底路径，现行流程里包由用户放网盘。
> **不要用 `./release_gitee.sh`** —— 它会强制上传 1.6GB DMG 到 Gitee，必然失败。

**发版标准动作全序列**：
1. bump 版本号（VERSION + pbxproj 两处 MARKETING_VERSION）→ clean Release universal 构建 → 打 `MixCut-v<版本>.dmg`
2. 三项强制校验：主程序 `lipo -archs` == `x86_64 arm64`、4 个内置二进制均双架构、DMG 内 `CFBundleShortVersionString` == 目标版本
3. `git commit` → `git tag vX.Y.Z` → `git push origin main && git push gitee main` → `git push origin vX.Y.Z && git push gitee vX.Y.Z`
4. `gh release create vX.Y.Z --title … --notes-file …`（**不传 DMG**，正文「下载」段指向下载页）
5. Gitee `POST https://gitee.com/api/v5/repos/jinxiushanhehao/mixed_cut/releases`
   （jq 组 body，字段 access_token/tag_name/name/body/prerelease/target_commitish=main）
6. **等用户给百度网盘链接** → 更新服务器 `versions.json`

**凭据**：`GITEE_TOKEN` 与服务器 `CN_SSH_*` 都在项目根 `.env`（gitignored，绝不提交/外传）。
服务器登录用**密码**不是 key，且密码含特殊字符：
- 绝不能 `source .env`（`#` 会截断密码）；要 `grep -E '^CN_SSH_PASSWORD=' .env | sed -E 's/^CN_SSH_PASSWORD=//; s/^"(.*)"$/\1/'`
- ssh/scp 必须带 `-o PreferredAuthentications=password -o PubkeyAuthentication=no` + `sshpass`

**历史 Gitee release id**：v0.7.1=736815 / v0.8.0=739784 / v0.8.1=744314 / v0.9.0=750028 / v0.9.1=754773 / v0.9.2=759430
（正文改动用 `PATCH …/releases/{id}`，GitHub 用 `gh release edit vX.Y.Z --notes-file`）

## 关键开发规则（必须遵守）

### 双系统（Universal）支持铁律 ⚠️⚠️⚠️

MixCut 必须**同时原生支持 Apple Silicon 与 Intel Mac**。任何构建、发版、二进制改动都必须保持 universal，绝不能退回 arm64-only（否则 Intel 同事装了直接报「这台 Mac 不支持此应用程序」）。

1. **主程序**：Release/DMG 构建必须带 `-destination 'generic/platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO`。普通 `xcodebuild ... Release build` 只出本机 arm64，**严禁**用它打分发包。
2. **内置二进制**：ffmpeg / ffprobe / whisper / demucs 必须都是 universal（arm64 + x86_64）静态自包含二进制，由 `./scripts/build_universal_binaries.sh` 生成；改动或更新任何内置二进制后，必须重跑该脚本并 `python3 bundle_deps.py` 校验。
3. **发版前强制校验**（缺一不可）：
   - `lipo -archs <app>/Contents/MacOS/MixCut` == `x86_64 arm64`
   - 四个内置二进制逐个 `lipo -archs` 均为双架构（或直接 `python3 bundle_deps.py`）
   - DMG 内 `CFBundleShortVersionString` == 目标版本号
4. **新增任何内置二进制/处理链组件**：默认就要做成 universal，并纳入 `build_universal_binaries.sh` 与 `bundle_deps.py` 的校验清单。

> 背景：v0.6.0 曾因 arm64-only 分发导致 Intel 同事「不支持此应用程序」；v0.6.1 起整条链改为 universal。此后**任何发版都必须守住双系统**。

### 不要在修改过程中破坏已有功能（最重要 ⚠️⚠️⚠️）

修改任何代码前，**必须先识别该文件/模块已有的功能点**；改完后这些功能必须依然完整可用。**严禁为了修一个问题而误伤相邻功能**。

#### 强制 SOP（每次代码改动都必走）
1. **改动前**：通读要改的文件 + 周边文件（相同 view tree），用一句话列出"这里能做的事"（点击/双击/编辑/选中复制/拖拽/右键菜单/键盘快捷键/项目切换联动 等等）。
2. **改动中**：每次修改只针对当前任务，不要顺手"重构"周边代码。
3. **改动后**：人工跑一遍受影响的视图，**逐项验证**第 1 步列出的能力，确认没破坏。
4. **疑似删改**：不确定某段代码的作用时，先查 `git blame` / `git log`，不要随意删改。

#### 已知容易被误伤的功能清单（动相关文件时必须回归验证）
- **素材导入页**：台词行双击编辑、台词文本选中复制、视频卡片文件名选中复制、卡片右键菜单
- **分镜素材库**：多选模式（checkbox + 全选/反选/清空）、批量导出（编号 + 命名规则）、批量删除、Equatable 性能优化、`isHovering/isSelected` 控制 BoundaryAdjustRow 显示
- **分镜库 / 项目概览 / 素材导入**：切换项目时的**数据联动刷新**（详见下一节"切换项目铁律"）
- **导出**：默认 H.264 硬件加速、分镜导出第一帧不黑屏（trim filter + setpts 重置时间戳）
- **强制浅色外观**：`MixCutApp.init()` 中 `NSApplication.shared.appearance = .aqua`
- **应用启动恢复上次项目**：`ProjectViewModel.setModelContext` 末尾的 lastSelectedProjectID 恢复
- **缩略图全局缓存**：`ThumbnailCache.shared`，不要重新引入 `NSImage(contentsOfFile:)` 直接同步加载
- **Toast / InlineBanner / SkeletonView**：全局共享组件，新视图需要错误提示/loading 时复用

#### 当出现 bug 时不要"修一个改坏三个"
本项目已多次出现"修一个 bug 把别的功能改坏"的情况。**当你的改动跨越多个文件 / 改了核心视图时，必须用第 3 步的人工验证来兜底**，不要假设 SwiftUI 的 diff 会保护你。

### 切换项目时各模块必须联动刷新（多次踩坑，铁律 ⚠️）

所有依赖项目数据的视图，必须使用以下两种之一加载数据：

```swift
// ✅ 写法 A：onAppear + onChange（最稳）
.onAppear { viewModel.loadData(for: project) }
.onChange(of: project.id) { viewModel.loadData(for: project) }

// ✅ 写法 B：.task(id: project.id) — 在 project.id 变化时自动重新执行
.task(id: project.id) {
    isLoading = true
    viewModel.loadData(for: project)
    isLoading = false
}

// ❌ 错误：仅 onAppear（切换项目时视图复用不会重新触发）
.onAppear { viewModel.loadData(for: project) }
```

#### 🚨 致命陷阱：`.task(id:)` 必须放在 body 最外层

**绝对不要**把 `.task(id: project.id)` 附加在条件渲染的子视图上：

```swift
// ❌ 致命错误：当 isLoading=false 时 SkeletonView 不渲染 → task 消失 → 切换项目不联动！
var body: some View {
    if isLoading {
        SkeletonView()
            .task(id: project.id) { ... isLoading = false }   // ← task 绑在条件分支上
    } else {
        mainContent
    }
}

// ✅ 正确：task 在 Group 外层，无论 isLoading 状态如何都监听 project.id
var body: some View {
    Group {
        if isLoading { SkeletonView() } else { mainContent }
    }
    .task(id: project.id) {        // ← task 跟随整个 view 生命周期
        isLoading = true
        // load data...
        isLoading = false
    }
}
```

**为什么犯过这个错**：2026-05-23 我把性能优化的 task 绑到了 SkeletonView 上，导致从其他项目切回来时（isLoading 已经是 false）task 不触发，数据停留在上一个项目。这种错误**视觉上一切正常但数据完全是错的**，必须人工切项目验证才能发现。

#### 检查清单（改完依赖项目的视图必须人工跑一遍）
1. 项目 A → 项目 B：视频列表、分镜、统计数据是否变成 B 的？
2. B → A 回切：A 数据完整？
3. 多选状态下切项目：选中状态是否清空？

#### 已修复 / 必须遵循此模式的视图
- ProjectOverviewView（用 `.task(id: project.id)`）
- ImportView（用 `.task(id: project.id)`）
- SegmentLibraryView（用 `.task(id: project.id)`）
- SchemeListView、ExportView（用 `onAppear + onChange`）
新增视图如果依赖项目数据，必须遵循以上模式。

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
