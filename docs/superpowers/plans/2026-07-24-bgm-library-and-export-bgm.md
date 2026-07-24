# BGM 库 + 导出 BGM 替换 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增全局 BGM 库（上传 MP3），导出成片时可选一条 BGM：去除各分镜原 BGM、只留纯口播，再把所选 BGM 铺满整片（长截断、短循环、结尾 1 秒淡出）。

**Architecture:** 复用现有 demucs 人声分离缓存（`VocalSeparationService`，键 = videoHash）取纯口播；`DubSegmentGraphBuilder` 增加「原声段改用整轨 vocals.wav 切片」的音源开关；`DubExportService` 在 concat 后新增整片 BGM 混音阶段。BGM 库为纯文件目录（`AppSupport/MixCut/BGM/`），不动 SwiftData schema。

**Tech Stack:** SwiftUI + SwiftData（不改 schema）、ffmpeg（内置）、demucs（内置）、Swift Testing（MixCutCore 纯逻辑）。

**Spec:** `docs/superpowers/specs/2026-07-24-bgm-library-design.md`

## Global Constraints

- **绝不自动 git commit/push/tag**（项目规则：等用户验证后由用户决定）。计划里的"提交"步骤全部省略。
- **兜底只兜过程不兜结果**：选了 BGM 就必须是「纯口播 + 该 BGM」；人声分离失败 → 涉及该视频的成片直接失败并透出「哪个视频、哪一步、什么原因」。
- 默认选项 UI 文案定稿为 **「保留原 BGM」**（不用「保留原声」）。
- BGM 音量滑杆默认 **60%**；结尾淡出 **1 秒**。
- 所有注释、UI 文案用中文；新文件 < 800 行；遵循 DesignTokens。
- 新增 App target 文件必须登记进 `MixCut.xcodeproj/project.pbxproj`（用 ruby `xcodeproj` gem，见 Task 4 的登记脚本）。
- 编译一律 `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build`；纯逻辑用 `swift test`。
- 编译成功后自动 `pkill -x MixCut; sleep 1; open <DerivedData>/Build/Products/Debug/MixCut.app` 重启应用；UI 改动必须截图自查。
- DerivedData: `/Users/menggang/Library/Developer/Xcode/DerivedData/MixCut-byytuggmhodpumcmwnwrtzwkmavr/`

---

### Task 1: MixCutCore — GlobalBGMMixGraphBuilder（整片 BGM 铺底滤镜图）

**Files:**
- Create: `Sources/MixCutCore/GlobalBGMMixGraph.swift`
- Test: `Tests/MixCutCoreTests/GlobalBGMMixGraphTests.swift`

**Interfaces:**
- Consumes: 无
- Produces: `GlobalBGMMixGraphBuilder.filterComplex(pieceDuration: Double, bgmVolume: Double) -> String`；`GlobalBGMMixGraphBuilder.fadeOutDuration: Double`。输入约定：input 0 = 纯口播成片，input 1 = BGM（调用方用 `-stream_loop -1` 循环），输出音频标签 `[aout]`。

- [ ] **Step 1: 写失败测试**

```swift
// Tests/MixCutCoreTests/GlobalBGMMixGraphTests.swift
import Testing
@testable import MixCutCore

@Suite("整片 BGM 铺底滤镜图")
struct GlobalBGMMixGraphTests {

    @Test("BGM 截断到成片时长并按音量淡出")
    func basicGraph() {
        let g = GlobalBGMMixGraphBuilder.filterComplex(pieceDuration: 30, bgmVolume: 0.6)
        #expect(g.contains("[1:a]atrim=0:30.000"))
        #expect(g.contains("volume=0.60"))
        #expect(g.contains("afade=t=out:st=29.000:d=1.000"))
        #expect(g.contains("[0:a][bgm]amix=inputs=2:duration=first:normalize=0[aout]"))
    }

    @Test("音量夹取到 0…1")
    func volumeClamped() {
        #expect(GlobalBGMMixGraphBuilder.filterComplex(pieceDuration: 10, bgmVolume: 1.5).contains("volume=1.00"))
        #expect(GlobalBGMMixGraphBuilder.filterComplex(pieceDuration: 10, bgmVolume: -1).contains("volume=0.00"))
    }

    @Test("成片短于淡出时长时淡出从 0 开始且不超片长")
    func shortPiece() {
        let g = GlobalBGMMixGraphBuilder.filterComplex(pieceDuration: 0.5, bgmVolume: 0.6)
        #expect(g.contains("afade=t=out:st=0.000:d=0.500"))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd /Users/menggang/www/Mixed_cut && swift test --filter GlobalBGMMixGraphTests`
Expected: 编译失败 "cannot find 'GlobalBGMMixGraphBuilder'"

- [ ] **Step 3: 写实现**

```swift
// Sources/MixCutCore/GlobalBGMMixGraph.swift
import Foundation

/// 成片级「全局 BGM 铺底」滤镜图（纯字符串，导出服务直接拼进 ffmpeg 命令）。
///
/// 输入约定：input 0 = 已拼好的纯口播成片；input 1 = 用户选的 BGM 音频，
/// 由调用方加 `-stream_loop -1` 无限循环 —— BGM 短于成片时循环补齐，
/// 长于成片时由 atrim 截断。结尾 1 秒淡出，避免 BGM 硬切。
/// 只动 BGM 那一路（口播不淡出、不改音量），amix 不归一化以保持口播原响度。
public enum GlobalBGMMixGraphBuilder {
    /// 结尾淡出时长（秒）
    public static let fadeOutDuration: Double = 1.0

    /// - Parameters:
    ///   - pieceDuration: 成片时长（秒）
    ///   - bgmVolume: BGM 音量（0…1，越界自动夹取）
    public static func filterComplex(pieceDuration: Double, bgmVolume: Double) -> String {
        let d = max(0.1, pieceDuration)
        let v = min(1.0, max(0.0, bgmVolume))
        let fadeLen = min(fadeOutDuration, d)
        let fadeStart = max(0, d - fadeLen)
        return "[1:a]atrim=0:\(f3(d)),asetpts=PTS-STARTPTS,aresample=44100," +
               "volume=\(f2(v)),afade=t=out:st=\(f3(fadeStart)):d=\(f3(fadeLen))[bgm];" +
               "[0:a][bgm]amix=inputs=2:duration=first:normalize=0[aout]"
    }

    private static func f3(_ x: Double) -> String { String(format: "%.3f", x) }
    private static func f2(_ x: Double) -> String { String(format: "%.2f", x) }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter GlobalBGMMixGraphTests`
Expected: 3 tests PASS

---

### Task 2: MixCutCore — DubSegmentGraphBuilder 支持「原声段改用纯人声音源」

**Files:**
- Modify: `Sources/MixCutCore/DubSegmentGraph.swift`（第 39-50 行签名、第 104-111 行音频段）
- Test: `Tests/MixCutCoreTests/DubSegmentGraphTests.swift`（追加）

**Interfaces:**
- Consumes: 现有 `DubSegmentGraphBuilder.build(...)`
- Produces: 新增 `public struct VocalsSource { inputIndex: Int; start: Double; end: Double }`；`build(...)` 尾部新增参数 `vocalsSource: VocalsSource? = nil`。语义：`keepOriginalAudio == true` 且 `vocalsSource != nil` 时，音频取 `[N:a]` 整轨纯人声按 **原视频时间轴** `[start, end)` 秒切片，替代 `[0:a]`。有默认值，现有调用点零改动。

- [ ] **Step 1: 写失败测试（追加到 DubSegmentGraphTests.swift 末尾）**

```swift
@Suite("全局 BGM 模式：原声段用纯人声音源")
struct VocalsSourceTests {

    @Test("传 vocalsSource 时原声段音频取自 vocals 输入并按秒切片")
    func vocalsSliceReplacesOriginalAudio() {
        let g = DubSegmentGraphBuilder.build(
            mode: .none, startFrame: 0, endFrame: 90, fps: 30,
            outputWidth: 720, outputHeight: 1280,
            maskPixel: PixelRect(x: 0, y: 0, width: 100, height: 100),
            captions: [], keepOriginalAudio: true,
            dubAudioInputIndex: 1, freezePadFrames: 0, trailingSilence: 0,
            vocalsSource: VocalsSource(inputIndex: 1, start: 12.5, end: 15.5))
        #expect(g.filterComplex.contains("[1:a]atrim=start=12.50000:end=15.50000"))
        #expect(!g.filterComplex.contains("[0:a]"))
    }

    @Test("不传 vocalsSource 时行为不变（原声取 [0:a]）")
    func defaultKeepsOriginalBehavior() {
        let g = DubSegmentGraphBuilder.build(
            mode: .none, startFrame: 0, endFrame: 90, fps: 30,
            outputWidth: 720, outputHeight: 1280,
            maskPixel: PixelRect(x: 0, y: 0, width: 100, height: 100),
            captions: [], keepOriginalAudio: true,
            dubAudioInputIndex: 1, freezePadFrames: 0, trailingSilence: 0)
        #expect(g.filterComplex.contains("[0:a]atrim="))
    }

    @Test("配音段不受 vocalsSource 影响（音频仍取配音输入）")
    func dubSegmentIgnoresVocalsSource() {
        let g = DubSegmentGraphBuilder.build(
            mode: .none, startFrame: 0, endFrame: 90, fps: 30,
            outputWidth: 720, outputHeight: 1280,
            maskPixel: PixelRect(x: 0, y: 0, width: 100, height: 100),
            captions: [], keepOriginalAudio: false,
            dubAudioInputIndex: 1, freezePadFrames: 0, trailingSilence: 0,
            vocalsSource: VocalsSource(inputIndex: 2, start: 0, end: 3))
        #expect(g.filterComplex.contains("[1:a]aresample=44100"))
        #expect(!g.filterComplex.contains("[2:a]"))
    }
}
```

（`PixelRect` 构造签名以文件内现有用法为准，跑测试前先看该测试文件里既有的构造写法并保持一致。）

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter VocalsSourceTests`
Expected: 编译失败 "cannot find 'VocalsSource'"

- [ ] **Step 3: 实现**

在 `DubSegmentGraph.swift` 的 `CaptionOverlay` 之后加：

```swift
/// 全局 BGM 模式下，原声段的「纯人声」音源：
/// 整轨 vocals.wav 的输入序号 + 原视频时间轴上的切片窗（秒）。
/// ⚠️ 时间窗必须用**原视频**时间轴（segment.startTime/endTime），不能用替换画面片的帧换算——
/// 替换画面片的音轨本来就取自原视频同窗口，vocals.wav 也是对原视频整轨分离的。
public struct VocalsSource: Sendable, Equatable {
    public let inputIndex: Int
    public let start: Double
    public let end: Double
    public init(inputIndex: Int, start: Double, end: Double) {
        self.inputIndex = inputIndex; self.start = start; self.end = end
    }
}
```

`build` 签名尾部加 `vocalsSource: VocalsSource? = nil`（放在 `bgmInputIndex` 之后）。第 5 步音频分支改为：

```swift
        // 5) 音频 → [aout]
        if keepOriginalAudio {
            if let vs = vocalsSource {
                // 全局 BGM 模式：原声段只留纯口播（整轨 vocals.wav 按原视频时间轴切片）
                parts.append(
                    "[\(vs.inputIndex):a]atrim=start=\(String(format: "%.5f", vs.start)):end=\(String(format: "%.5f", vs.end))," +
                    "asetpts=PTS-STARTPTS,aresample=44100[aout]"
                )
            } else {
                let aStart = Double(startFrame) / fps
                let aEnd = Double(endFrame) / fps
                parts.append(
                    "[0:a]atrim=start=\(String(format: "%.5f", aStart)):end=\(String(format: "%.5f", aEnd))," +
                    "asetpts=PTS-STARTPTS,aresample=44100[aout]"
                )
            }
        } else {
            // …（原有配音分支不动）
        }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter DubSegmentGraph && swift test --filter VocalsSourceTests`
Expected: 全部 PASS（既有 DubSegmentGraphTests 也必须全绿——回归保护）

---

### Task 3: MixCutCore — UniqueFileNamer（上传重名自动加后缀）

**Files:**
- Create: `Sources/MixCutCore/UniqueFileNamer.swift`
- Test: `Tests/MixCutCoreTests/UniqueFileNamerTests.swift`

**Interfaces:**
- Produces: `UniqueFileNamer.uniqueName(for fileName: String, existing: Set<String>) -> String`

- [ ] **Step 1: 写失败测试**

```swift
import Testing
@testable import MixCutCore

@Suite("BGM 上传重名去重")
struct UniqueFileNamerTests {
    @Test("无冲突原样返回")
    func noConflict() {
        #expect(UniqueFileNamer.uniqueName(for: "歌.mp3", existing: []) == "歌.mp3")
    }
    @Test("冲突时从 2 递增")
    func conflictAppendsCounter() {
        #expect(UniqueFileNamer.uniqueName(for: "歌.mp3", existing: ["歌.mp3"]) == "歌 2.mp3")
        #expect(UniqueFileNamer.uniqueName(for: "歌.mp3", existing: ["歌.mp3", "歌 2.mp3"]) == "歌 3.mp3")
    }
    @Test("无扩展名文件也正确加后缀")
    func noExtension() {
        #expect(UniqueFileNamer.uniqueName(for: "bgm", existing: ["bgm"]) == "bgm 2")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter UniqueFileNamerTests` → 编译失败 "cannot find 'UniqueFileNamer'"

- [ ] **Step 3: 实现**

```swift
// Sources/MixCutCore/UniqueFileNamer.swift
import Foundation

/// 在已有文件名集合中为新文件找一个不冲突的名字："歌.mp3" → "歌 2.mp3" → "歌 3.mp3"…
public enum UniqueFileNamer {
    public static func uniqueName(for fileName: String, existing: Set<String>) -> String {
        guard existing.contains(fileName) else { return fileName }
        let ns = fileName as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            if !existing.contains(candidate) { return candidate }
            counter += 1
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter UniqueFileNamerTests` → 3 tests PASS

---

### Task 4: App — FileHelper.bgmLibraryDirectory + BGMLibraryStore

**Files:**
- Modify: `MixCut/Utilities/FileHelper.swift`（「人声分离」小节之后加 BGM 小节）
- Create: `MixCut/Services/BGM/BGMLibraryStore.swift`

**Interfaces:**
- Consumes: `FileHelper.appSupportDirectory`、`UniqueFileNamer`（Task 3）
- Produces:
  - `FileHelper.bgmLibraryDirectory: URL`
  - `struct BGMTrack: Identifiable { path: String; name: String; duration: Double; id: String }`
  - `@MainActor @Observable final class BGMLibraryStore`：`tracks: [BGMTrack]`、`func reload() async`、`func importFiles(urls: [URL]) async -> [(name: String, reason: String)]`、`func delete(_ track: BGMTrack) async -> String?`（nil = 成功，非 nil = 人话失败原因）

- [ ] **Step 1: FileHelper 加目录**

```swift
    // MARK: - BGM 库（全局共享）

    /// BGM 库目录：AppSupport/MixCut/BGM/。
    /// 上传的音频文件直接落此目录，"库"即目录扫描，无数据库记录（避免 schema 变更）。
    static var bgmLibraryDirectory: URL {
        let url = appSupportDirectory.appendingPathComponent("BGM", isDirectory: true)
        ensureDirectory(at: url)
        return url
    }
```

- [ ] **Step 2: 写 BGMLibraryStore**

```swift
// MixCut/Services/BGM/BGMLibraryStore.swift
import Foundation
import AVFoundation
import Observation

/// 一条 BGM：文件即数据，name = 文件名，无数据库记录。
struct BGMTrack: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let duration: Double   // 秒；0 = 时长未知（理论上不会发生，导入时已校验）
    var id: String { path }
}

/// 全局 BGM 库：目录扫描 / 上传（校验 + 重名去重）/ 删除。
/// BGM 库页面和导出页共用。全项目共享（与视频素材的全局共享逻辑一致）。
@MainActor
@Observable
final class BGMLibraryStore {
    private(set) var tracks: [BGMTrack] = []

    /// 重新扫描 BGM 目录（文件名自然排序）。
    func reload() async {
        let dir = FileHelper.bgmLibraryDirectory
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var list: [BGMTrack] = []
        for url in files.sorted(by: {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }) {
            let duration = await Self.audioDuration(url: url) ?? 0
            list.append(BGMTrack(path: url.path, name: url.lastPathComponent, duration: duration))
        }
        tracks = list
    }

    /// 导入音频文件：逐个校验是有效音频（AVFoundation 读得出音轨与时长），
    /// 无效/复制失败的**不静默吞掉**，逐条返回「文件名 + 人话原因」。
    func importFiles(urls: [URL]) async -> [(name: String, reason: String)] {
        var failures: [(name: String, reason: String)] = []
        var existing = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: FileHelper.bgmLibraryDirectory.path)) ?? []
        )
        for url in urls {
            guard await Self.audioDuration(url: url) != nil else {
                failures.append((url.lastPathComponent, "不是有效的音频文件，或文件已损坏"))
                continue
            }
            let name = UniqueFileNamer.uniqueName(for: url.lastPathComponent, existing: existing)
            let dest = FileHelper.bgmLibraryDirectory.appendingPathComponent(name)
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                existing.insert(name)
            } catch {
                MixLog.error("[BGM] 导入失败 \(url.lastPathComponent): \(error.localizedDescription)")
                failures.append((url.lastPathComponent, "复制文件失败：\(error.localizedDescription)"))
            }
        }
        await reload()
        return failures
    }

    /// 删除一条 BGM。返回 nil = 成功；非 nil = 人话失败原因。
    func delete(_ track: BGMTrack) async -> String? {
        do {
            try FileManager.default.removeItem(atPath: track.path)
        } catch {
            MixLog.error("[BGM] 删除失败 \(track.name): \(error.localizedDescription)")
            return "删除失败：\(error.localizedDescription)"
        }
        await reload()
        return nil
    }

    /// 读音频时长；读不出（非音频 / 损坏 / 无音轨）返回 nil。
    private static func audioDuration(url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let audioTracks = try? await asset.loadTracks(withMediaType: .audio),
              !audioTracks.isEmpty,
              let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}
```

- [ ] **Step 3: 登记新文件进 xcodeproj 并编译**

```bash
cd /Users/menggang/www/Mixed_cut && ruby -e '
require "xcodeproj"
proj = Xcodeproj::Project.open("MixCut.xcodeproj")
target = proj.targets.find { |t| t.name == "MixCut" }
[
  "MixCut/Services/BGM/BGMLibraryStore.swift",
  "Sources/MixCutCore/GlobalBGMMixGraph.swift",
  "Sources/MixCutCore/UniqueFileNamer.swift",
].each do |f|
  next if proj.files.any? { |r| (r.real_path.to_s rescue "").end_with?(f) }
  ref = proj.main_group.new_file(f)
  target.source_build_phase.add_file_reference(ref, true)
  puts "registered: #{f}"
end
proj.save
'
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -5
```

Expected: 三个文件 registered + `** BUILD SUCCEEDED **`

---

### Task 5: App — NavigationItem + BGMLibraryView（管理界面）

**Files:**
- Modify: `MixCut/App/ContentView.swift`（NavigationItem 枚举 + detailView switch）
- Create: `MixCut/Views/BGMLibrary/BGMLibraryView.swift`

**Interfaces:**
- Consumes: `BGMLibraryStore`（Task 4）、`ToastCenter.shared`、DesignTokens
- Produces: `NavigationItem.bgmLibrary`（rawValue "BGM 库"，icon "music.note.list"）；`struct BGMLibraryView: View`（无参构造，全局数据不依赖 project）

- [ ] **Step 1: NavigationItem 加 case**

`ContentView.swift` 枚举中 `schemes` 与 `export` 之间插入：

```swift
    case bgmLibrary = "BGM 库"
```

icon switch 中加：

```swift
        case .bgmLibrary: return "music.note.list"
```

detailView switch 中加（侧边栏 `ForEach(NavigationItem.allCases)` 自动带出新项，无需改 SidebarView）：

```swift
        case .bgmLibrary:
            BGMLibraryView()
```

- [ ] **Step 2: 写 BGMLibraryView**

```swift
// MixCut/Views/BGMLibrary/BGMLibraryView.swift
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// 全局 BGM 库：上传 / 试听 / 删除。所有项目共享；导出成片时从这里选一条铺底。
struct BGMLibraryView: View {
    @State private var store = BGMLibraryStore()
    @State private var isImporterPresented = false
    /// 正在试听的 BGM 路径（nil = 没在播）
    @State private var playingPath: String?
    @State private var player: AVAudioPlayer?
    /// 待确认删除的 BGM
    @State private var trackPendingDelete: BGMTrack?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.generous) {
                    header
                    if store.tracks.isEmpty {
                        emptyState
                    } else {
                        trackList
                    }
                }
                .padding(DesignTokens.Padding.page)
                .frame(maxWidth: 860)
            }
            .frame(maxWidth: .infinity)
        }
        .task { await store.reload() }
        .onDisappear { stopPreview() }
        .fileImporter(isPresented: $isImporterPresented,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { result in
            handleImport(result)
        }
        .confirmationDialog("删除这条 BGM？",
                            isPresented: Binding(get: { trackPendingDelete != nil },
                                                 set: { if !$0 { trackPendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("删除「\(trackPendingDelete?.name ?? "")」", role: .destructive) {
                if let track = trackPendingDelete { deleteTrack(track) }
            }
            Button("取消", role: .cancel) { trackPendingDelete = nil }
        } message: {
            Text("删除后无法恢复。已导出的视频不受影响。")
        }
        .navigationTitle("BGM 库")
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.compact) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("BGM 库")
                        .font(DesignTokens.Typography.headline)
                    Text("全部项目共享。在「导出」页选一条 BGM，即可去除成片原 BGM、只留口播并铺上所选音乐。")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    isImporterPresented = true
                } label: {
                    Label("上传 BGM", systemImage: "plus")
                        .font(DesignTokens.Typography.labelEmphasis)
                }
                .buttonStyle(.borderedProminent)
                .help("支持 MP3 等常见音频格式，可多选")
            }
        }
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.normal) {
            Image(systemName: "music.note.list")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("还没有 BGM")
                .font(DesignTokens.Typography.bodyLargeEmphasis)
            Text("点击右上角「上传 BGM」添加音乐文件（MP3 等）")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    // MARK: - 列表

    private var trackList: some View {
        VStack(spacing: 0) {
            ForEach(store.tracks) { track in
                trackRow(track)
                Divider().padding(.leading, 44)
            }
        }
        .background(.quaternary.opacity(DesignTokens.Palette.Alpha.subtle * 2))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.medium, style: DesignTokens.Corner.style))
    }

    private func trackRow(_ track: BGMTrack) -> some View {
        let isPlaying = playingPath == track.path
        return HStack(spacing: DesignTokens.Spacing.normal) {
            Button {
                togglePreview(track)
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(isPlaying ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(isPlaying ? "暂停试听" : "试听")

            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(DesignTokens.Typography.label)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text(Self.formatDuration(track.duration))
                    .font(DesignTokens.Typography.microRounded)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                trackPendingDelete = track
            } label: {
                Image(systemName: "trash")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("删除")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // MARK: - 行为

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            ToastCenter.shared.show("选择文件失败：\(error.localizedDescription)",
                                    icon: "exclamationmark.triangle.fill", style: .error)
        case .success(let urls):
            guard !urls.isEmpty else { return }
            Task { @MainActor in
                let failures = await store.importFiles(urls: urls)
                let succeeded = urls.count - failures.count
                if failures.isEmpty {
                    ToastCenter.shared.show("已添加 \(succeeded) 条 BGM",
                                            icon: "checkmark.seal.fill", style: .success)
                } else {
                    // 失败明细不吞：逐条列出文件名和原因
                    let detail = failures.map { "\($0.name)：\($0.reason)" }.joined(separator: "\n")
                    ToastCenter.shared.show("成功 \(succeeded) 条，失败 \(failures.count) 条\n\(detail)",
                                            icon: "exclamationmark.triangle.fill", style: .warning)
                }
            }
        }
    }

    private func deleteTrack(_ track: BGMTrack) {
        if playingPath == track.path { stopPreview() }
        trackPendingDelete = nil
        Task { @MainActor in
            if let reason = await store.delete(track) {
                ToastCenter.shared.show(reason, icon: "exclamationmark.triangle.fill", style: .error)
            } else {
                ToastCenter.shared.show("已删除「\(track.name)」", icon: "trash", style: .info)
            }
        }
    }

    private func togglePreview(_ track: BGMTrack) {
        if playingPath == track.path {
            stopPreview()
            return
        }
        stopPreview()
        do {
            let p = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: track.path))
            p.play()
            player = p
            playingPath = track.path
        } catch {
            ToastCenter.shared.show("无法播放「\(track.name)」：\(error.localizedDescription)",
                                    icon: "exclamationmark.triangle.fill", style: .error)
        }
    }

    private func stopPreview() {
        player?.stop()
        player = nil
        playingPath = nil
    }

    /// 秒 → "3:25"
    static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
```

（若 `ToastCenter.show`、DesignTokens 常量名与现状不符，以现有代码为准就地调整——写前先看 `Toast.swift` 与 `DesignTokens.swift` 的真实 API。）

- [ ] **Step 3: 登记 + 编译 + 重启 + 截图自查**

```bash
cd /Users/menggang/www/Mixed_cut && ruby -e '
require "xcodeproj"
proj = Xcodeproj::Project.open("MixCut.xcodeproj")
target = proj.targets.find { |t| t.name == "MixCut" }
f = "MixCut/Views/BGMLibrary/BGMLibraryView.swift"
unless proj.files.any? { |r| (r.real_path.to_s rescue "").end_with?(f) }
  ref = proj.main_group.new_file(f)
  target.source_build_phase.add_file_reference(ref, true)
  puts "registered: #{f}"
end
proj.save
'
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3
pkill -x MixCut; sleep 1
open /Users/menggang/Library/Developer/Xcode/DerivedData/MixCut-byytuggmhodpumcmwnwrtzwkmavr/Build/Products/Debug/MixCut.app
```

截图验证（生成一条测试音频放进库目录模拟已有数据，检查列表/时长/空态）：

```bash
# 造 8 秒正弦波测试 mp3 直接放入 BGM 目录（模拟已上传）
FF=$(ls /Users/menggang/Library/Developer/Xcode/DerivedData/MixCut-byytuggmhodpumcmwnwrtzwkmavr/Build/Products/Debug/MixCut.app/Contents/Resources/bin/ffmpeg 2>/dev/null || which ffmpeg)
"$FF" -y -f lavfi -i "sine=frequency=440:duration=8" -c:a libmp3lame \
  "$HOME/Library/Application Support/MixCut/BGM/测试BGM.mp3"
sleep 2
WID=$(osascript -e 'tell app "System Events" to get id of window 1 of process "MixCut"' 2>/dev/null)
screencapture -l "$WID" /private/tmp/claude-501/-Users-menggang-www-Mixed-cut/26a8a2ee-ec9d-48f0-9748-efe9d50ef8c6/scratchpad/bgm_library.png
```

用 Read 工具查看截图，确认：侧边栏出现「BGM 库」、列表显示「测试BGM.mp3 / 0:08」、上传按钮在位。不对就修。

---

### Task 6: App — 导出管线支持全局 BGM（DubSegmentSpec / DubExportInput / DubExportService）

**Files:**
- Modify: `MixCut/Services/Export/DubExportService.swift`
- Modify: `MixCut/Services/Export/ExportService.swift`（ExportError 加一个 case）

**Interfaces:**
- Consumes: `VocalsSource`、`GlobalBGMMixGraphBuilder`（Task 1/2）、`FileHelper.stemsDirectory`
- Produces:
  - `struct GlobalBGMSpec: Sendable { let audioPath: String; let volume: Double }`
  - `DubSegmentSpec` 新增 `vocalsAudioPath: String?`、`vocalsStart: Double`、`vocalsEnd: Double`（带默认值的显式 init，`VariantBatchExportService` 等既有调用点零改动）
  - `DubExportInput.from(scheme:combo:useVocalsOnly:)`：`useVocalsOnly = true` 时原声/锁定/回退段带 vocals 切片信息、配音段不混原分离 BGM；任一分镜的 vocals.wav 缺失 → 返回 nil（调用方已在预检阶段拿到具体失败原因）
  - `DubExportService.export(input:outputPath:config:globalBGM:onProgress:)`：`globalBGM != nil` 时 concat 后新增「铺底 BGM」阶段
  - `ExportError.missingVocals(String)`

- [ ] **Step 1: DubSegmentSpec 加字段与显式 init**

在 `DubSegmentSpec` 末尾加三个字段，并补显式 init（新字段带默认值，其余参数按现有字段顺序全列）：

```swift
    /// 全局 BGM 模式：原声段改用整轨纯人声 wav（原视频 stems/vocals.wav）；nil = 常规模式
    let vocalsAudioPath: String?
    /// 人声切片窗（**原视频时间轴**，秒）。替换画面段也用原视频时间——替换片音轨本取自原视频同窗口。
    let vocalsStart: Double
    let vocalsEnd: Double

    init(videoPath: String, startFrame: Int, endFrame: Int, fps: Double,
         captionLines: [CaptionLine], hasHardSubtitle: Bool, maskStyleRaw: String,
         maskRect: SubtitleMaskRect, isVoiceLocked: Bool, dubAudioPath: String?,
         freezePadFrames: Int, trailingSilence: Double, bgmAudioPath: String?,
         subtitleFontRatio: Double,
         vocalsAudioPath: String? = nil, vocalsStart: Double = 0, vocalsEnd: Double = 0) {
        self.videoPath = videoPath; self.startFrame = startFrame; self.endFrame = endFrame
        self.fps = fps; self.captionLines = captionLines; self.hasHardSubtitle = hasHardSubtitle
        self.maskStyleRaw = maskStyleRaw; self.maskRect = maskRect; self.isVoiceLocked = isVoiceLocked
        self.dubAudioPath = dubAudioPath; self.freezePadFrames = freezePadFrames
        self.trailingSilence = trailingSilence; self.bgmAudioPath = bgmAudioPath
        self.subtitleFontRatio = subtitleFontRatio
        self.vocalsAudioPath = vocalsAudioPath; self.vocalsStart = vocalsStart; self.vocalsEnd = vocalsEnd
    }
```

同文件加：

```swift
/// 全局 BGM 铺底参数（导出时用户在导出页选中的 BGM）。
struct GlobalBGMSpec: Sendable {
    let audioPath: String
    /// BGM 音量 0…1（UI 默认 0.6）
    let volume: Double
}
```

- [ ] **Step 2: DubExportInput.from 支持 useVocalsOnly**

签名改为 `static func from(scheme: MixScheme, combo: [UUID?]? = nil, useVocalsOnly: Bool = false) -> DubExportInput?`。循环体内、拿到 `segment`/`video` 后：

```swift
            // 全局 BGM 模式：所有段都必须能拿到纯人声源，缺一即整条成片不可导
            // （预检阶段已保证分离成功；这里兜底防御，绝不静默回退成混音原声）
            var vocalsPath: String? = nil
            if useVocalsOnly {
                guard let vp = Self.vocalsPath(for: video) else {
                    MixLog.error("[Export] 全局 BGM 模式缺少 vocals.wav：\(video.name)")
                    return nil
                }
                vocalsPath = vp
            }
```

三个 spec 构造分支（原声/锁定、配音、回退）统一追加参数：

- 原声/锁定分支与回退分支：`vocalsAudioPath: vocalsPath, vocalsStart: segment.startTime, vocalsEnd: segment.endTime`
- 配音分支：`bgmAudioPath: useVocalsOnly ? nil : Self.bgmPath(for: video)`（配音段本身就是纯人声，全局 BGM 模式下不再混原视频分离 BGM；vocals 三参保持默认——配音段用不到）

加辅助函数（与现有 `bgmPath(for:)` 并排）：

```swift
    /// 原声段的纯人声源：demucs 分离出的整轨 vocals.wav；不存在 → nil。
    /// 调用方（全局 BGM 模式）需已在预检阶段完成分离。
    private static func vocalsPath(for video: Video) -> String? {
        guard let hash = video.contentHash else { return nil }
        let path = FileHelper.stemsDirectory(videoHash: hash).appendingPathComponent("vocals.wav").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
```

- [ ] **Step 3: renderSegment 接入 vocalsSource（不静默回退）**

`renderSegment` 中、dub 音频输入拼装之后加：

```swift
        // 全局 BGM 模式：原声段音频改取整轨纯人声切片。文件缺失=结果达不到承诺，直接报错，绝不回退混音原声。
        var vocalsSource: VocalsSource? = nil
        if keepOriginalAudio, let vocPath = spec.vocalsAudioPath {
            guard FileManager.default.fileExists(atPath: vocPath) else {
                throw ExportError.missingVocals(vocPath)
            }
            extraInputs.append(vocPath)
            vocalsSource = VocalsSource(inputIndex: extraInputs.count,
                                        start: spec.vocalsStart, end: spec.vocalsEnd)
        }
```

`DubSegmentGraphBuilder.build(...)` 调用尾部加 `vocalsSource: vocalsSource`。

- [ ] **Step 4: export 加 globalBGM 参数与铺底阶段**

`export` 签名在 `config` 后加 `globalBGM: GlobalBGMSpec? = nil`。阶段二改为：

```swift
        // 阶段二：concat 无损拼接。选了全局 BGM 时先落中间片，再铺底 BGM 到最终输出。
        onProgress?(ExportProgress(phase: .concatenating, progress: 0.88, description: "拼接成片…"))
        let concatTarget = globalBGM == nil
            ? outputPath
            : workDir.appendingPathComponent("voiced.mp4").path
        try await concatCopy(paths: intermediatePaths, workDir: workDir, outputPath: concatTarget)

        if let bgm = globalBGM {
            onProgress?(ExportProgress(phase: .concatenating, progress: 0.95, description: "铺底背景音乐…"))
            try await mixGlobalBGM(voicedPath: concatTarget, bgm: bgm, outputPath: outputPath)
        }

        onProgress?(ExportProgress(phase: .completed, progress: 1.0, description: "配音导出完成"))
```

新增私有方法：

```swift
    // MARK: - 全局 BGM 铺底

    /// 把选中的 BGM 铺到纯口播成片上：视频流直拷（不重编码），音频 = 口播 + BGM 混音。
    /// BGM 短于成片由 -stream_loop 循环补齐，长于成片由滤镜 atrim 截断，结尾 1 秒淡出。
    private func mixGlobalBGM(voicedPath: String, bgm: GlobalBGMSpec, outputPath: String) async throws {
        guard FileManager.default.fileExists(atPath: bgm.audioPath) else {
            throw ExportError.encodingFailed("背景音乐文件不存在：\((bgm.audioPath as NSString).lastPathComponent)，请回「BGM 库」检查")
        }
        let duration = await probeDuration(voicedPath)
        guard duration > 0 else {
            throw ExportError.encodingFailed("无法读取成片时长，背景音乐铺底失败")
        }
        let graph = GlobalBGMMixGraphBuilder.filterComplex(pieceDuration: duration, bgmVolume: bgm.volume)
        let args = ["-y", "-i", voicedPath,
                    "-stream_loop", "-1", "-i", bgm.audioPath,
                    "-filter_complex", graph,
                    "-map", "0:v", "-map", "[aout]",
                    "-c:v", "copy",
                    "-c:a", "aac", "-b:a", "192k", "-ar", "44100", "-ac", "2",
                    "-movflags", "+faststart", outputPath]
        _ = try await ffmpeg.run(arguments: args, totalDuration: nil, onProgress: nil)
    }

    /// 读容器时长（秒）；失败返回 0。
    private func probeDuration(_ path: String) async -> Double {
        let out = try? await ffmpeg.runProbe(arguments: [
            "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path])
        return Double((out ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
```

- [ ] **Step 5: ExportError 加 case**

`ExportService.swift` 的 `ExportError`：

```swift
    case missingVocals(String)
```

`errorDescription`：

```swift
        case .missingVocals(let path):
            return "人声分离产物缺失（\((path as NSString).lastPathComponent)），无法去除原 BGM。请重新导出（会自动重新分离）"
```

- [ ] **Step 6: 编译验证**

Run: `xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`（同时确认 `VariantBatchExportService.swift` 未改动也能编过——init 默认值生效）
Run: `swift test`（全量回归）→ 全部 PASS

---

### Task 7: App — ExportView：BGM 选择 UI + 人声分离预检 + 失败透出

**Files:**
- Modify: `MixCut/Views/Export/ExportView.swift`

**Interfaces:**
- Consumes: `BGMLibraryStore`、`GlobalBGMSpec`、`VocalSeparationService`、`DubExportInput.from(scheme:combo:useVocalsOnly:)`、`DubExportService.export(...globalBGM:)`、`FriendlyError.reason(for:)`
- Produces: 导出设置「背景音乐」区块（默认「保留原 BGM」）+ 选中后音量滑杆；导出流程带 BGM 预检

- [ ] **Step 1: 状态与 UI**

State 区加：

```swift
    /// 全局 BGM：nil = 保留原 BGM（现有行为零改动）
    @State private var bgmStore = BGMLibraryStore()
    @State private var selectedBGMPath: String? = nil
    @State private var bgmVolume: Double = 0.6
```

`exportSettings` 的质量提示之后追加：

```swift
                Divider().padding(.vertical, 4)

                Picker("背景音乐", selection: $selectedBGMPath) {
                    Text("保留原 BGM").tag(String?.none)
                    ForEach(bgmStore.tracks) { track in
                        Text("\(track.name)（\(BGMLibraryView.formatDuration(track.duration))）")
                            .tag(String?.some(track.path))
                    }
                }

                if selectedBGMPath != nil {
                    HStack(spacing: DesignTokens.Spacing.normal) {
                        Text("BGM 音量")
                            .font(DesignTokens.Typography.label)
                        Slider(value: $bgmVolume, in: 0.1...1.0)
                        Text("\(Int(bgmVolume * 100))%")
                            .font(DesignTokens.Typography.microRounded)
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                            .monospacedDigit()
                    }
                    HStack(spacing: DesignTokens.Spacing.tight) {
                        Image(systemName: "music.note")
                            .font(DesignTokens.Typography.microRegular)
                            .foregroundStyle(.tertiary)
                        Text("将去除各分镜原 BGM、只保留口播，再铺上所选音乐（比成片长则截断，短则循环，结尾 1 秒淡出）。首次会对相关视频做人声分离，耗时较长。")
                            .font(DesignTokens.Typography.microRegular)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        Spacer()
                    }
                }
```

`body` 上加载 BGM 列表并校验选中项仍存在（BGM 库里删掉后回到导出页不能残留失效选择）：

```swift
        .task {
            await bgmStore.reload()
            if let path = selectedBGMPath, !bgmStore.tracks.contains(where: { $0.path == path }) {
                selectedBGMPath = nil
            }
        }
```

（挂在现有 `.onAppear` 同层；注意切项目 `onChange` 不重置 BGM 选择——BGM 是全局的，与项目无关。）

- [ ] **Step 2: 确认弹窗文案带 BGM 信息**

`alert` 的 message 改为：

```swift
        } message: {
            Text(selectedBGMPath == nil
                 ? "选中 \(count) 个方案，画面不变，按每个分镜的「原声 + 各改写版」全部排列组合，串行逐条生成（一条一条导，避免占满机器）。"
                 : "选中 \(count) 个方案，将替换背景音乐：去除原 BGM、只留口播，并铺上所选 BGM。首次需要对相关视频做人声分离，耗时较长。")
        }
```

- [ ] **Step 3: startDubbedExport 接入 BGM 预检与失败透出**

方法开头（`guard !allSchemes.isEmpty` 之后）：

```swift
        // 全局 BGM：导出前先验证所选文件还在（可能刚在 BGM 库里被删）
        let globalBGM: GlobalBGMSpec? = selectedBGMPath.map { GlobalBGMSpec(audioPath: $0, volume: bgmVolume) }
        if let bgm = globalBGM, !FileManager.default.fileExists(atPath: bgm.audioPath) {
            errorMessage = "所选背景音乐文件已不存在，请到「BGM 库」确认后重新选择。"
            selectedBGMPath = nil
            return
        }
```

Task 体内、`isExporting = true` 之后加 `exportFailures = []`（顺带修复现有 bug：该路径从不清空失败清单，多次导出会累积旧记录）。

第 1 步「准备音频」循环之后、第 2 步扁平化之前，插入人声分离预检：

```swift
                // 1.5) 全局 BGM 预检：为选中方案涉及的每个源视频准备 vocals.wav。
                // 失败的**不回退**（回退=悄悄给用户混着原 BGM 的片子），记录人话原因，
                // 涉及该视频的方案整个标记失败，不影响其他方案。
                var sepFailures: [UUID: (videoName: String, reason: String)] = [:]
                if globalBGM != nil {
                    var involved: [Video] = []
                    var seen = Set<UUID>()
                    for (scheme, _) in plans {
                        for ss in scheme.orderedSegments {
                            guard let v = ss.segment?.video, !seen.contains(v.id) else { continue }
                            seen.insert(v.id)
                            involved.append(v)
                        }
                    }
                    let separator = VocalSeparationService()
                    for (index, video) in involved.enumerated() {
                        if Task.isCancelled { break }
                        exportProgress = BatchExportProgress(
                            total: max(1, involved.count), completed: index,
                            description: "人声分离 \(index + 1)/\(involved.count)：\(video.name)…")
                        guard let hash = video.contentHash else {
                            sepFailures[video.id] = (video.name, "视频缺少内容哈希，无法定位人声分离缓存")
                            continue
                        }
                        do {
                            _ = try await separator.separate(videoPath: video.localPath, videoHash: hash)
                        } catch {
                            sepFailures[video.id] = (video.name, FriendlyError.reason(for: error))
                        }
                    }
                }
```

第 2 步 jobs 组装改为（涉及分离失败视频的方案 → 全部组合直接进失败清单；`from` 加 `useVocalsOnly`）：

```swift
                var jobs: [DubExportJob] = []
                for (scheme, combos) in plans {
                    if globalBGM != nil,
                       let badVideo = scheme.orderedSegments.compactMap({ $0.segment?.video })
                           .first(where: { sepFailures[$0.id] != nil }) {
                        let failure = sepFailures[badVideo.id]!
                        exportFailures.append(ExportFailure(
                            name: scheme.name,
                            reason: "视频「\(failure.videoName)」人声分离失败：\(failure.reason)。无法去除原 BGM，该方案的 \(combos.count) 条组合均未导出。"))
                        continue
                    }
                    let strategyName = scheme.strategy?.name ?? "未分组"
                    for combo in combos {
                        guard let input = DubExportInput.from(scheme: scheme, combo: combo.choices,
                                                              useVocalsOnly: globalBGM != nil) else { continue }
                        let base = sanitizeFilename("\(strategyName)_方案\(scheme.variationIndex)_\(combo.nameSuffix)")
                        jobs.append(DubExportJob(
                            input: input,
                            outputPath: url.appendingPathComponent("\(base).mp4").path,
                            label: "\(scheme.name) \(combo.nameSuffix)"))
                    }
                }
```

第 3 步 `service.export(...)` 调用加 `globalBGM: globalBGM`。

- [ ] **Step 4: 编译 + 重启 + 截图自查**

```bash
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -3
pkill -x MixCut; sleep 1
open /Users/menggang/Library/Developer/Xcode/DerivedData/MixCut-byytuggmhodpumcmwnwrtzwkmavr/Build/Products/Debug/MixCut.app
sleep 2
WID=$(osascript -e 'tell app "System Events" to get id of window 1 of process "MixCut"' 2>/dev/null)
screencapture -l "$WID" /private/tmp/claude-501/-Users-menggang-www-Mixed-cut/26a8a2ee-ec9d-48f0-9748-efe9d50ef8c6/scratchpad/export_bgm.png
```

用 Read 查看截图确认：导出设置出现「背景音乐」下拉、默认「保留原 BGM」。（下拉选中态与滑杆需要点击交互，列入用户必测清单。）

---

### Task 8: 回归验证 + 多 agent 审查 + bump 版本 + 打 DMG

**Files:**
- Modify: `VERSION`（0.9.1 → 0.9.2）、`MixCut.xcodeproj/project.pbxproj`（两处 MARKETING_VERSION）

- [ ] **Step 1: 全量测试与回归**

```bash
swift test 2>&1 | tail -5        # MixCutCore 全绿
```

人工回归（按 CLAUDE.md「不破坏已有功能」清单，重点导出页相邻功能）：
1. 不选 BGM 导出路径完全不变（确认弹窗文案、原声组合导出仍可用）
2. 切项目：导出页状态重置、BGM 选择保留（全局属性）、方案列表联动刷新
3. 侧边栏其余导航项照常工作；BGM 库页切走再切回列表还在
4. 分镜素材库批量导出不受影响（未接入 BGM）

- [ ] **Step 2: 并行审查（项目规则：改完必须 review）**

并行调用 `everything-claude-code:code-reviewer`（代码质量）+ `everything-claude-code:security-reviewer`（文件导入/路径处理），针对本次全部改动文件。处理 CRITICAL/HIGH 问题后重新编译 + `swift test`。

- [ ] **Step 3: bump 版本 + Release universal + DMG（守双系统铁律）**

```bash
cd /Users/menggang/www/Mixed_cut
echo "0.9.2" > VERSION
# pbxproj 两处 MARKETING_VERSION 同步改为 0.9.2（sed 或 Edit）
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Release \
  -destination 'generic/platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build 2>&1 | tail -3
APP=/Users/menggang/Library/Developer/Xcode/DerivedData/MixCut-byytuggmhodpumcmwnwrtzwkmavr/Build/Products/Release/MixCut.app
lipo -archs "$APP/Contents/MacOS/MixCut"        # 必须 x86_64 arm64
V=$(cat VERSION)
TEMP=$(mktemp -d) && cp -R "$APP" "$TEMP/" && ln -s /Applications "$TEMP/Applications"
rm -f ~/Desktop/MixCut-v${V}.dmg
hdiutil create -volname "MixCut ${V}" -srcfolder "$TEMP" -ov -format UDZO ~/Desktop/MixCut-v${V}.dmg
rm -rf "$TEMP"
# 校验 DMG 内版本号
MNT=$(hdiutil attach ~/Desktop/MixCut-v${V}.dmg -nobrowse | awk -F'\t' 'END{print $NF}')
/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$MNT/MixCut.app/Contents/Info.plist"
hdiutil detach "$MNT"
```

- [ ] **Step 4: 输出用户必测清单（不能自动验证的项）**

1. BGM 库：通过文件选择器上传真实 MP3（多选）、试听播放/暂停、删除确认
2. 导出：选一条 BGM 导出一个方案，播放成片确认——原 BGM 已去除、口播清晰、BGM 铺满全片、结尾有淡出
3. BGM 比成片短的场景：确认循环无缝
4. 含配音变体的方案 + BGM：配音段人声正常、无原 BGM 残留
5. 含替换画面分镜的方案 + BGM：口播与画面无错位
6. 故意断网/删 stems 缓存后……（正常情况分离是本地的，不涉网；只需确认分离失败时失败清单文案说清了视频名与原因）

**不做 git commit**——等用户验证后由用户决定提交时机。
