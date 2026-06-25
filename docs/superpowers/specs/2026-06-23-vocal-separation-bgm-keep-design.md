# 去原声留 BGM（本地人声分离）设计

**日期**: 2026-06-23
**目标**: 非「保留原声」的分镜，导出时去掉原音频里的人声旁白、保留背景音乐(BGM)，再把新 TTS 配音混入，得到「原 BGM + 新配音」。

## 方案选择
**本地 AI 人声分离**（用户拍板）。选 **demucs.cpp**（sevagh/demucs.cpp）：
- C++17 + 头文件库 Eigen + GGML，无 Python/onnxruntime，**与已内置的 whisper.cpp 同一套打包模式**。
- 支持 `--two-stems`：只分「vocals / no_vocals(伴奏)」。我们取 **no_vocals = BGM**。
- 模型 `ggml-model-htdemucs-4s-f16.bin`(~81MB)，首次使用下载到 Caches（同 whisper 模型策略），不进 DMG。

## 架构

### 1) 打包（开箱即用）
- 编译 demucs.cpp 为 macOS 通用二进制（arm64 优先，x86_64 视情况），放 `Resources/bin/`。
- `bundle_deps.py` 负责把二进制及 dylib 修成 `@loader_path`。开发期 fallback 系统/本地构建产物。
- 模型首次使用下载到 `~/Library/Caches/com.mixcut.app/demucs-models/`。

### 2) VocalSeparationService（actor）
- 输入：某分镜在原视频里的音频区间（用 ffmpeg 按 startTime/endTime 截原音频为 wav）。
- 运行 demucs.cpp `--two-stems` → 得到 `no_vocals.wav`(BGM)。
- **缓存**：结果按 `videoHash + startFrame + endFrame` 落盘缓存（确定性，避免重复分离）；路径 `AppSupport/MixCut/BGM/{videoHash}/{startFrame}-{endFrame}.wav`。
- 容错：分离失败 → 返回 nil，导出回退到「纯 TTS（无 BGM）」并记录日志。

### 3) 导出混音（DubExportService）
- 对**非锁定且选用了配音变体**的分镜：最终音轨 = `amix(BGM 分离结果, 新 TTS)`（ffmpeg），而非纯 TTS。
  - BGM 与 TTS 按合适增益混合（TTS 略高，保证人声清晰；BGM 适当压低，如 -6dB 或加 sidechain ducking 可后续优化）。
- **锁定（保留原声）分镜**：完全不动原音频（含原 BGM+原人声）。
- 无配音变体的分镜：原音频。

### 4)（可选，后续）预览
- 变体 ▶ 暂仍只试听 TTS；BGM 混音在导出体现。后续可加「BGM+配音」预览。

## 性能
demucs.cpp CPU 推理较慢（每段可能数十秒）。分离按分镜并**缓存**，只在首次导出/生成时跑；进度提示必须有。建议分离在导出前批量预跑并显示进度。

## 测试
- demucs.cpp 二进制本地实测：拿一段真实素材音频跑 `--two-stems`，人工听 no_vocals 是否干净（我自己先测，不让用户当测试员）。
- VocalSeparationService 的缓存键、回退逻辑：纯逻辑部分抽到可测函数。
- 导出混音：在一条分镜上端到端验证「能听到原 BGM + 新配音」。

## 分阶段
- **Stage 1**：编译+打包 demucs.cpp，VocalSeparationService 产出 BGM 分离，单段实测质量。
- **Stage 2**：接入 DubExportService 混音，端到端导出验证。

## 非目标（本期）
- sidechain 自动闪避(ducking) 的精细调参（先用固定增益）。
- 变体级「BGM+配音」实时预览。
- 6-stem / 多模型选择。
