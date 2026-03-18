#!/usr/bin/env python3
"""生成 MixCut.xcodeproj/project.pbxproj"""

import hashlib
import os

# 生成确定性的 24 位十六进制 ID
def make_id(name: str) -> str:
    return hashlib.md5(name.encode()).hexdigest()[:24].upper()

# ── 项目根目录（自动检测脚本所在目录）──
ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, "MixCut")

# ── 收集源文件 ──
swift_files = []
for dirpath, _, filenames in os.walk(SRC):
    for f in filenames:
        if f.endswith(".swift"):
            rel = os.path.relpath(os.path.join(dirpath, f), ROOT)
            swift_files.append(rel)
swift_files.sort()

# ── 收集资源文件 ──
resource_files = []
for dirpath, _, filenames in os.walk(os.path.join(SRC, "Resources", "Prompts")):
    for f in filenames:
        rel = os.path.relpath(os.path.join(dirpath, f), ROOT)
        resource_files.append(rel)
resource_files.sort()

# ── 收集目录结构 ──
# 我们需要为每个目录创建 PBXGroup
groups = {}  # relative_dir -> [children_names]

def ensure_group(rel_dir):
    if rel_dir not in groups:
        groups[rel_dir] = []
        parent = os.path.dirname(rel_dir)
        if parent and parent != rel_dir:
            ensure_group(parent)
            basename = os.path.basename(rel_dir)
            if basename not in groups[parent]:
                groups[parent].append(basename)

for f in swift_files + resource_files:
    d = os.path.dirname(f)
    ensure_group(d)
    basename = os.path.basename(f)
    if basename not in groups[d]:
        groups[d].append(basename)

# ── 固定 ID ──
PROJECT_ID       = make_id("project_MixCut")
ROOT_GROUP_ID    = make_id("root_group")
MAIN_TARGET_ID   = make_id("target_MixCut_app")
SOURCES_PHASE_ID = make_id("sources_build_phase")
RESOURCES_PHASE_ID = make_id("resources_build_phase")
FRAMEWORKS_PHASE_ID = make_id("frameworks_build_phase")
BUILD_CONFIG_LIST_PROJECT = make_id("config_list_project")
BUILD_CONFIG_LIST_TARGET  = make_id("config_list_target")
DEBUG_CONFIG_PROJECT  = make_id("debug_config_project")
RELEASE_CONFIG_PROJECT = make_id("release_config_project")
DEBUG_CONFIG_TARGET   = make_id("debug_config_target")
RELEASE_CONFIG_TARGET  = make_id("release_config_target")
PRODUCTS_GROUP_ID = make_id("products_group")
APP_PRODUCT_ID    = make_id("product_MixCut_app")
APP_FILEREF_ID    = make_id("fileref_product_MixCut_app")
# Entitlements
ENTITLEMENTS_FILEREF_ID = make_id("fileref_entitlements")

# Assets.xcassets
XCASSETS_FILEREF_ID = make_id("fileref_xcassets")
XCASSETS_BUILD_ID = make_id("build_xcassets")

# Resources/bin folder reference（FFmpeg + whisper 二进制）
BIN_FOLDER_FILEREF_ID = make_id("fileref_resources_bin")
BIN_FOLDER_BUILD_ID = make_id("build_resources_bin")

# ── 生成 PBXFileReference 和 PBXBuildFile ──
file_refs = []   # (id, path, name, lastKnownFileType)
build_files = [] # (build_id, fileref_id, file_name)
resource_build_files = [] # (build_id, fileref_id, file_name)

for f in swift_files:
    fref_id = make_id(f"fileref_{f}")
    build_id = make_id(f"build_{f}")
    name = os.path.basename(f)
    file_refs.append((fref_id, f, name, "sourcecode.swift"))
    build_files.append((build_id, fref_id, name))

for f in resource_files:
    fref_id = make_id(f"fileref_{f}")
    build_id = make_id(f"build_resource_{f}")
    name = os.path.basename(f)
    file_refs.append((fref_id, f, name, "net.daringfireball.markdown"))
    resource_build_files.append((build_id, fref_id, name))

# ── 生成 PBXGroup 树 ──
def group_id(rel_dir):
    if rel_dir == "MixCut":
        return make_id("group_MixCut_root")
    return make_id(f"group_{rel_dir}")

def build_group_entry(rel_dir):
    gid = group_id(rel_dir)
    name = os.path.basename(rel_dir) if rel_dir != "MixCut" else "MixCut"
    children_ids = []

    sorted_children = sorted(groups.get(rel_dir, []))
    for child in sorted_children:
        child_path = os.path.join(rel_dir, child)
        if child_path in groups:
            # 子目录
            children_ids.append(group_id(child_path))
        else:
            # 文件
            fref_id = make_id(f"fileref_{child_path}")
            children_ids.append(fref_id)

    # 如果是 Resources 组，添加 bin folder reference
    if rel_dir == "MixCut/Resources":
        children_ids.append(BIN_FOLDER_FILEREF_ID)
        sorted_children.append("bin")

    children_str = "\n".join(f"\t\t\t\t{cid} /* {child} */,"
                             for cid, child in zip(children_ids, sorted_children))

    return f"""\t\t{gid} /* {name} */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{children_str}
\t\t\t);
\t\t\tpath = "{name}";
\t\t\tsourceTree = "<group>";
\t\t}};"""

group_entries = []
for d in sorted(groups.keys()):
    group_entries.append(build_group_entry(d))

# ── 生成 pbxproj ──
pbxproj = f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 60;
\tobjects = {{

/* Begin PBXBuildFile section */
"""

for build_id, fref_id, name in build_files:
    pbxproj += f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fref_id} /* {name} */; }};\n"

for build_id, fref_id, name in resource_build_files:
    pbxproj += f"\t\t{build_id} /* {name} in Resources */ = {{isa = PBXBuildFile; fileRef = {fref_id} /* {name} */; }};\n"

# Assets.xcassets build file
pbxproj += f"\t\t{XCASSETS_BUILD_ID} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {XCASSETS_FILEREF_ID} /* Assets.xcassets */; }};\n"

# bin folder build file
pbxproj += f"\t\t{BIN_FOLDER_BUILD_ID} /* bin in Resources */ = {{isa = PBXBuildFile; fileRef = {BIN_FOLDER_FILEREF_ID} /* bin */; }};\n"

pbxproj += """/* End PBXBuildFile section */

/* Begin PBXFileReference section */
"""

for fref_id, path, name, ftype in file_refs:
    pbxproj += f'\t\t{fref_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype}; path = "{name}"; sourceTree = "<group>"; }};\n'

# App product
pbxproj += f'\t\t{APP_FILEREF_ID} /* MixCut.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = MixCut.app; sourceTree = BUILT_PRODUCTS_DIR; }};\n'

# Entitlements
pbxproj += f'\t\t{ENTITLEMENTS_FILEREF_ID} /* MixCut.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = MixCut.entitlements; sourceTree = "<group>"; }};\n'

# Assets.xcassets
pbxproj += f'\t\t{XCASSETS_FILEREF_ID} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};\n'

# Resources/bin folder reference
pbxproj += f'\t\t{BIN_FOLDER_FILEREF_ID} /* bin */ = {{isa = PBXFileReference; lastKnownFileType = folder; path = bin; sourceTree = "<group>"; }};\n'

pbxproj += """/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
"""
pbxproj += f"""\t\t{FRAMEWORKS_PHASE_ID} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
"""

pbxproj += """/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
"""

# Root group
mixcut_group_id = group_id("MixCut")
pbxproj += f"""\t\t{ROOT_GROUP_ID} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{mixcut_group_id} /* MixCut */,
\t\t\t\t{ENTITLEMENTS_FILEREF_ID} /* MixCut.entitlements */,
\t\t\t\t{PRODUCTS_GROUP_ID} /* Products */,
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};
"""

# Products group
pbxproj += f"""\t\t{PRODUCTS_GROUP_ID} /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{APP_FILEREF_ID} /* MixCut.app */,
\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t}};
"""

# MixCut group - 需要添加 Assets.xcassets
mixcut_children = groups.get("MixCut", [])
# 把 Assets.xcassets 加入 MixCut group
original_entry = build_group_entry("MixCut")
# 在 MixCut group 的 children 中插入 Assets.xcassets
for entry in group_entries:
    if f"{mixcut_group_id}" in entry:
        # 在 children 最后添加 Assets.xcassets
        entry = entry.replace(
            "\t\t\t);\n\t\t\tpath",
            f"\t\t\t\t{XCASSETS_FILEREF_ID} /* Assets.xcassets */,\n\t\t\t);\n\t\t\tpath"
        )
        pbxproj += entry + "\n"
    else:
        pbxproj += entry + "\n"

pbxproj += """/* End PBXGroup section */

/* Begin PBXNativeTarget section */
"""

sources_list = "\n".join(f"\t\t\t\t{bid} /* {name} in Sources */," for bid, _, name in build_files)
resources_list = "\n".join(f"\t\t\t\t{bid} /* {name} in Resources */," for bid, _, name in resource_build_files)

pbxproj += f"""\t\t{MAIN_TARGET_ID} /* MixCut */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {BUILD_CONFIG_LIST_TARGET} /* Build configuration list for PBXNativeTarget "MixCut" */;
\t\t\tbuildPhases = (
\t\t\t\t{SOURCES_PHASE_ID} /* Sources */,
\t\t\t\t{FRAMEWORKS_PHASE_ID} /* Frameworks */,
\t\t\t\t{RESOURCES_PHASE_ID} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = MixCut;
\t\t\tproductName = MixCut;
\t\t\tproductReference = {APP_FILEREF_ID} /* MixCut.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
"""

pbxproj += """/* End PBXNativeTarget section */

/* Begin PBXProject section */
"""

pbxproj += f"""\t\t{PROJECT_ID} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 1600;
\t\t\t\tLastUpgradeCheck = 1600;
\t\t\t}};
\t\t\tbuildConfigurationList = {BUILD_CONFIG_LIST_PROJECT} /* Build configuration list for PBXProject "MixCut" */;
\t\t\tdevelopmentRegion = "zh-Hans";
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\t"zh-Hans",
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {ROOT_GROUP_ID};
\t\t\tproductRefGroup = {PRODUCTS_GROUP_ID} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{MAIN_TARGET_ID} /* MixCut */,
\t\t\t);
\t\t}};
"""

pbxproj += """/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
"""

pbxproj += f"""\t\t{RESOURCES_PHASE_ID} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{resources_list}
\t\t\t\t{XCASSETS_BUILD_ID} /* Assets.xcassets in Resources */,
\t\t\t\t{BIN_FOLDER_BUILD_ID} /* bin in Resources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
"""

pbxproj += """/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
"""

pbxproj += f"""\t\t{SOURCES_PHASE_ID} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{sources_list}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
"""

pbxproj += """/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
"""

# Debug config - Project level
pbxproj += f"""\t\t{DEBUG_CONFIG_PROJECT} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tASSTTAGS_COMPILER_WARN_DUPLICATE_ASSET_TAGS = YES;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
\t\t\t\tCLANG_WARN_BOOL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_COMMA = YES;
\t\t\t\tCLANG_WARN_CONSTANT_CONVERSION = YES;
\t\t\t\tCLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
\t\t\t\tCLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
\t\t\t\tCLANG_WARN_EMPTY_BODY = YES;
\t\t\t\tCLANG_WARN_ENUM_CONVERSION = YES;
\t\t\t\tCLANG_WARN_INFINITE_RECURSION = YES;
\t\t\t\tCLANG_WARN_INT_CONVERSION = YES;
\t\t\t\tCLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;
\t\t\t\tCLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
\t\t\t\tCLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
\t\t\t\tCLANG_WARN_STRICT_PROTOTYPES = YES;
\t\t\t\tCLANG_WARN_SUSPICIOUS_MOVE = YES;
\t\t\t\tCLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
\t\t\t\tCLANG_WARN_UNREACHABLE_CODE = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tENABLE_TESTABILITY = YES;
\t\t\t\tGCC_DYNAMIC_NO_PIC = NO;
\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;
\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (
\t\t\t\t\t"DEBUG=1",
\t\t\t\t\t"$(inherited)",
\t\t\t\t);
\t\t\t\tGCC_WARN_64_TO_32_BIT_CONVERSION = YES;
\t\t\t\tGCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
\t\t\t\tGCC_WARN_UNDECLARED_SELECTOR = YES;
\t\t\t\tGCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
\t\t\t\tGCC_WARN_UNUSED_FUNCTION = YES;
\t\t\t\tGCC_WARN_UNUSED_VARIABLE = YES;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;
\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
\t\t\t\tMTL_FAST_MATH = YES;
\t\t\t\tONLY_ACTIVE_ARCH = YES;
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) DEBUG";
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
"""

# Release config - Project level
pbxproj += f"""\t\t{RELEASE_CONFIG_PROJECT} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tASSTTAGS_COMPILER_WARN_DUPLICATE_ASSET_TAGS = YES;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
\t\t\t\tCLANG_WARN_BOOL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_COMMA = YES;
\t\t\t\tCLANG_WARN_CONSTANT_CONVERSION = YES;
\t\t\t\tCLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
\t\t\t\tCLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
\t\t\t\tCLANG_WARN_EMPTY_BODY = YES;
\t\t\t\tCLANG_WARN_ENUM_CONVERSION = YES;
\t\t\t\tCLANG_WARN_INFINITE_RECURSION = YES;
\t\t\t\tCLANG_WARN_INT_CONVERSION = YES;
\t\t\t\tCLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;
\t\t\t\tCLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
\t\t\t\tCLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
\t\t\t\tCLANG_WARN_STRICT_PROTOTYPES = YES;
\t\t\t\tCLANG_WARN_SUSPICIOUS_MOVE = YES;
\t\t\t\tCLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
\t\t\t\tCLANG_WARN_UNREACHABLE_CODE = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\t\tENABLE_NS_ASSERTIONS = NO;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
\t\t\t\tGCC_WARN_64_TO_32_BIT_CONVERSION = YES;
\t\t\t\tGCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
\t\t\t\tGCC_WARN_UNDECLARED_SELECTOR = YES;
\t\t\t\tGCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
\t\t\t\tGCC_WARN_UNUSED_FUNCTION = YES;
\t\t\t\tGCC_WARN_UNUSED_VARIABLE = YES;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;
\t\t\t\tMTL_FAST_MATH = YES;
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;
\t\t\t}};
\t\t\tname = Release;
\t\t}};
"""

# Debug config - Target level
pbxproj += f"""\t\t{DEBUG_CONFIG_TARGET} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
\t\t\t\tCODE_SIGN_ENTITLEMENTS = MixCut.entitlements;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEVELOPMENT_TEAM = "";
\t\t\t\tENABLE_HARDENED_RUNTIME = YES;
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tINFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.video";
\t\t\t\tINFOPLIST_KEY_NSHumanReadableCopyright = "";
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/../Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 0.1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.mixcut.app;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
"""

# Release config - Target level
pbxproj += f"""\t\t{RELEASE_CONFIG_TARGET} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
\t\t\t\tCODE_SIGN_ENTITLEMENTS = MixCut.entitlements;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEVELOPMENT_TEAM = "";
\t\t\t\tENABLE_HARDENED_RUNTIME = YES;
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tINFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.video";
\t\t\t\tINFOPLIST_KEY_NSHumanReadableCopyright = "";
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/../Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 0.1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.mixcut.app;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t}};
\t\t\tname = Release;
\t\t}};
"""

pbxproj += """/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
"""

pbxproj += f"""\t\t{BUILD_CONFIG_LIST_PROJECT} /* Build configuration list for PBXProject "MixCut" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{DEBUG_CONFIG_PROJECT} /* Debug */,
\t\t\t\t{RELEASE_CONFIG_PROJECT} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Debug;
\t\t}};
\t\t{BUILD_CONFIG_LIST_TARGET} /* Build configuration list for PBXNativeTarget "MixCut" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{DEBUG_CONFIG_TARGET} /* Debug */,
\t\t\t\t{RELEASE_CONFIG_TARGET} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Debug;
\t\t}};
"""

pbxproj += """/* End XCConfigurationList section */
"""

pbxproj += f"""\t}};
\trootObject = {PROJECT_ID} /* Project object */;
}}
"""

# ── 写入文件 ──
proj_dir = os.path.join(ROOT, "MixCut.xcodeproj")
os.makedirs(proj_dir, exist_ok=True)
with open(os.path.join(proj_dir, "project.pbxproj"), "w") as f:
    f.write(pbxproj)

print(f"Generated {proj_dir}/project.pbxproj")
print(f"  Swift files: {len(swift_files)}")
print(f"  Resource files: {len(resource_files)}")
print(f"  Groups: {len(groups)}")
