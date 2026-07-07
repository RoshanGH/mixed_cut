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

echo "==> [2/3] whisper (whisper.cpp 源码, 两架构 lipo)"
git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git wcpp
pushd wcpp >/dev/null
# arm64：静态 + 内嵌 Metal（不降速）
cmake -B ba -DCMAKE_OSX_ARCHITECTURES=arm64 -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DCMAKE_BUILD_TYPE=Release \
  -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF >/dev/null
cmake --build ba -j8 --target whisper-cli >/dev/null
# x86_64：静态 + CPU/Accelerate（GGML_NATIVE=OFF 避免把 apple-m1 带进 x86 交叉编译）
cmake -B bx -DCMAKE_OSX_ARCHITECTURES=x86_64 -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF \
  -DGGML_METAL=OFF -DGGML_BLAS=ON -DGGML_ACCELERATE=ON -DCMAKE_BUILD_TYPE=Release \
  -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF >/dev/null
cmake --build bx -j8 --target whisper-cli >/dev/null
lipo -create ba/bin/whisper-cli bx/bin/whisper-cli -output ../uni/whisper
popd >/dev/null

echo "==> [3/3] demucs (demucs.cpp 源码, 两架构 lipo)"
git clone --depth 1 --recurse-submodules https://github.com/sevagh/demucs.cpp.git dcpp
pushd dcpp >/dev/null
sed -i '' 's/ -march=native//' CMakeLists.txt      # 去掉 native（x86 交叉编译会报 apple-m1）
# macOS 下 USE_OPENBLAS=ON → find_package(BLAS)=Accelerate；CMAKE_POLICY_VERSION_MINIMUM 兼容老 cmake_minimum
for a in arm64 x86_64; do
  cmake -B "b_$a" -DCMAKE_OSX_ARCHITECTURES=$a -DUSE_OPENBLAS=ON \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 >/dev/null
  cmake --build "b_$a" -j8 --target demucs.cpp.main >/dev/null
done
lipo -create b_arm64/demucs.cpp.main b_x86_64/demucs.cpp.main -output ../uni/demucs
popd >/dev/null

echo "==> 安装到 $DEST"
for b in ffmpeg ffprobe whisper demucs; do
  install -m 0755 "uni/$b" "$DEST/$b"
  echo "   $b: $(lipo -archs "$DEST/$b")"
done

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
