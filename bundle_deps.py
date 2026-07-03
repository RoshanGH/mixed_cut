#!/usr/bin/env python3
"""校验 MixCut 内置二进制是否就位且为 universal (arm64 + x86_64)。

历史：本脚本曾负责「从 Homebrew 抓 ffmpeg/whisper + 递归收集/修复 dylib」。
现已改为**静态自包含 universal 二进制**方案（支持 Intel Mac），二进制由
`scripts/build_universal_binaries.sh` 生成（下载静态 ffmpeg + 源码编 whisper/demucs
+ lipo 合并）。本脚本退化为校验器：确认文件就位、且都是双架构。
"""
import os
import subprocess
import sys

DEST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "MixCut", "Resources", "bin")
BINARIES = ["ffmpeg", "ffprobe", "whisper", "demucs"]   # 需为 universal
DATA = ["ggml-htdemucs-4s.bin"]                         # 架构无关（人声分离模型）


def archs(path):
    try:
        return set(subprocess.check_output(["lipo", "-archs", path], text=True).split())
    except Exception:
        return set()


def main():
    print(f"校验 {DEST}")
    ok = True
    for name in BINARIES:
        p = os.path.join(DEST, name)
        if not os.path.isfile(p):
            print(f"  ✗ 缺少 {name}")
            ok = False
            continue
        a = archs(p)
        if {"arm64", "x86_64"} <= a:
            print(f"  ✓ {name}: {' '.join(sorted(a))}")
        else:
            print(f"  ✗ {name} 架构不完整: {' '.join(sorted(a)) or '未知'}（需 arm64 + x86_64）")
            ok = False
    for name in DATA:
        p = os.path.join(DEST, name)
        print(f"  {'✓' if os.path.isfile(p) else '✗'} {name}")
        ok = ok and os.path.isfile(p)

    if not ok:
        print("\n内置二进制缺失或非 universal，请运行：\n  ./scripts/build_universal_binaries.sh")
        sys.exit(1)
    print("\n✅ 所有内置二进制就位且为 universal (arm64 + x86_64)。")


if __name__ == "__main__":
    main()
