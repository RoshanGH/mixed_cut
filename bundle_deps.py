#!/usr/bin/env python3
"""将 FFmpeg 和 whisper.cpp 及其所有依赖打包到 app Resources/bin 中"""
import glob
import os
import shutil
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEST = os.path.join(SCRIPT_DIR, "MixCut", "Resources", "bin")
RPATH_PREFIX = "@loader_path"

def get_dylib_deps(binary_path):
    """获取非系统 dylib 依赖"""
    result = subprocess.run(["otool", "-L", binary_path], capture_output=True, text=True)
    deps = []
    for line in result.stdout.strip().split("\n")[1:]:  # skip first line (binary name)
        path = line.strip().split(" (")[0].strip()
        if (path and
            not path.startswith("/usr/lib") and
            not path.startswith("/System") and
            not path.startswith("@rpath") and
            not path.startswith("@executable_path") and
            not path.startswith("@loader_path") and
            os.path.exists(path)):
            deps.append(path)
    return deps

def resolve_path(path):
    """解析符号链接"""
    return os.path.realpath(path)

def collect_all_dylibs(binaries):
    """递归收集所有非系统 dylib"""
    collected = {}  # basename -> realpath
    queue = list(binaries)
    visited = set()

    while queue:
        binary = queue.pop(0)
        if binary in visited:
            continue
        visited.add(binary)

        for dep in get_dylib_deps(binary):
            real = resolve_path(dep)
            basename = os.path.basename(dep)
            if basename not in collected:
                collected[basename] = real
                queue.append(real)

    return collected

def fix_references(binary_path, all_libs):
    """修复二进制中的 dylib 引用"""
    result = subprocess.run(["otool", "-L", binary_path], capture_output=True, text=True)
    for line in result.stdout.strip().split("\n")[1:]:
        path = line.strip().split(" (")[0].strip()
        if path.startswith("@"):
            continue
        basename = os.path.basename(path)
        if basename in all_libs or os.path.exists(os.path.join(DEST, basename)):
            subprocess.run([
                "install_name_tool", "-change", path,
                f"{RPATH_PREFIX}/{basename}", binary_path
            ], capture_output=True)

def fix_id(lib_path):
    """修复 dylib 的 install name"""
    basename = os.path.basename(lib_path)
    subprocess.run([
        "install_name_tool", "-id",
        f"{RPATH_PREFIX}/{basename}", lib_path
    ], capture_output=True)

def main():
    # 清理并创建目标目录
    if os.path.exists(DEST):
        shutil.rmtree(DEST)
    os.makedirs(DEST)

    # ============================================================
    # 1. FFmpeg + FFprobe
    # ============================================================
    print("=== 1. 收集 FFmpeg 依赖 ===")
    ffmpeg_real = resolve_path("/opt/homebrew/bin/ffmpeg")
    ffprobe_real = resolve_path("/opt/homebrew/bin/ffprobe")

    shutil.copy2(ffmpeg_real, os.path.join(DEST, "ffmpeg"))
    shutil.copy2(ffprobe_real, os.path.join(DEST, "ffprobe"))
    os.chmod(os.path.join(DEST, "ffmpeg"), 0o755)
    os.chmod(os.path.join(DEST, "ffprobe"), 0o755)

    print("  递归收集 dylib...")
    ff_libs = collect_all_dylibs([ffmpeg_real, ffprobe_real])
    print(f"  共收集 {len(ff_libs)} 个 dylib")

    for basename, realpath in ff_libs.items():
        dest_path = os.path.join(DEST, basename)
        shutil.copy2(realpath, dest_path)
        os.chmod(dest_path, 0o755)
        print(f"    {basename}")

    # 修复 ffmpeg/ffprobe
    for name in ["ffmpeg", "ffprobe"]:
        fix_references(os.path.join(DEST, name), ff_libs)

    # 修复所有 dylib
    for basename in ff_libs:
        lib_path = os.path.join(DEST, basename)
        fix_id(lib_path)
        fix_references(lib_path, ff_libs)

    print("  FFmpeg 打包完成")

    # ============================================================
    # 2. Whisper-cli
    # ============================================================
    print("\n=== 2. 打包 Whisper-cli ===")
    # 自动检测 whisper-cpp 安装路径（支持任意版本号）
    whisper_cellar = "/opt/homebrew/Cellar/whisper-cpp"
    if os.path.isdir(whisper_cellar):
        versions = sorted(os.listdir(whisper_cellar))
        if versions:
            whisper_dir = os.path.join(whisper_cellar, versions[-1], "libexec")
        else:
            print("  ERROR: whisper-cpp Cellar 目录为空")
            sys.exit(1)
    else:
        print("  ERROR: whisper-cpp 未通过 Homebrew 安装")
        sys.exit(1)
    whisper_src = os.path.join(whisper_dir, "bin/whisper-cli")

    shutil.copy2(whisper_src, os.path.join(DEST, "whisper"))
    os.chmod(os.path.join(DEST, "whisper"), 0o755)

    whisper_dylibs = [
        "libwhisper.1.dylib",
        "libggml.0.dylib",
        "libggml-cpu.0.dylib",
        "libggml-blas.0.dylib",
        "libggml-metal.0.dylib",
        "libggml-base.0.dylib",
    ]

    for lib in whisper_dylibs:
        src = resolve_path(os.path.join(whisper_dir, "lib", lib))
        dest = os.path.join(DEST, lib)
        shutil.copy2(src, dest)
        os.chmod(dest, 0o755)
        print(f"    {lib}")

    # 复制 Metal shader
    for ext in ["*.metal", "*.metallib"]:
        for f in glob.glob(os.path.join(whisper_dir, "lib", ext)):
            shutil.copy2(f, os.path.join(DEST, os.path.basename(f)))
            print(f"    {os.path.basename(f)}")

    # 修复 whisper
    whisper_path = os.path.join(DEST, "whisper")
    for lib in whisper_dylibs:
        subprocess.run([
            "install_name_tool", "-change",
            f"@rpath/{lib}", f"@loader_path/{lib}",
            whisper_path
        ], capture_output=True)

    # 修复 whisper dylib
    for lib in whisper_dylibs:
        lib_path = os.path.join(DEST, lib)
        fix_id(lib_path)
        for dep in whisper_dylibs:
            if lib != dep:
                subprocess.run([
                    "install_name_tool", "-change",
                    f"@rpath/{dep}", f"{RPATH_PREFIX}/{dep}",
                    lib_path
                ], capture_output=True)

    print("  Whisper 打包完成")

    # ============================================================
    # 3. 代码签名（macOS 要求所有可执行文件有有效签名）
    # ============================================================
    print("\n=== 3. Ad-hoc 代码签名 ===")
    # 先签 dylib，再签可执行文件（签名顺序：依赖 → 主体）
    for name in sorted(os.listdir(DEST)):
        fpath = os.path.join(DEST, name)
        if not os.path.isfile(fpath):
            continue
        if name.endswith(".dylib"):
            subprocess.run(["codesign", "--force", "--sign", "-", fpath], capture_output=True)
            print(f"    签名: {name}")
    for name in ["ffmpeg", "ffprobe", "whisper"]:
        fpath = os.path.join(DEST, name)
        if os.path.exists(fpath):
            subprocess.run(["codesign", "--force", "--sign", "-", fpath], capture_output=True)
            print(f"    签名: {name}")

    # ============================================================
    # 4. 验证
    # ============================================================
    print("\n=== 4. 验证 ===")

    # 检查残留绝对路径
    has_bad = False
    for name in os.listdir(DEST):
        fpath = os.path.join(DEST, name)
        if not os.path.isfile(fpath):
            continue
        result = subprocess.run(["otool", "-L", fpath], capture_output=True, text=True)
        for line in result.stdout.split("\n"):
            if "/opt/homebrew" in line or "/usr/local" in line:
                print(f"  WARNING: {name} 仍引用 {line.strip()}")
                has_bad = True

    if not has_bad:
        print("  OK: 无残留绝对路径引用")

    # 总大小
    total = sum(os.path.getsize(os.path.join(DEST, f)) for f in os.listdir(DEST) if os.path.isfile(os.path.join(DEST, f)))
    print(f"\n  总大小: {total / 1024 / 1024:.1f} MB")
    print(f"  文件数: {len(os.listdir(DEST))}")

    # 列出最大的文件
    files = []
    for f in os.listdir(DEST):
        fp = os.path.join(DEST, f)
        if os.path.isfile(fp):
            files.append((f, os.path.getsize(fp)))
    files.sort(key=lambda x: -x[1])
    print("\n  最大文件:")
    for name, size in files[:15]:
        print(f"    {size/1024:.0f}K  {name}")

if __name__ == "__main__":
    main()
