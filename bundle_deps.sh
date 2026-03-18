#!/bin/bash
# 将 FFmpeg 和 whisper.cpp 及其所有依赖打包到 app Resources/bin 中
set -e

DEST="/Users/menggang/www/Mixed_cut/MixCut/Resources/bin"
rm -rf "$DEST"
mkdir -p "$DEST"

# ============================================================
# 递归收集非系统 dylib 的函数
# ============================================================
declare -A COLLECTED  # 已收集的 dylib（避免重复）

collect_dylibs() {
    local binary="$1"
    local deps
    deps=$(otool -L "$binary" | tail -n +2 | awk '{print $1}' | grep -v "/usr/lib" | grep -v "/System" | grep -v "@rpath" | grep -v "@executable_path" || true)

    for dep in $deps; do
        local realpath
        realpath=$(readlink -f "$dep" 2>/dev/null || echo "$dep")
        local basename
        basename=$(basename "$dep")

        if [ -z "${COLLECTED[$basename]}" ] && [ -f "$realpath" ]; then
            COLLECTED[$basename]="$realpath"
            echo "    Found: $basename"
            # 递归
            collect_dylibs "$realpath"
        fi
    done
}

# ============================================================
# 1. FFmpeg + FFprobe
# ============================================================
echo "=== 1. 收集 FFmpeg 依赖 ==="
FFMPEG_REAL=$(readlink -f /opt/homebrew/bin/ffmpeg)
FFPROBE_REAL=$(readlink -f /opt/homebrew/bin/ffprobe)

cp "$FFMPEG_REAL" "$DEST/ffmpeg"
cp "$FFPROBE_REAL" "$DEST/ffprobe"
chmod +x "$DEST/ffmpeg" "$DEST/ffprobe"

echo "  收集 ffmpeg dylib..."
collect_dylibs "$FFMPEG_REAL"
echo "  收集 ffprobe dylib..."
collect_dylibs "$FFPROBE_REAL"

echo ""
echo "  共收集 ${#COLLECTED[@]} 个 dylib，开始复制..."

for basename in "${!COLLECTED[@]}"; do
    cp "${COLLECTED[$basename]}" "$DEST/$basename"
done

# 修复 ffmpeg/ffprobe 的 dylib 引用
for binary in "$DEST/ffmpeg" "$DEST/ffprobe"; do
    deps=$(otool -L "$binary" | tail -n +2 | awk '{print $1}' | grep -v "/usr/lib" | grep -v "/System" || true)
    for dep in $deps; do
        basename=$(basename "$dep")
        if [ -f "$DEST/$basename" ]; then
            install_name_tool -change "$dep" "@executable_path/../Resources/bin/$basename" "$binary" 2>/dev/null || true
        fi
    done
done

# 修复所有 dylib 的 id 和交叉引用
for lib in "$DEST"/lib*.dylib; do
    basename=$(basename "$lib")
    install_name_tool -id "@executable_path/../Resources/bin/$basename" "$lib" 2>/dev/null || true

    deps=$(otool -L "$lib" | tail -n +2 | awk '{print $1}' | grep -v "/usr/lib" | grep -v "/System" | grep -v "@executable_path" || true)
    for dep in $deps; do
        depbase=$(basename "$dep")
        if [ -f "$DEST/$depbase" ]; then
            install_name_tool -change "$dep" "@executable_path/../Resources/bin/$depbase" "$lib" 2>/dev/null || true
        fi
    done
done

echo "  FFmpeg 打包完成"

# ============================================================
# 2. Whisper-cli
# ============================================================
echo ""
echo "=== 2. 打包 Whisper-cli ==="
WHISPER_DIR="/opt/homebrew/Cellar/whisper-cpp/1.8.3/libexec"
cp "$WHISPER_DIR/bin/whisper-cli" "$DEST/whisper"
chmod +x "$DEST/whisper"

WHISPER_DYLIBS=(
    "libwhisper.1.dylib"
    "libggml.0.dylib"
    "libggml-cpu.0.dylib"
    "libggml-blas.0.dylib"
    "libggml-metal.0.dylib"
    "libggml-base.0.dylib"
)

for lib in "${WHISPER_DYLIBS[@]}"; do
    REAL=$(readlink -f "$WHISPER_DIR/lib/$lib")
    cp "$REAL" "$DEST/$lib"
done

# 复制 Metal shader
for f in "$WHISPER_DIR/lib/"*.metal "$WHISPER_DIR/lib/"*.metallib; do
    [ -f "$f" ] && cp "$f" "$DEST/" && echo "  Copied $(basename "$f")"
done

# 修复 whisper 的 rpath
for lib in "${WHISPER_DYLIBS[@]}"; do
    install_name_tool -change "@rpath/$lib" "@executable_path/../Resources/bin/$lib" "$DEST/whisper" 2>/dev/null || true
done

# 修复 whisper dylib 的 id 和交叉引用
for lib in "${WHISPER_DYLIBS[@]}"; do
    install_name_tool -id "@executable_path/../Resources/bin/$lib" "$DEST/$lib" 2>/dev/null || true
    for dep in "${WHISPER_DYLIBS[@]}"; do
        if [ "$lib" != "$dep" ]; then
            install_name_tool -change "@rpath/$dep" "@executable_path/../Resources/bin/$dep" "$DEST/$lib" 2>/dev/null || true
        fi
    done
done

echo "  Whisper 打包完成"

# ============================================================
# 3. 验证
# ============================================================
echo ""
echo "=== 3. 验证 ==="
echo "--- ffmpeg 非系统依赖 ---"
otool -L "$DEST/ffmpeg" | grep "@executable_path" | head -10
echo "..."
echo ""
echo "--- whisper 非系统依赖 ---"
otool -L "$DEST/whisper" | grep "@executable_path"
echo ""

# 检查是否有残留的绝对路径引用
echo "--- 检查残留绝对路径引用 ---"
BAD=$(otool -L "$DEST/ffmpeg" "$DEST/ffprobe" "$DEST/whisper" | grep "/opt/homebrew" || true)
if [ -n "$BAD" ]; then
    echo "WARNING: 仍有绝对路径引用:"
    echo "$BAD"
else
    echo "OK: 无残留绝对路径引用"
fi

echo ""
echo "--- 总大小 ---"
du -sh "$DEST"
echo ""
echo "--- 文件列表 ---"
ls -lhS "$DEST" | head -30
