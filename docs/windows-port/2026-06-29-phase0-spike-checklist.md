# Phase 0 Spike —— Windows「开箱即用」处理链可行性验证清单

> 分支：`windows-port`
> 日期：2026-06-29
> 目标：**只验证一件事**——能不能在一台干净的 Windows 机器上，把 MixCut 赖以生存的本地处理链（FFmpeg + Whisper + demucs）跑通，且不要求用户预装任何东西。
> 时长预算：1–2 周。
> 判定：**全绿 → 进入正式 Tauri 重写；任意一项红 → 停下重新设计架构（如改本地服务/云处理），不要硬上。**

## 为什么先做这个

整套 app 的核心卖点是「像剪映一样双击即用」。Mac 版靠把 ffmpeg/whisper/demucs 二进制 + dylib 内置进 bundle 实现。Windows 能不能同样做到，是整个跨端方案**唯一的真未知数**——其余（UI 重写、SQLite、AI HTTP 调用）都是确定性工程量。这一步**最便宜地证伪**，所以必须最先做。

## 测试环境要求

- [ ] 一台**干净的 Windows 11 x64**（虚拟机即可，关键是「未装过 ffmpeg/python/visual studio 运行库之外的东西」，模拟真实用户）
- [ ] 准备一条**真实 9:16 竖屏广告测试视频**（带人声 + BGM，30fps，≥60s）——和 Mac 端用同一条，便于对比
- [ ] 一台开发机（可 Mac，用于交叉编译/打包），以及 Windows 上的最小构建环境（仅当需要现场编译 whisper/demucs 时）

---

## 验证项 1：FFmpeg / FFprobe（风险：🟢 低）

MixCut 用 ffmpeg 做：场景切换检测、静音检测、I-frame 提取、缩略图、**按帧号精确切片**、导出拼接。

- [ ] **1.1 获取 Windows 静态构建**：从 gyan.dev 或 BtbN/FFmpeg-Builds 下载 `ffmpeg.exe` + `ffprobe.exe`（GPL static 版，自带常用编解码器，无外部 dll 依赖）。记录版本号与体积。
- [ ] **1.2 探测**：`ffprobe.exe -v error -show_streams -of json <测试视频>` → 能正确输出分辨率 1080x1920 / fps / 时长 / 有音频流。
- [ ] **1.3 场景检测**：复刻 `SceneDetectionService` 的 `select='gt(scene,0.3)'` 或 `scdet` 滤镜 → 能输出场景切换时间点列表。
- [ ] **1.4 静音检测**：`silencedetect=noise=-30dB:d=0.5` → 输出静音区间。
- [ ] **1.5 按帧号精确切片**：复刻 `FFmpegRunner.cutSegment` 的 `trim=start_frame=N:end_frame=M,setpts=PTS-STARTPTS` → 切出的片段**第一帧不黑、时长精确、帧数对**。
- [ ] **1.6 ⚠️ 导出编码器（关键差异点）**：Mac 端用的 `h264_videotoolbox` 是 **Apple 独占硬件编码器，Windows 上没有**。必须验证 Windows 的替代：
  - [ ] 软件兜底 `libx264`（一定可用，慢）能正常出 H.264 mp4
  - [ ] 探测并尝试硬件编码器：NVIDIA `h264_nvenc` / Intel `h264_qsv` / AMD `h264_amf`（按显卡选，没有就回退 libx264）
  - [ ] **结论记录**：Windows 导出需要「探测可用硬件编码器 → 否则 libx264」的平台自适应逻辑（Tauri 重写时实现）
- [ ] **1.7 拼接导出**：复刻 concat 流程，多段拼成一条 9:16 mp4，能正常播放、音画同步。
- **通过标准**：1.2–1.7 全部产出正确结果；明确记录 Windows 导出用哪个编码器。
- **失败/回退**：FFmpeg 几乎不可能失败（成熟跨平台），若有问题多半是参数差异，可调。

---

## 验证项 2：Whisper 本地 ASR（风险：🟡 中）

MixCut 用 whisper.cpp + `ggml-small.bin`（~488MB）做本地语音识别，**需要字级时间戳**。

- [ ] **2.1 获取 Windows 版 whisper.cpp**：
  - [ ] 优先找官方/社区预编译的 `whisper-cli.exe`（whisper.cpp release 有 Windows x64 二进制）；记录是否需要附带 dll（如 OpenBLAS/ggml dll）
  - [ ] 若无合适预编译版：在 Windows 上用 CMake 编译 whisper.cpp（CPU 版即可，先不追求 GPU）
  - [ ] **注意**：Mac 端用的是 Metal 加速版（`libggml-metal.dylib`），Windows 没有 Metal → **用 CPU 版**（或后续探索 CUDA/Vulkan）。先验证 CPU 版能跑、速度可接受。
- [ ] **2.2 模型下载**：确认 `ggml-small.bin` 下载逻辑在 Windows 可用（首次启动下到用户目录，路径用跨平台 API）。
- [ ] **2.3 识别 + 字级时间戳**：对测试视频抽出的 16kHz 单声道 wav 跑 whisper-cli，开启字级时间戳（`-ml 1` / `--output-json` 带 word timestamps）→ 输出**逐字带时间**的 JSON。
- [ ] **2.4 准确度/速度对比**：和 Mac 端同一条视频的识别结果对比（文字内容应一致；CPU 版速度记录下来，评估是否可接受，例如 60s 视频识别耗时）。
- **通过标准**：能在干净 Windows 上跑出带字级时间戳的中文识别结果，速度用户可忍受（如 ≤ 视频时长的 1–2 倍）。
- **失败/回退**：CPU 版太慢 → 评估 GPU 版（CUDA/Vulkan，复杂度上升）或**主推云 ASR**（项目已有千问 paraformer 云路径，纯 HTTP，Windows 零成本；本地 whisper 降级为可选）。

---

## 验证项 3：demucs 人声分离（风险：🔴 高 —— 最大未知数）

配音模块要把原声里的人声和 BGM 分离（克隆配音 + 保留原 BGM）。Mac 端内置的是 `demucs`（2.5MB 二进制，疑似 demucs.cpp）。**这是整个 Spike 最可能卡住的地方。**

- [ ] **3.1 搞清 Mac 端到底用的什么**：确认内置的 `demucs` 是 demucs.cpp（C++ 移植）还是别的；它依赖的模型文件在哪、多大。
- [ ] **3.2 找 Windows 版**：
  - [ ] demucs.cpp 能否在 Windows 编译出 `demucs.exe`？（CMake 构建，记录依赖：onnxruntime / ggml 之类）
  - [ ] 模型文件是否跨平台通用（同一份权重）？
- [ ] **3.3 实测分离**：对测试视频音轨跑分离 → 输出 `vocals.wav` + `no_vocals.wav`（BGM），人声/伴奏分离质量可接受。
- [ ] **3.4 速度**：记录分离一条 60s 音轨的耗时（CPU）。
- **通过标准**：Windows 上能产出可用的人声/BGM 分离结果。
- **失败/回退（重要，先想好）**：
  - 选项 A：换其他可跨平台的分离方案（如 ONNX 版 MDX/UVR 模型 + onnxruntime，Windows 支持好）
  - 选项 B：人声分离走**云 API**（牺牲「完全离线」）
  - 选项 C：**配音模块在 Windows v1 先不做人声分离**（配音直接覆盖整条音轨，BGM 保留作为后续增强）——把 Windows 首版范围缩小，先上线
  - **决策**：若 3 卡住，不阻塞整个项目，按 C 缩范围即可；记录决定。

---

## 验证项 4：Tauri 集成方式（风险：🟡 中）

验证「Tauri 怎么调这些二进制」，这决定打包形态。

- [ ] **4.1 Tauri sidecar 机制**：用 Tauri 的 sidecar（externalBin）把 ffmpeg.exe 打进安装包，从 Rust 端 `Command`/`tauri::api::process` 调用，拿到 stdout/stderr 和退出码。
- [ ] **4.2 进度解析**：能像现在 `FFmpegRunner` 那样实时读 ffmpeg 的 stderr 解析进度百分比。
- [ ] **4.3 跨平台路径/换行**：Rust 端用 `PathBuf`，验证 Windows 反斜杠路径、空格路径、中文路径（用户素材常有中文名）都能正确传给 ffmpeg。
- [ ] **4.4 大文件二进制打包**：把 ffmpeg + whisper(+模型) + demucs 一起打进 Tauri 安装包，记录**最终安装包体积**与安装/首次启动体验（模型可首启下载，不必全塞进安装包）。
- [ ] **4.5 一份代码双平台**：同一套 Tauri 工程，能分别产出 `.dmg`(Mac) 和 `.msi`/`.exe`(Windows) 安装包，sidecar 按平台带对应二进制。
- **通过标准**：Windows 上双击安装包 → 安装 → 启动 → 能调用内置 ffmpeg 跑出结果，无需用户装任何依赖。

---

## 验证项 5：视频预览/逐帧（风险：🟡 中，非阻塞但要心里有数）

- [ ] **5.1 网页 `<video>` 播放** 9:16 mp4 是否流畅。
- [ ] **5.2 逐帧/帧精度**：现在大量靠帧号（trim start_frame）。网页 video 的 `currentTime` 帧精度不如 AVKit。验证微调分镜边界时，能否用「Rust 端 ffmpeg 抽某一帧 → 显示静帧」来补偿帧精度。
- **通过标准**：能实现「拖到第 N 帧看画面」的微调体验（哪怕靠抽帧而非实时 seek）。
- **非阻塞**：即使体验略降级，也不影响项目可行性，记录方案即可。

---

## Spike 产出物（验证完必须交付）

- [ ] 一份**结论表**：5 个验证项逐条 🟢/🟡/🔴 + 关键数据（whisper CPU 速度、demucs 是否可行、安装包体积、Windows 用哪个编码器）
- [ ] **demucs 的去留决定**（过 / 换方案 / Windows v1 砍掉）
- [ ] 一个**最小可跑的 Tauri demo**：在 Windows 上导入 1 条视频 → 抽缩略图 + 跑一次 whisper 识别 → 屏幕上看到识别文字。证明「端到端能通」。
- [ ] 基于实测，**修正第 4–7 个月的工作量估算**（把未知数变成已知数）。

## 判定门槛（Go / No-Go）

| 结果 | 决定 |
|------|------|
| 1、2、4 全绿，3 至少有回退方案 | ✅ **GO**：进入正式 Tauri 重写，做迁移设计 + 实施计划 |
| 2（whisper）只能靠云 | 🟡 GO，但「完全离线」让步为「ASR 需联网」，产品上确认可接受 |
| 4（打包）做不到「双击即用」 | 🔴 NO-GO：重新考虑架构（本地服务/容器/云处理）|
| demucs 无解且配音是刚需 | 🟡 Windows v1 先砍人声分离，配音用整轨覆盖 |

---

> 这份清单只做「证伪/证可行」，**不写正式产品代码**。全绿后再进 brainstorming → 迁移设计 → 实施计划。
