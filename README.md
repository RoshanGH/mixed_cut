# MixCut - AI 广告视频混剪工具

> macOS 原生桌面应用 | SwiftUI + SwiftData | 本地 AI 驱动 | 开箱即用

MixCut 面向广告投放团队，两条主线能力：

- **智能混剪** — 导入广告素材 → AI 自动按语义切分分镜 → 智能排列组合 → 一键批量导出多条差异化广告
- **AI 配音 / 口播替换** — 一键改写台词 → 克隆原声音色 → 合成配音 → 保留原 BGM → 烧录新字幕 → 批量出多版

视频内容、API Key 全部本地处理，AI 调用只发送结构化文本、**不发视频**。FFmpeg / Whisper / 人声分离模型全部内置，**双击即用，无需安装任何依赖**。

> Windows 版（C# + WPF + .NET 8）：[RoshanGH/mixcut-windows](https://github.com/RoshanGH/mixcut-windows)

## 下载

| 平台 | 链接 |
|------|------|
| GitHub | [Releases](https://github.com/RoshanGH/mixed_cut/releases) |
| Gitee（国内）| [Releases](https://gitee.com/jinxiushanhehao/mixed_cut/releases) |

最新版本：**v0.6.0**

## 功能亮点

### AI 智能流水线
- **AI 语义切分** — 自动识别 11 种语义类型（噱头引入 / 痛点 / 产品方案 / 效果展示 / 信任背书 / 价格对比 / 活动福利 / 行动号召 / 产品定位 / 产品使用教育 / 过渡）
- **本地语音识别** — 内置 whisper.cpp（`ggml-large-v3-turbo` 模型，首次启动自动下载），完全离线，输出字级时间戳
- **单分镜重识别** — whisper 识别不准时，用阿里 `paraformer-realtime` 云端重识别单条分镜（不传视频，仅传该段音频）纠正台词
- **AI 混剪方案** — 两步生成：① AI 出策略（风格 / 受众 / 叙事结构）② AI 按策略排列分镜组合
- **多 AI 提供商** — 千问 / MiniMax / DeepSeek / Claude 原生 / 国内转发网关（Claude/Gemini/OpenAI 三平台）/ 自定义 OpenAI 兼容

### AI 配音 / 口播替换
- **一键改写** — AI 按多种广告风格，一次为每条分镜改写出 K 套差异化台词
- **原声克隆** — 内置 demucs 分离出纯人声 → 用千问 `qwen-vc` 克隆原视频说话人音色，自动克隆原声（无需手动选音色），换 API Key 自动重克隆
- **人声 / BGM 分离** — 内置 demucs（分离模型已随包内置，离线、无需下载），配音时保留原视频背景音乐
- **配音合成 + 时长对齐** — TTS 合成后按分镜时长对齐（变速），克隆配音 + 原 BGM 混音
- **烧录字幕（v0.6.0）** — 字号无级可调（滑条，占画面宽 3%~8.5%，**随分辨率自适应**）；**所见即所得**：示例字幕叠在分镜真实画面上、居中落在遮挡区、跟随遮挡框、拖动实时变化；**导出 = 预览**（贴字圆角胶囊底衬）；烧录时标点转空格但**保留 9.9 / 1,000 / 8:00 等数字**
- **字幕遮挡** — 三种处理：直接烧录 / 模糊虚化 / 纯色遮挡（盖住原片旧字幕再烧新字幕）
- **变体批量导出** — 每条分镜「原版 + 全部配音变体」一键导出多个 MP4

### 视频处理
- **硬件加速导出** — 默认 H.264 VideoToolbox 硬件编码，Apple Silicon 5-10× 软件编码速度
- **分镜批量导出** — 多选分镜 → 单独 MP4，文件命名 `{编号}_{原视频名}.mp4`
- **第一帧无黑屏** — 用 trim filter + setpts 精确切片，QuickTime 立即显示画面
- **视频全局共享** — 同一视频（SHA-256 哈希）跨项目共享，分镜修改全局同步

### 体验
- **键盘快捷键** — `⌘N` 新建项目 / `⌘1~5` 切换工作区 / `⌘B` 显隐侧边栏 / `⌘/` 快捷键面板 / 多选模式 `⌘A`/`⌘D`/`⌘0`/`Esc`
- **强制浅色外观** — 不跟随系统夜间模式
- **Toast + Skeleton + InlineBanner** — 完整的反馈 / 加载 / 错误展示体系
- **应用启动恢复上次项目** + **应用内更新检查**

### 容错与稳定性
- **AI JSON 4 层防御** — 预清洗 / 截断修复 / 错误位置救援 / 失败 JSON 落盘
- **每步独立容错** — 导入流水线每步失败不阻塞后续（元数据 / 缩略图 / ASR / AI 分析各自 try-catch）
- **国内网络友好** — 运行时下载的模型走国内镜像优先 + 超时重试；人声分离模型已内置根治超时
- **二进制路径调用时解析** — FFmpeg 路径运行时动态解析 + 系统回退，长任务中途也不误报「组件未找到」

## 系统要求

- macOS 14.0 (Sonoma) 或更高
- Apple Silicon (M1/M2/M3/M4) 推荐 | Intel Mac 软件编码回退可用
- 首次启动下载 Whisper 模型 ~1.5 GB（仅一次）；人声分离模型已内置无需下载

## 用户使用（普通用户）

直接下载 [Releases](https://github.com/RoshanGH/mixed_cut/releases) 的 DMG，拖到 Applications 即可。首次启动如提示「无法打开」，**右键 → 打开**。

### 配置 AI Key
首次启动会有引导。在 **设置 → AI 配置** 中填入 API Key：

| 提供商 | 说明 |
|--------|------|
| **千问 (Qwen)** | 阿里通义千问；配音的原声克隆 / TTS / 单分镜重识别也走千问（DashScope） |
| **MiniMax** | MiniMax M2.7 / abab 系列 |
| **DeepSeek** | DeepSeek-V4 系列 |
| **Claude** | Anthropic 官方 API |
| **国内转发网关** | 转发到 Claude / Gemini / OpenAI 三平台之一 |
| **自定义** | 任意 OpenAI 兼容 API（自填地址 + 模型名） |

> 配音功能（原声克隆 / TTS）依赖千问 DashScope，需开通 `qwen-voice-enrollment` 与 `qwen3-tts-vc`，并保证账户有可用额度。

## 开发者构建

```bash
# 1. 克隆
git clone https://github.com/RoshanGH/mixed_cut.git
cd mixed_cut

# 2. 打包二进制依赖到 Resources/bin/（ffmpeg / ffprobe / whisper / demucs + 模型）
brew install ffmpeg whisper-cpp
python3 bundle_deps.py

# 3. 用 Xcode 打开
open MixCut.xcodeproj

# 或命令行编译
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build
```

最低要求：Xcode 15.0+ / Swift 5.10+（SwiftData 宏依赖 Xcode 编译器，必须用 Xcode 构建）

## 技术架构

```
┌─────────────────────────────────────────────────────┐
│                    SwiftUI Views                     │
│  Overview │ Import │ SegmentLibrary │ Schemes │ Export │
│  + Dubbing（配音/字幕）+ Shared（Toast/Skeleton/...） │
├─────────────────────────────────────────────────────┤
│            @Observable ViewModels (MainActor)        │
├─────────────────────────────────────────────────────┤
│                  Service Layer (actor)               │
│  SceneDetection │ ASR(+paraformer) │ AIAnalysis      │
│  ScriptRewrite │ SchemeGen │ Export/DubExport        │
│  TTS(克隆/合成) │ VocalSeparation(demucs) │ Boundary │
├─────────────────────────────────────────────────────┤
│         MixCutCore（跨端可复用纯逻辑，可单测）        │
│  CaptionRenderer/Layout │ 变体组合 │ 对齐 │ 语速规划   │
├─────────────────────────────────────────────────────┤
│              Data Layer (SwiftData, 8 @Model)        │
│  Project │ ProjectVideo │ Video │ Segment │ SegmentDub│
│  MixStrategy │ MixScheme │ SchemeSegment             │
├─────────────────────────────────────────────────────┤
│                   Infrastructure                     │
│  FFmpeg + ffprobe │ whisper.cpp │ demucs(+模型)（均内置）│
│  AI API（千问/MiniMax/DeepSeek/Claude）│ AVKit        │
└─────────────────────────────────────────────────────┘
```

### 核心数据流

```
视频导入
  ↓ FFmpeg 元数据 / 缩略图
  ↓ FFmpeg 场景检测 + 静音检测 + ffprobe I-frame 提取
  ↓ Whisper 本地 ASR（字级时间戳，可用 paraformer 重识别单分镜）
  ↓ AI 语义分析（仅发送结构化文本，不传视频）
  ↓ 四阶段边界优化（句子吸附 → 场景对齐 → 静音吸附 → I-frame 对齐）
  ↓ 分镜素材库
  ├─ 混剪线：AI 方案（Step 1 策略 → Step 2 变体）→ FFmpeg 硬件加速导出
  └─ 配音线：一键改写台词 → demucs 分离人声 → 克隆原声 → TTS 合成 + 对齐
             → BGM 混音 → 烧录字幕（居中遮挡区 + 贴字胶囊）→ 变体批量导出
```

### 数据模型

```
Project *──* Video 1──* Segment          (视频全局共享，通过 ProjectVideo 多对多)
Segment 1──* SegmentDub                  (单分镜的多套配音变体)
Project 1──* MixStrategy 1──* MixScheme 1──* SchemeSegment *──1 Segment
```

## 项目结构

```
MixCut/
├── App/              MixCutApp / ContentView / 数据迁移
├── Models/           8 个 SwiftData @Model（含 SegmentDub）
├── ViewModels/       Project/Import/SegmentLibrary/Scheme/Export/Dubbing VM
├── Services/
│   ├── AI/           AIProvider 协议 + OpenAICompatibleClient + ScriptRewrite
│   ├── ASR/          ASRService（whisper）+ QwenASRClient（paraformer 重识别）
│   ├── TTS/          原声克隆 / TTS 合成 / demucs 人声分离 / 配音对齐
│   ├── VideoProcessing/  FFmpegRunner
│   ├── SceneDetection/   场景 / 静音 / I-frame
│   ├── BoundaryOptimizer/ 四阶段边界优化
│   ├── SchemeGeneration/  方案生成
│   ├── Export/       全量 / 批量分镜 / 配音导出 / 变体批量导出
│   └── UpdateChecker/    应用内更新检查
├── Views/
│   ├── Sidebar / Overview / Import / SegmentLibrary / Schemes / Export
│   ├── Settings / Shared（Toast/Skeleton/InlineBanner/ThumbnailCache/...）
├── Utilities/        KeychainHelper / FileHelper / DesignTokens
├── Resources/
│   ├── bin/          FFmpeg / ffprobe / whisper.cpp / demucs + 分离模型（内置）
│   └── Prompts/      AI Prompt 模板 (.md)
└── Assets.xcassets/  AppIcon + 颜色资源

Sources/MixCutCore/   跨端可复用纯逻辑（字幕渲染/落位、变体组合、边界对齐、语速规划等，含单测）
Tests/MixCutCoreTests/ MixCutCore 单元测试
```

## 开发状态

**Phase 1 MVP + 配音（已完成）**

- [x] 素材导入 + AI 分析流水线（场景检测 / 静音检测 / I-frame / Whisper / AI 语义切分 / 边界优化）
- [x] 分镜素材库（11 类筛选、视频/列表两视图、边界微调、多选、批量导出、批量删除）
- [x] 单分镜重识别（paraformer 纠正 whisper 不准）
- [x] 混剪方案生成（两步 AI 流程 + 4 层 JSON 容错）
- [x] 视频全局共享（跨项目去重）
- [x] 硬件加速导出（H.264/H.265 VideoToolbox）+ 分镜批量导出（编号 + 命名规则 + 无开头黑屏）
- [x] **AI 配音**：一键改写 + 原声克隆（demucs 分离 + qwen-vc）+ TTS 合成对齐 + BGM 混音 + 变体批量导出
- [x] **烧录字幕系统**：字号可调 + 所见即所得预览 + 居中遮挡区 + 导出=预览 + 标点转空格保留数字
- [x] 键盘快捷键体系 + 应用图标 + 应用内更新检查

**Phase 2（规划中）**

- [ ] 项目模板与方案预设
- [ ] 跨项目素材搜索
- [ ] 多语言字幕 / 配音适配

## 发版

每次发版双端同步（GitHub + Gitee，均含 DMG 附件）。开发者用 `release_gitee.sh` 同步 Gitee Release。

## 联系方式

- **开发者**: MengGang
- **手机/微信**: 13462890087
- **GitHub**: [@RoshanGH](https://github.com/RoshanGH)
- **Issues**: [GitHub Issues](https://github.com/RoshanGH/mixed_cut/issues)

## License

MIT License
