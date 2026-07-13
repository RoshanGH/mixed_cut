#!/usr/bin/env bash
# 生成 MixCut 所需的 universal (arm64 + x86_64) 内置二进制到 MixCut/Resources/bin/
#
# 背景：为支持 Intel Mac，主程序与三个内置二进制都必须是 universal。
# 全部做成「静态 / 自包含」——无外部 dylib，bundle 极简，两架构各带自己的加速：
#   - ffmpeg/ffprobe：下载静态构建（evermeet=x86_64，osxexperts=arm64）→ lipo
#   - whisper       ：源码编两架构（arm64 内嵌 Metal，x86_64 走 CPU/Accelerate）→ lipo
#   - demucs        ：demucs.cpp 源码编两架构（Accelerate BLAS）→ lipo
#   - 模型 ggml-htdemucs-4s.bin：架构无关，单独放（见 VocalSeparationService 下载兜底）
#
# 依赖：cmake、git、curl、unzip、Xcode 命令行工具。产物为静态，仅依赖系统框架。
# 用法：./scripts/build_universal_binaries.sh
set -euo pipefail

FFMPEG_VER="8.1"                     # osxexperts arm64 用此主版本；evermeet x86_64 用下面的精确版
FFMPEG_X86_VER="8.1.2"
# ⚠️ 部署目标铁律：源码本机编的 whisper/demucs 必须显式设低 min，否则在装了新 SDK(如 macOS 26)
# 的开发机上会被编成 minos=SDK 版本，且可能强引用新系统独有符号(如 Metal MTLResidencySetDescriptor)，
# 导致所有老系统 Mac 在 dyld 加载期崩溃(退出码6)、本地功能全废。见 project_whisper_metal_crash。
DEPLOY="13.0"                        # 内置二进制统一部署目标 = macOS 13（覆盖我们声称支持的 14+ 且留余量）
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/MixCut/Resources/bin"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$DEST" "$WORK/uni"
cd "$WORK"

echo "==> [1/3] ffmpeg / ffprobe (静态 universal)"
for tool in ffmpeg ffprobe; do
  curl -sL "https://evermeet.cx/ffmpeg/${tool}-${FFMPEG_X86_VER}.zip" -o "${tool}_x86.zip"
  unzip -oq "${tool}_x86.zip" -d x86       # evermeet = x86_64 静态
  curl -sL "https://www.osxexperts.net/${tool}${FFMPEG_VER//./}arm.zip" -o "${tool}_arm.zip"
  unzip -oq "${tool}_arm.zip" -d arm       # osxexperts = arm64 静态
  lipo -create "arm/$tool" "x86/$tool" -output "uni/$tool"
done

echo "==> [2/3] whisper (whisper.cpp 源码, 编 GPU 版 + CPU 版两个二进制)"
# 兼容策略：产出两个 whisper 二进制，ASRService 运行时先试 GPU 版、失败自动换 CPU 版（见 project_whisper_metal_crash）。
#  - whisper     = arm64(Metal ON, GPU 加速) + x86_64(CPU)  ← 新系统走这个
#  - whisper-cpu = arm64(Metal OFF, CPU)     + x86_64(CPU)  ← 老系统/GPU 失败兜底，必须 minos 低且无 Metal
# 之所以要两个独立二进制：老系统上 Metal 版会在 dyld 加载期就崩（--no-gpu 运行期参数救不了），
# 只有换成另一个不链接 Metal 的二进制才能真正兜底。
git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git wcpp
pushd wcpp >/dev/null
CPU_FLAGS="-DGGML_METAL=OFF -DGGML_BLAS=ON -DGGML_ACCELERATE=ON"
COMMON="-DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=$DEPLOY \
  -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF"
# arm64 GPU 版（Metal 内嵌）
cmake -B ba_gpu -DCMAKE_OSX_ARCHITECTURES=arm64 -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON $COMMON >/dev/null
cmake --build ba_gpu -j8 --target whisper-cli >/dev/null
# arm64 CPU 版（Metal OFF + Accelerate）
cmake -B ba_cpu -DCMAKE_OSX_ARCHITECTURES=arm64 $CPU_FLAGS $COMMON >/dev/null
cmake --build ba_cpu -j8 --target whisper-cli >/dev/null
# x86_64 CPU（GGML_NATIVE=OFF 避免把 apple-m1 带进 x86 交叉编译）；Intel 无实用 Metal，一律 CPU
cmake -B bx_cpu -DCMAKE_OSX_ARCHITECTURES=x86_64 -DGGML_NATIVE=OFF $CPU_FLAGS $COMMON >/dev/null
cmake --build bx_cpu -j8 --target whisper-cli >/dev/null
lipo -create ba_gpu/bin/whisper-cli bx_cpu/bin/whisper-cli -output ../uni/whisper       # GPU 版（arm64 Metal + x86 CPU）
lipo -create ba_cpu/bin/whisper-cli bx_cpu/bin/whisper-cli -output ../uni/whisper-cpu    # CPU 版（两架构均 CPU）
popd >/dev/null

echo "==> [3/3] demucs (demucs.cpp 源码, 两架构 lipo)"
git clone --depth 1 --recurse-submodules https://github.com/sevagh/demucs.cpp.git dcpp
pushd dcpp >/dev/null
sed -i '' 's/ -march=native//' CMakeLists.txt      # 去掉 native（x86 交叉编译会报 apple-m1）
# macOS 下 USE_OPENBLAS=ON → find_package(BLAS)=Accelerate；CMAKE_POLICY_VERSION_MINIMUM 兼容老 cmake_minimum
for a in arm64 x86_64; do
  cmake -B "b_$a" -DCMAKE_OSX_ARCHITECTURES=$a -DCMAKE_OSX_DEPLOYMENT_TARGET=$DEPLOY -DUSE_OPENBLAS=ON \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 >/dev/null
  cmake --build "b_$a" -j8 --target demucs.cpp.main >/dev/null
done
lipo -create b_arm64/demucs.cpp.main b_x86_64/demucs.cpp.main -output ../uni/demucs
popd >/dev/null

echo "==> 安装到 $DEST"
for b in ffmpeg ffprobe whisper whisper-cpu demucs; do
  install -m 0755 "uni/$b" "$DEST/$b"
  echo "   $b: $(lipo -archs "$DEST/$b")"
done

# ⚠️ 老系统兼容强制校验：CPU 兜底二进制(whisper-cpu)与 demucs 的部署目标必须 ≤ 15、且不得强引用
# macOS26 独有 Metal 符号——它们是老系统唯一能跑的路。GPU 版 whisper 允许带 Metal/高 min（它是给新系统的，
# 老系统上会被 ASRService 检测失败后换 whisper-cpu）。任一兜底件不达标直接 fail。见 project_whisper_metal_crash。
echo "==> 校验兜底二进制部署目标 & 未来符号（whisper-cpu / demucs）"
for b in whisper-cpu demucs; do
  minfirst=$(otool -l "$DEST/$b" | awk '/minos/{print $2; exit}')
  major=${minfirst%%.*}
  if [ -n "$major" ] && [ "$major" -ge 16 ]; then
    echo "❌ $b 部署目标过高（minos=$minfirst），老系统会 dyld 崩溃。确认 CMAKE_OSX_DEPLOYMENT_TARGET=$DEPLOY 生效。"; exit 1
  fi
  if nm -u "$DEST/$b" 2>/dev/null | grep -q MTLResidencySet; then
    echo "❌ $b 强引用 macOS26 独有符号 MTLResidencySetDescriptor（Metal 未关干净），老系统会崩。"; exit 1
  fi
  echo "   ✓ $b: minos=$minfirst 无未来 Metal 符号"
done
echo "   ℹ️ whisper(GPU版): minos=$(otool -l "$DEST/whisper" | awk '/minos/{print $2; exit}')（允许带 Metal，失败自动降级 whisper-cpu）"

# 人声分离模型（架构无关）：不存在则从国内镜像下载
MODEL="$DEST/ggml-htdemucs-4s.bin"
if [ ! -f "$MODEL" ]; then
  echo "==> 下载 demucs 模型 (~80MB)"
  curl -sL "https://hf-mirror.com/datasets/Retrobear/demucs.cpp/resolve/main/ggml-model-htdemucs-4s-f16.bin" -o "$MODEL" \
    || curl -sL "https://huggingface.co/datasets/Retrobear/demucs.cpp/resolve/main/ggml-model-htdemucs-4s-f16.bin" -o "$MODEL"
fi

# Whisper ASR 模型（架构无关，~1.62GB）：内置进包，App 完全自包含、无需运行时下载。
# 缺失或体积不足（下了半个）则从国内镜像重新下载。国内镜像优先，超时/失败切原站。
WMODEL="$DEST/ggml-large-v3-turbo.bin"
WMIN=1600000000
WSIZE=$([ -f "$WMODEL" ] && stat -f%z "$WMODEL" 2>/dev/null || echo 0)
if [ "$WSIZE" -lt "$WMIN" ]; then
  echo "==> 下载 Whisper 模型 ggml-large-v3-turbo (~1.62GB)"
  curl -fL --retry 3 --retry-delay 2 "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin" -o "$WMODEL" \
    || curl -fL --retry 3 --retry-delay 2 "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin" -o "$WMODEL"
fi

echo "✅ 完成。全部为静态自包含 universal（含内置 Whisper/demucs 模型），无需 dylib、无需运行时下载。"
