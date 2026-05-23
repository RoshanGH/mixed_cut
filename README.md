# MixCut - AI 广告视频混剪工具

> macOS 原生桌面应用 | SwiftUI + SwiftData | 本地 AI 驱动 | 开箱即用

MixCut 面向广告投放团队，**导入广告素材视频 → AI 自动按语义切分分镜 → 智能排列组合生成多条差异化广告视频 → 一键批量导出**。视频内容、API Key 全部本地处理，AI 调用只发送结构化文本不发视频。

## 下载

| 平台 | 链接 |
|------|------|
| GitHub | [Releases](https://github.com/RoshanGH/mixed_cut/releases) |
| Gitee（国内）| [Releases](https://gitee.com/jinxiushanhehao/mixed_cut/releases) |

最新版本：**v0.2.4**

## 功能亮点

### AI 智能流水线
- **AI 语义切分** — 自动识别 11 种语义类型（噱头引入 / 痛点 / 产品方案 / 效果展示 / 信任背书 / 价格对比 / 活动福利 / 行动号召 / 产品定位 / 产品使用教育 / 过渡）
- **本地语音识别** — 内置 whisper.cpp（`ggml-large-v3-turbo` 模型，首次启动自动下载），完全离线
- **AI 混剪方案** — 两步生成：① AI 出策略（风格/受众/叙事结构）② AI 按策略排列分镜组合
- **多 AI 提供商** — 千问 / MiniMax / DeepSeek / Claude 原生 / 国内转发网关（Claude/Gemini/OpenAI 三平台）/ 自定义 OpenAI 兼容

### 视频处理
- **硬件加速导出** — 默认 H.264 VideoToolbox 硬件编码，Apple Silicon 5-10× 软件编码速度
- **分镜批量导出** — 多选分镜 → 单独 MP4，文件命名 `{编号}_{原视频名}.mp4`
- **第一帧无黑屏** — 用 trim filter + setpts 精确切片，QuickTime 立即显示画面
- **视频全局共享** — 同一视频（SHA-256 哈希）跨项目共享，分镜修改全局同步

### 体验
- **键盘快捷键** — `⌘N` 新建项目 / `⌘1~5` 切换工作区 / `⌘B` 显隐侧边栏 / `⌘/` 快捷键面板 / 多选模式 `⌘A`/`⌘D`/`⌘0`/`Esc`
- **强制浅色外观** — 不跟随系统时间夜间模式
- **Toast + Skeleton + InlineBanner** — 完整的反馈/加载/错误展示体系
- **应用启动恢复上次项目**

### 容错与稳定性
- **AI JSON 4 层防御** — 预清洗 / 截断修复 / 错误位置救援 / 失败 JSON 落盘
- **ASR 智能降级** — 单 segment 整段时按标点重新切分，保证文字 100% 完整
- **AI 分析 lossless 数组解码** — 单条 segment 坏掉不影响整体

## 系统要求

- macOS 14.0 (Sonoma) 或更高
- Apple Silicon (M1/M2/M3/M4) 推荐 | Intel Mac 软件编码回退可用
- 首次启动下载 Whisper 模型 ~1.5 GB（仅一次）

## 用户使用（普通用户）

直接下载 [Releases](https://github.com/RoshanGH/mixed_cut/releases) 的 DMG，拖到 Applications 即可。首次启动如提示「无法打开」，**右键 → 打开**。

### 配置 AI Key
首次启动会有引导。在 **设置 → AI 配置** 中填入 API Key：

| 提供商 | 说明 |
|--------|------|
| **千问 (Qwen)** | 阿里通义千问 |
| **MiniMax** | MiniMax M2.7 / abab 系列 |
| **DeepSeek** | DeepSeek-V4 系列 |
| **Claude** | Anthropic 官方 API |
| **国内转发网关** | 转发到 Claude / Gemini / OpenAI 三平台之一 |
| **自定义** | 任意 OpenAI 兼容 API（自填地址 + 模型名） |

## 开发者构建

```bash
# 1. 克隆
git clone https://github.com/RoshanGH/mixed_cut.git
cd mixed_cut

# 2. 打包二进制依赖到 Resources/bin/
brew install ffmpeg whisper-cpp
python3 bundle_deps.py

# 3. 用 Xcode 打开
open MixCut.xcodeproj

# 或命令行编译
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build
```

最低要求：Xcode 15.0+ / Swift 5.10+

## 技术架构

```
┌─────────────────────────────────────────────────────┐
│                    SwiftUI Views                     │
│  Overview │ Import │ SegmentLibrary │ Schemes │ Export │
│  + Shared (Toast / Skeleton / InlineBanner / ...)    │
├─────────────────────────────────────────────────────┤
│            @Observable ViewModels (MainActor)        │
├─────────────────────────────────────────────────────┤
│                  Service Layer (actor)               │
│  SceneDetection │ ASR │ AIAnalysis │ SchemeGen       │
│  Export │ BatchSegmentExport │ BoundaryOptimizer     │
├─────────────────────────────────────────────────────┤
│              Data Layer (SwiftData)                   │
│  Project │ ProjectVideo │ Video │ Segment            │
│  MixStrategy │ MixScheme │ SchemeSegment             │
├─────────────────────────────────────────────────────┤
│                   Infrastructure                     │
│  FFmpeg + ffprobe (bundled) │ whisper.cpp (bundled)  │
│  AI API (千问/MiniMax/DeepSeek/Claude) │ AVKit       │
└─────────────────────────────────────────────────────┘
```

### 核心数据流

```
视频导入
  ↓ FFmpeg 元数据 / 缩略图
  ↓ FFmpeg 场景检测 + 静音检测 + ffprobe I-frame 提取
  ↓ Whisper 本地 ASR（字级时间戳）
  ↓ AI 语义分析（仅发送结构化文本，不传视频）
  ↓ 四阶段边界优化（句子吸附 → 场景对齐 → 静音吸附 → I-frame 对齐）
  ↓ 分镜素材库
  ↓ AI 混剪方案（Step 1: 策略 → Step 2: 变体）
  ↓ FFmpeg 硬件加速导出（VideoToolbox）
```

### 数据模型

```
Project *──* Video 1──* Segment  (视频全局共享，通过 ProjectVideo 多对多)
Project 1──* MixStrategy 1──* MixScheme 1──* SchemeSegment *──1 Segment
```

## 项目结构

```
MixCut/
├── App/              MixCutApp / ContentView / 数据迁移
├── Models/           7 个 SwiftData @Model
├── ViewModels/       Project/Import/SegmentLibrary/Scheme/Export VM
├── Services/
│   ├── AI/           AIProvider 协议 + OpenAICompatibleClient
│   ├── ASR/          ASRService（whisper.cpp 封装）
│   ├── VideoProcessing/  FFmpegRunner
│   ├── SceneDetection/   场景/静音/I-frame
│   ├── BoundaryOptimizer/ 四阶段边界优化
│   ├── SchemeGeneration/  方案生成
│   └── Export/       全量导出 + 批量分镜导出
├── Views/
│   ├── Sidebar/      侧边栏 + 项目管理
│   ├── Overview/     项目概览
│   ├── Import/       素材导入
│   ├── SegmentLibrary/  分镜库 + 批量导出
│   ├── Schemes/      混剪方案
│   ├── Export/       全量导出
│   ├── Settings/     设置
│   └── Shared/       Toast / Skeleton / InlineBanner / ThumbnailCache / KeyboardShortcutsSheet
├── Utilities/        KeychainHelper / FileHelper / DesignTokens
├── Resources/
│   ├── bin/          FFmpeg / ffprobe / whisper.cpp（内置）
│   └── Prompts/      AI Prompt 模板 (.md)
└── Assets.xcassets/  AppIcon + 颜色资源
```

## 开发状态

**Phase 1 MVP**（基本完成）

- [x] 素材导入 + AI 分析流水线（场景检测 / 静音检测 / I-frame / Whisper / AI 语义切分 / 边界优化）
- [x] 分镜素材库（11 类筛选、视频/列表两视图、边界微调、多选、批量导出、批量删除）
- [x] 混剪方案生成（两步 AI 流程 + 4 层 JSON 容错）
- [x] 视频全局共享（跨项目去重）
- [x] 硬件加速导出（H.264/H.265 VideoToolbox）
- [x] 分镜批量导出（编号 + 命名规则 + 无开头黑屏）
- [x] 键盘快捷键体系
- [x] 应用图标 + 全套 UI 体验优化

**Phase 2（规划中）**

- [ ] 音轨分离（口播 / BGM / 音效）—— 用于替换 BGM、多语言适配
- [ ] 项目模板与方案预设
- [ ] 跨项目素材搜索

## 发版

每次发版双端同步（GitHub + Gitee）。开发者用 `release_gitee.sh` 同步 Gitee Release（含 DMG 附件）。

## 联系方式

- **开发者**: MengGang
- **手机/微信**: 13462890087
- **GitHub**: [@RoshanGH](https://github.com/RoshanGH)
- **Issues**: [GitHub Issues](https://github.com/RoshanGH/mixed_cut/issues)

## License

MIT License
