# MixCut - AI 广告视频混剪工具

> Mac 原生桌面应用 | SwiftUI + SwiftData | 本地 AI 驱动

MixCut 是一款面向广告投放团队的 macOS 桌面工具。用户导入广告素材视频，AI 自动按语义切分镜头、标注类型，然后智能排列组合生成多条差异化的混剪广告视频。

## 功能特性

- **AI 语义切分** — 自动识别广告视频中的噱头引入、痛点、产品方案、效果展示等 11 种语义类型
- **本地语音识别** — 内置 whisper.cpp，离线完成语音转文字，支持中文
- **智能混剪方案** — AI 根据广告风格和目标受众，自动排列组合生成多条差异化广告
- **视频全局共享** — 同一视频跨项目共享，修改分镜全局同步，不重复处理
- **开箱即用** — FFmpeg、whisper 均内置于应用中，用户无需安装任何依赖

## 系统要求

- macOS 14.0 (Sonoma) 或更高版本
- Apple Silicon (M1/M2/M3/M4) 或 Intel Mac
- Xcode 15.0+, Swift 5.10+

## 构建与运行

### 1. 克隆项目

```bash
git clone git@github.com:RoshanGH/mixed_cut.git
cd mixed_cut
```

### 2. 打包依赖二进制

项目依赖 FFmpeg 和 whisper.cpp，需要先通过脚本打包到 `MixCut/Resources/bin/`：

```bash
# 安装依赖（如未安装）
brew install ffmpeg whisper-cpp

# 打包二进制及其 dylib 到 Resources/bin/
python3 bundle_deps.py
```

### 3. 编译运行

在 Xcode 中打开 `MixCut.xcodeproj`，选择 MixCut scheme，点击运行。

或命令行编译：

```bash
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build
```

### 4. 配置 AI 提供商

首次运行后，在 **设置** 中配置 AI 提供商的 API Key：

| 提供商 | 说明 |
|--------|------|
| 千问 (Qwen) | 阿里通义千问 |
| MiniMax | MiniMax 大模型 |
| Claude (国内转发) | Anthropic Claude 国内转发 |
| Claude | Anthropic Claude 官方 API |
| 自定义 | 任意 OpenAI 兼容 API（自填地址 + 模型名） |

## 技术架构

```
┌─────────────────────────────────────────────────────┐
│                    SwiftUI Views                     │
├─────────────────────────────────────────────────────┤
│                @Observable ViewModels                │
├─────────────────────────────────────────────────────┤
│                   Service Layer                      │
│  SceneDetection │ ASR │ AIAnalysis │ SchemeGen │ Export│
├─────────────────────────────────────────────────────┤
│              Data Layer (SwiftData)                   │
│  Project │ ProjectVideo │ Video │ Segment │ MixScheme │
├─────────────────────────────────────────────────────┤
│                   Infrastructure                     │
│  FFmpeg (bundled) │ whisper.cpp │ AI API │ AVKit      │
└─────────────────────────────────────────────────────┘
```

### 核心数据流

```
视频导入 → FFmpeg 提取元数据/缩略图
         → FFmpeg 场景检测 + 静音检测 + I-frame 提取
         → Whisper 本地语音识别 (ASR)
         → AI 语义分析（结构化文本，不传视频）
         → 四阶段边界优化
         → 分镜素材库
         → AI 混剪方案生成
         → FFmpeg 视频导出
```

### 数据模型

```
Project *──* Video 1──* Segment    (视频全局共享，通过 ProjectVideo 多对多)
Project 1──* MixScheme 1──* SchemeSegment *──1 Segment
```

## 项目结构

```
MixCut/
├── App/              入口 + 主路由
├── Models/           SwiftData 模型 (6 个 @Model)
├── ViewModels/       @Observable ViewModel
├── Services/         业务逻辑 (actor 隔离)
│   ├── AI/           AI 提供商 (OpenAI 兼容协议)
│   ├── ASR/          语音识别 (whisper.cpp)
│   ├── VideoProcessing/  FFmpeg 封装
│   ├── BoundaryOptimizer/  边界优化
│   ├── SchemeGeneration/   方案生成
│   └── Export/       视频导出
├── Views/            SwiftUI 视图
│   ├── Sidebar/      侧边栏导航
│   ├── Overview/     项目概览
│   ├── Import/       素材导入
│   ├── SegmentLibrary/  分镜素材库
│   ├── Schemes/      混剪方案
│   ├── Export/       导出
│   └── Settings/     设置
├── Utilities/        工具类
└── Resources/        Prompt 模板 + 二进制依赖
```

## 开发状态

当前处于 **Phase 1 MVP** 阶段：

- [x] 素材导入 + AI 分析流水线
- [x] 分镜素材库浏览/筛选/微调
- [x] 混剪方案生成 (两步 AI 流程)
- [x] 视频全局共享 (跨项目去重)
- [ ] 端到端导出验证
- [ ] 批量导出

## 联系方式

- **开发者**: MengGang
- **手机/微信**: 13462890087
- **GitHub**: [@RoshanGH](https://github.com/RoshanGH)

## License

MIT License
