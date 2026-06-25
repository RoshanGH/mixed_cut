# 配音 P4：字幕烧制 + 三模式遮挡 + 两阶段配音导出 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给定「某一版配音的逐分镜解析结果」，渲染出一条成片——逐分镜遮挡旧硬字幕、烧录新台词字幕、替换为新音色音轨（明星锁定段保留原声原画原字幕），最终拼接成可投放的 9:16 竖屏 MP4。

**Architecture:** 两阶段导出。阶段一逐分镜生成「中间片」(精确切片 → 9:16 标准化 → 遮挡旧字幕 → 叠新字幕 PNG → 换音轨 → 末尾定格/补静音 → 统一硬件编码)；阶段二用 concat 解复用器 `-c copy` 无损拼接所有中间片。字幕用 macOS 原生（系统苹方字体）渲染成透明 PNG，再用 ffmpeg `overlay` 叠加——内置 ffmpeg 无 libass，无法用 `subtitles`/`drawtext` 滤镜。纯逻辑（遮挡模式映射、像素落位、滤镜图字符串、字幕 PNG 渲染）全部下沉到 MixCutCore 用 `swift test` 覆盖；只有编排服务在 App 层。**现有普通导出 `ExportService` 完全不动**，配音版走全新 `DubExportService`。

**Tech Stack:** Swift 5.10 / SwiftUI / SwiftData（App 端）；MixCutCore 纯逻辑库（`swift test`）；AppKit（`NSBitmapImageRep` 离屏渲染字幕）；内置 ffmpeg/ffprobe（`MixCut/Resources/bin/`）。

## Global Constraints

- **视频比例 9:16 竖屏**：所有成片与中间片统一 `scale=W:H:force_original_aspect_ratio=decrease,pad=W:H:(ow-iw)/2:(oh-ih)/2:black,setsar=1`，默认 `1080:1920`。
- **字幕用系统苹方字体（PingFangSC-Semibold），绝不打包字体、不重编 ffmpeg**；字号回退 `NSFont.boldSystemFont`。
- **字幕渲染必须用 `NSBitmapImageRep(bitmapDataPlanes:nil, pixelsWide:…, pixelsHigh:…, …)` 显式 1:1 像素**；**绝不能用 `NSImage.lockFocus`**（会按 Retina 2× 放大，PNG 尺寸翻倍，overlay 落点变负、字幕飘出画面）。
- **只用内置 ffmpeg 已确认存在的滤镜**：`trim/atrim/setpts/asetpts/scale/pad/setsar/fps/split/crop/boxblur/drawbox/overlay/tpad/apad/aresample/loudnorm/null/anull`（已实测全部可用且滤镜图被接受）。**不可用** `subtitles/ass/drawtext`（无 libass/freetype）。
- **MixCutCore 纯逻辑、无 SwiftData 依赖**；可 `import AppKit`（macOS target 支持，离屏 bitmap 渲染无需窗口服务器）。App target 通过 xcodeproj 把 `Sources/MixCutCore/*.swift` 当**同模块**编译（无需 `import MixCutCore`），故每个新增 Core 文件必须在 `MixCut.xcodeproj/project.pbxproj` 登记进 App target。
- **不可变优先**：纯逻辑返回新值，不就地改参。`let` 优先。
- **不改动现有普通导出**：`MixCut/Services/Export/ExportService.swift`、`FFmpegRunner.concat` 一行不动。
- **明星锁定段（`Segment.isVoiceLocked == true`）**：保留原视频原音轨原字幕，不遮挡、不叠字幕、不换音轨。
- AI 提供商仅千问/MiniMax/Claude（本计划不涉及 AI 调用）。

---

## 文件结构

**MixCutCore（纯逻辑 + `swift test`，需同时登记进 App target）**
- `Sources/MixCutCore/SubtitleMaskMode.swift` — 遮挡渲染模式枚举 + 从 (hasHardSubtitle, maskStyleRaw) 的映射
- `Sources/MixCutCore/CaptionLayout.swift` — `PixelRect` + 字幕 PNG 在画面里的像素落位计算
- `Sources/MixCutCore/CaptionRenderer.swift` — AppKit 把台词渲染成透明 PNG（显式像素，防 2×）
- `Sources/MixCutCore/DubSegmentGraph.swift` — 单分镜中间片的完整 `filter_complex` 字符串构建

**MixCutCore 测试**
- `Tests/MixCutCoreTests/SubtitleMaskModeTests.swift`
- `Tests/MixCutCoreTests/CaptionLayoutTests.swift`
- `Tests/MixCutCoreTests/CaptionRendererTests.swift`
- `Tests/MixCutCoreTests/DubSegmentGraphTests.swift`

**App（编排，集成测试）**
- `MixCut/Services/Export/DubExportService.swift` — `DubExportInput` / `DubSegmentSpec` 值类型 + `from(scheme:variant:)` 映射 + 两阶段导出 actor

**修改**
- `MixCut.xcodeproj/project.pbxproj` — 登记 4 个 Core 文件 + 1 个 App 文件进 App target

---

## pbxproj 登记规则（每个新文件必做，照抄现有模式）

App target 必须能看到每个新增 `.swift`，否则编译期报“找不到类型”。每次新增文件用 `uuidgen | tr -dA-F0-9 | cut -c1-24` 生成两个**唯一** 24 位十六进制 ID（一个 BuildFile、一个 FileReference）。

**Core 文件**（参照 `AlignmentPlan.swift`，4 处登记）：
1. `PBXBuildFile` 段：`<BUILDID> /* X.swift in Sources */ = {isa = PBXBuildFile; fileRef = <REFID> /* X.swift */; };`
2. `PBXFileReference` 段：`<REFID> /* X.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; name = X.swift; path = Sources/MixCutCore/X.swift; sourceTree = "<group>"; };`（注意 `path` 含 `Sources/MixCutCore/`）
3. MixCutCore 所在的 `PBXGroup` children：加一行 `<REFID> /* X.swift */,`（紧挨现有 `AlignmentPlan.swift` 那行）
4. App target 的 `PBXSourcesBuildPhase` files：加一行 `<BUILDID> /* X.swift in Sources */,`

**App 文件**（参照 `DubAudioFinalizer.swift`，3 处登记）：
1. `PBXBuildFile`：`<BUILDID> /* X.swift in Sources */ = {isa = PBXBuildFile; fileRef = <REFID> /* X.swift */; };`
2. `PBXFileReference`：`<REFID> /* X.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = X.swift; sourceTree = "<group>"; };`（`path` 仅文件名；文件物理放在对应分组目录）
3. App target `PBXSourcesBuildPhase`：`<BUILDID> /* X.swift in Sources */,`
（App 文件还需挂进它所在的 `Services/Export` 分组 children，与 `ExportService.swift` 同组。）

> 校验：每次登记后 `grep -c "X.swift" MixCut.xcodeproj/project.pbxproj` 应为 **4**（Core）或 **3~4**（App，含分组）。

---

### Task 1: SubtitleMaskMode（遮挡渲染模式 + 映射）

**Files:**
- Create: `Sources/MixCutCore/SubtitleMaskMode.swift`
- Test: `Tests/MixCutCoreTests/SubtitleMaskModeTests.swift`
- Modify: `MixCut.xcodeproj/project.pbxproj`（登记 Core 文件，见上）

**Interfaces:**
- Produces: `enum SubtitleMaskMode: String, Equatable, Sendable, CaseIterable { case none, blur, solid, dim }`；`static func from(hasHardSubtitle: Bool, maskStyleRaw: String) -> SubtitleMaskMode`

- [ ] **Step 1: 写失败测试**

```swift
import Testing
@testable import MixCutCore

@Suite("SubtitleMaskMode")
struct SubtitleMaskModeTests {
    @Test("无硬字幕 → none，忽略 style")
    func noHardSubtitleIsNone() {
        #expect(SubtitleMaskMode.from(hasHardSubtitle: false, maskStyleRaw: "solid") == .none)
        #expect(SubtitleMaskMode.from(hasHardSubtitle: false, maskStyleRaw: "blur") == .none)
    }

    @Test("有硬字幕 → 按 style 映射")
    func mapsKnownStyles() {
        #expect(SubtitleMaskMode.from(hasHardSubtitle: true, maskStyleRaw: "blur") == .blur)
        #expect(SubtitleMaskMode.from(hasHardSubtitle: true, maskStyleRaw: "solid") == .solid)
        #expect(SubtitleMaskMode.from(hasHardSubtitle: true, maskStyleRaw: "dim") == .dim)
    }

    @Test("未知 style 退回 blur")
    func unknownStyleFallsBackToBlur() {
        #expect(SubtitleMaskMode.from(hasHardSubtitle: true, maskStyleRaw: "wat") == .blur)
        #expect(SubtitleMaskMode.from(hasHardSubtitle: true, maskStyleRaw: "") == .blur)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter SubtitleMaskModeTests`
Expected: 编译失败 `cannot find 'SubtitleMaskMode' in scope`

- [ ] **Step 3: 写实现**

```swift
import Foundation

/// 字幕遮挡渲染模式（纯 Core 表示，与 App 的 MaskStyle/hasHardSubtitle 解耦）。
public enum SubtitleMaskMode: String, Equatable, Sendable, CaseIterable {
    case none    // 原片无硬字幕：不遮挡，仅叠新字幕
    case blur    // 模糊遮挡旧字幕
    case solid   // 纯色字幕条遮挡旧字幕
    case dim     // 半透明压暗（遮挡力度弱，一般不用）

    /// 从 App 层「是否有硬字幕 + maskStyle 原始值」映射到渲染模式。
    /// hasHardSubtitle == false → .none（无视 style）；否则按 style 取，未知退回 .blur。
    public static func from(hasHardSubtitle: Bool, maskStyleRaw: String) -> SubtitleMaskMode {
        guard hasHardSubtitle else { return .none }
        switch maskStyleRaw {
        case "blur":  return .blur
        case "solid": return .solid
        case "dim":   return .dim
        default:      return .blur
        }
    }
}
```

- [ ] **Step 4: 登记 pbxproj（Core 文件 4 处）+ 跑测试确认通过**

Run: `swift test --filter SubtitleMaskModeTests`
Expected: PASS（3 tests）
Run: `grep -c "SubtitleMaskMode.swift" MixCut.xcodeproj/project.pbxproj`
Expected: `4`

- [ ] **Step 5: 提交**

```bash
git add Sources/MixCutCore/SubtitleMaskMode.swift Tests/MixCutCoreTests/SubtitleMaskModeTests.swift MixCut.xcodeproj/project.pbxproj
git commit -m "feat(dubbing): P4 SubtitleMaskMode 遮挡模式枚举与映射"
```

---

### Task 2: CaptionLayout（PixelRect + 字幕 PNG 像素落位）

**Files:**
- Create: `Sources/MixCutCore/CaptionLayout.swift`
- Test: `Tests/MixCutCoreTests/CaptionLayoutTests.swift`
- Modify: `MixCut.xcodeproj/project.pbxproj`（登记 Core 文件）

**Interfaces:**
- Consumes: `SubtitleMaskRect`（已存在于 `Sources/MixCutCore/SubtitleMaskRect.swift`，有 `.clamped()` 和 `.pixelRect(width:height:)`）
- Produces:
  - `struct PixelRect: Equatable, Sendable { let x, y, width, height: Int; init(x:y:width:height:); static func from(_ rect: SubtitleMaskRect, outputWidth: Int, outputHeight: Int) -> PixelRect }`
  - `enum CaptionLayout { static func overlayOrigin(outputWidth: Int, outputHeight: Int, maskRect: SubtitleMaskRect, captionWidth: Int, captionHeight: Int) -> (x: Int, y: Int) }`

- [ ] **Step 1: 写失败测试**

```swift
import Testing
@testable import MixCutCore

@Suite("CaptionLayout")
struct CaptionLayoutTests {
    @Test("PixelRect 归一化换算并钳进画面、取整、最小 2px")
    func pixelRectConversion() {
        let rect = SubtitleMaskRect(x: 0.0, y: 0.80, width: 1.0, height: 0.12)
        let px = PixelRect.from(rect, outputWidth: 1080, outputHeight: 1920)
        #expect(px.x == 0)
        #expect(px.width == 1080)
        #expect(px.y == 1536)            // round(0.80 * 1920)
        #expect(px.height == 230)        // round(0.12 * 1920)
    }

    @Test("字幕水平居中于整幅画面")
    func captionCenteredHorizontally() {
        let band = SubtitleMaskRect(x: 0.0, y: 0.80, width: 1.0, height: 0.12)
        let o = CaptionLayout.overlayOrigin(outputWidth: 1080, outputHeight: 1920,
                                            maskRect: band, captionWidth: 600, captionHeight: 100)
        #expect(o.x == 240)              // (1080 - 600) / 2
    }

    @Test("字幕竖直居中于字幕带")
    func captionCenteredInBand() {
        let band = SubtitleMaskRect(x: 0.0, y: 0.80, width: 1.0, height: 0.12) // 像素 y=1536 h=230
        let o = CaptionLayout.overlayOrigin(outputWidth: 1080, outputHeight: 1920,
                                            maskRect: band, captionWidth: 600, captionHeight: 100)
        #expect(o.y == 1601)             // 1536 + (230 - 100)/2
    }

    @Test("字幕比画面宽时 x 钳到 0")
    func captionWiderThanFrameClampsX() {
        let band = SubtitleMaskRect.defaultBottomBand
        let o = CaptionLayout.overlayOrigin(outputWidth: 1080, outputHeight: 1920,
                                            maskRect: band, captionWidth: 1200, captionHeight: 100)
        #expect(o.x == 0)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter CaptionLayoutTests`
Expected: 编译失败 `cannot find 'PixelRect' / 'CaptionLayout' in scope`

- [ ] **Step 3: 写实现**

```swift
import Foundation

/// 整数像素矩形（ffmpeg crop/drawbox/overlay 需要整数坐标）。
public struct PixelRect: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// 归一化矩形 → 像素并取整：宽高至少 2px，整体钳进画面不出界。
    public static func from(_ rect: SubtitleMaskRect, outputWidth: Int, outputHeight: Int) -> PixelRect {
        let p = rect.clamped().pixelRect(width: Double(outputWidth), height: Double(outputHeight))
        var w = Int(p.width.rounded())
        var h = Int(p.height.rounded())
        w = max(2, min(w, outputWidth))
        h = max(2, min(h, outputHeight))
        var x = Int(p.x.rounded())
        var y = Int(p.y.rounded())
        x = max(0, min(x, outputWidth - w))
        y = max(0, min(y, outputHeight - h))
        return PixelRect(x: x, y: y, width: w, height: h)
    }
}

/// 字幕 PNG 在成片画面里的像素落位（纯数学）。
public enum CaptionLayout {
    /// 计算字幕 PNG 的 overlay 原点（左上角像素）。水平居中于整幅画面；
    /// 竖直居中于 maskRect 字幕带；最后钳进画面避免出界。
    public static func overlayOrigin(outputWidth: Int, outputHeight: Int,
                                     maskRect: SubtitleMaskRect,
                                     captionWidth: Int, captionHeight: Int) -> (x: Int, y: Int) {
        let band = PixelRect.from(maskRect, outputWidth: outputWidth, outputHeight: outputHeight)
        let rawX = (Double(outputWidth) - Double(captionWidth)) / 2.0
        let rawY = Double(band.y) + (Double(band.height) - Double(captionHeight)) / 2.0
        let maxX = Double(max(0, outputWidth - captionWidth))
        let maxY = Double(max(0, outputHeight - captionHeight))
        let x = Int(min(max(rawX, 0), maxX).rounded())
        let y = Int(min(max(rawY, 0), maxY).rounded())
        return (x, y)
    }
}
```

- [ ] **Step 4: 登记 pbxproj + 跑测试确认通过**

Run: `swift test --filter CaptionLayoutTests`
Expected: PASS（4 tests）
Run: `grep -c "CaptionLayout.swift" MixCut.xcodeproj/project.pbxproj`
Expected: `4`

- [ ] **Step 5: 提交**

```bash
git add Sources/MixCutCore/CaptionLayout.swift Tests/MixCutCoreTests/CaptionLayoutTests.swift MixCut.xcodeproj/project.pbxproj
git commit -m "feat(dubbing): P4 CaptionLayout 字幕像素落位计算"
```

---

### Task 3: CaptionRenderer（AppKit 渲染透明字幕 PNG，防 Retina 2×）

**Files:**
- Create: `Sources/MixCutCore/CaptionRenderer.swift`
- Test: `Tests/MixCutCoreTests/CaptionRendererTests.swift`
- Modify: `MixCut.xcodeproj/project.pbxproj`（登记 Core 文件）

**Interfaces:**
- Produces:
  - `struct CaptionImage: Equatable, Sendable { let pngData: Data; let pixelWidth: Int; let pixelHeight: Int }`
  - `enum CaptionRenderer { static func render(text: String, canvasWidth: Int, withBackdrop: Bool, fontSize: CGFloat = 56) throws -> CaptionImage; @discardableResult static func renderToFile(text: String, canvasWidth: Int, withBackdrop: Bool, fontSize: CGFloat = 56, to url: URL) throws -> CaptionImage }`

- [ ] **Step 1: 写失败测试**（断言 1× 像素，直接抓住 Retina 2× 回归）

```swift
import Testing
import Foundation
#if canImport(AppKit)
import AppKit
#endif
@testable import MixCutCore

@Suite("CaptionRenderer")
struct CaptionRendererTests {
    @Test("渲染出的 PNG 是 1× 像素，宽度等于请求画布（不是 2×）")
    func rendersAtOnePixelScale() throws {
        let img = try CaptionRenderer.render(text: "测试字幕一二三四五", canvasWidth: 900, withBackdrop: true)
        #expect(img.pixelWidth == 900)               // 关键：不是 1800
        #expect(img.pixelHeight > 0)
        #expect(img.pixelHeight < 600)
        #expect(!img.pngData.isEmpty)
        #if canImport(AppKit)
        let rep = NSBitmapImageRep(data: img.pngData)
        #expect(rep?.pixelsWide == 900)              // PNG 解码后仍 1×
        #endif
    }

    @Test("无底衬模式同样产出 1× PNG")
    func rendersWithoutBackdrop() throws {
        let img = try CaptionRenderer.render(text: "纯色条上的字幕", canvasWidth: 720, withBackdrop: false)
        #expect(img.pixelWidth == 720)
        #expect(!img.pngData.isEmpty)
    }

    @Test("写文件成功且文件非空")
    func renderToFileWritesPNG() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cap_test.png")
        try? FileManager.default.removeItem(at: url)
        let img = try CaptionRenderer.renderToFile(text: "落盘测试", canvasWidth: 600, withBackdrop: true, to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(img.pixelWidth == 600)
        try? FileManager.default.removeItem(at: url)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter CaptionRendererTests`
Expected: 编译失败 `cannot find 'CaptionRenderer' in scope`

- [ ] **Step 3: 写实现**

```swift
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// 字幕渲染结果：PNG 数据 + 实际像素尺寸（供 CaptionLayout 落位）。
public struct CaptionImage: Equatable, Sendable {
    public let pngData: Data
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(pngData: Data, pixelWidth: Int, pixelHeight: Int) {
        self.pngData = pngData; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }
}

/// 用 macOS 原生（系统苹方字体）把台词渲染成透明 PNG。
/// ⚠️ 必须用 NSBitmapImageRep 显式像素渲染，绝不能用 NSImage.lockFocus（会按 Retina 2× 放大）。
public enum CaptionRenderer {
    public enum RenderError: Error { case contextCreationFailed, pngEncodingFailed, unsupportedPlatform }

    /// - Parameters:
    ///   - text: 台词文本
    ///   - canvasWidth: 画布像素宽（一般取成片宽度的 ~90%）
    ///   - withBackdrop: 是否画半透明圆角底衬（none/blur 模式 true；solid 模式底衬由 ffmpeg 字幕条提供，传 false）
    ///   - fontSize: 字号像素
    public static func render(text: String,
                              canvasWidth: Int,
                              withBackdrop: Bool,
                              fontSize: CGFloat = 56) throws -> CaptionImage {
        #if canImport(AppKit)
        let sidePadding: CGFloat = 28
        let vPadding: CGFloat = 18
        let maxTextWidth = max(1, CGFloat(canvasWidth) - sidePadding * 2)

        let font = NSFont(name: "PingFangSC-Semibold", size: fontSize)
            ?? NSFont.boldSystemFont(ofSize: fontSize)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 4

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black,
            .strokeWidth: -2.0,                 // 负值 = 描边 + 填充
            .paragraphStyle: paragraph,
            .shadow: shadow
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)

        // boundingRect 量真实换行后尺寸（size() 会低估宽度导致裁切）
        let bounds = attributed.boundingRect(
            with: NSSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let textH = ceil(bounds.height)

        let canvasW = canvasWidth
        let canvasH = Int(ceil(textH + vPadding * 2))

        // 显式像素 1:1 bitmap（关键：避免 Retina 2×）
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: canvasW,
            pixelsHigh: canvasH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { throw RenderError.contextCreationFailed }
        rep.size = NSSize(width: canvasW, height: canvasH)   // 1 point = 1 pixel

        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            throw RenderError.contextCreationFailed
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high

        ctx.cgContext.clear(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))  // 透明背景

        if withBackdrop {
            let inset: CGFloat = 6
            let pillRect = NSRect(x: inset, y: inset,
                                  width: CGFloat(canvasW) - inset * 2,
                                  height: CGFloat(canvasH) - inset * 2)
            let pill = NSBezierPath(roundedRect: pillRect, xRadius: 14, yRadius: 14)
            NSColor(white: 0, alpha: 0.55).setFill()
            pill.fill()
        }

        let textRect = NSRect(
            x: sidePadding,
            y: (CGFloat(canvasH) - textH) / 2,
            width: maxTextWidth,
            height: textH
        )
        attributed.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])

        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw RenderError.pngEncodingFailed
        }
        return CaptionImage(pngData: png, pixelWidth: canvasW, pixelHeight: canvasH)
        #else
        throw RenderError.unsupportedPlatform
        #endif
    }

    /// 渲染并写文件，返回尺寸信息。
    @discardableResult
    public static func renderToFile(text: String, canvasWidth: Int, withBackdrop: Bool,
                                    fontSize: CGFloat = 56, to url: URL) throws -> CaptionImage {
        let image = try render(text: text, canvasWidth: canvasWidth, withBackdrop: withBackdrop, fontSize: fontSize)
        try image.pngData.write(to: url)
        return image
    }
}
```

- [ ] **Step 4: 登记 pbxproj + 跑测试确认通过**

Run: `swift test --filter CaptionRendererTests`
Expected: PASS（3 tests）。若 `pixelWidth == 1800` 之类则说明触发了 2× 路径——检查是否误用 lockFocus。
Run: `grep -c "CaptionRenderer.swift" MixCut.xcodeproj/project.pbxproj`
Expected: `4`

- [ ] **Step 5: 提交**

```bash
git add Sources/MixCutCore/CaptionRenderer.swift Tests/MixCutCoreTests/CaptionRendererTests.swift MixCut.xcodeproj/project.pbxproj
git commit -m "feat(dubbing): P4 CaptionRenderer 原生渲染透明字幕PNG(显式像素防2×)"
```

---

### Task 4: DubSegmentGraph（单分镜中间片 filter_complex 构建）

**Files:**
- Create: `Sources/MixCutCore/DubSegmentGraph.swift`
- Test: `Tests/MixCutCoreTests/DubSegmentGraphTests.swift`
- Modify: `MixCut.xcodeproj/project.pbxproj`（登记 Core 文件）

**Interfaces:**
- Consumes: `SubtitleMaskMode`（Task 1）、`PixelRect`（Task 2）
- Produces:
  - `struct DubSegmentGraph: Equatable, Sendable { let filterComplex: String; let videoMapLabel: String; let audioMapLabel: String }`
  - `enum DubSegmentGraphBuilder { static func build(mode: SubtitleMaskMode, startFrame: Int, endFrame: Int, fps: Double, outputWidth: Int, outputHeight: Int, maskPixel: PixelRect, captionOrigin: (x: Int, y: Int)?, captionInputIndex: Int, keepOriginalAudio: Bool, dubAudioInputIndex: Int, freezePadFrames: Int, trailingSilence: Double) -> DubSegmentGraph }`
- 约定输入顺序由调用方保证：input 0 = 源视频；caption PNG 放在 `captionInputIndex`；dub m4a 放在 `dubAudioInputIndex`。`videoMapLabel`/`audioMapLabel` 恒为 `[vout]`/`[aout]`。

> 注：本任务的 filter 字符串已用内置 ffmpeg 实测被接受（blur/solid 两图均 exit 0 出有效 mp4）。

- [ ] **Step 1: 写失败测试**

```swift
import Testing
@testable import MixCutCore

@Suite("DubSegmentGraph")
struct DubSegmentGraphTests {
    private func blurDubbed() -> DubSegmentGraph {
        DubSegmentGraphBuilder.build(
            mode: .blur,
            startFrame: 15, endFrame: 75, fps: 30,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 1536, width: 1080, height: 230),
            captionOrigin: (x: 240, y: 1601),
            captionInputIndex: 1,
            keepOriginalAudio: false,
            dubAudioInputIndex: 2,
            freezePadFrames: 0,
            trailingSilence: 0.2
        )
    }

    @Test("恒定输出标签")
    func mapLabels() {
        let g = blurDubbed()
        #expect(g.videoMapLabel == "[vout]")
        #expect(g.audioMapLabel == "[aout]")
    }

    @Test("blur 模式含 split/crop/boxblur/overlay 回贴")
    func blurContainsBoxblur() {
        let g = blurDubbed()
        #expect(g.filterComplex.contains("split=2"))
        #expect(g.filterComplex.contains("crop=1080:230:0:1536"))
        #expect(g.filterComplex.contains("boxblur=20"))
        #expect(g.filterComplex.contains("overlay=0:1536[masked]"))
    }

    @Test("精确切片 + 9:16 标准化")
    func cutAndNormalize() {
        let g = blurDubbed()
        #expect(g.filterComplex.contains("trim=start_frame=15:end_frame=75,setpts=PTS-STARTPTS"))
        #expect(g.filterComplex.contains("scale=1080:1920:force_original_aspect_ratio=decrease"))
        #expect(g.filterComplex.contains("setsar=1,fps=30[base]"))
    }

    @Test("叠加字幕 PNG（用 captionInputIndex 与 captionOrigin）")
    func overlaysCaption() {
        let g = blurDubbed()
        #expect(g.filterComplex.contains("[masked][1:v]overlay=240:1601[capped]"))
    }

    @Test("非锁定段从 dubAudioInputIndex 取音轨 + trailingSilence 补静音")
    func dubbedAudioWithSilence() {
        let g = blurDubbed()
        #expect(g.filterComplex.contains("[2:a]aresample=44100"))
        #expect(g.filterComplex.contains("apad=pad_dur=0.200[aout]"))
    }

    @Test("solid 模式用 drawbox 实色条")
    func solidUsesDrawbox() {
        let g = DubSegmentGraphBuilder.build(
            mode: .solid, startFrame: 0, endFrame: 60, fps: 30,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 1536, width: 1080, height: 230),
            captionOrigin: (x: 240, y: 1601), captionInputIndex: 1,
            keepOriginalAudio: false, dubAudioInputIndex: 2,
            freezePadFrames: 0, trailingSilence: 0)
        #expect(g.filterComplex.contains("drawbox=x=0:y=1536:w=1080:h=230:color=0x1A1A1A@1.0:t=fill[masked]"))
        #expect(g.filterComplex.contains("[2:a]aresample=44100,loudnorm=I=-16:TP=-1.5:LRA=11[aout]"))
    }

    @Test("none 模式不遮挡（null 透传）")
    func noneModePassesThrough() {
        let g = DubSegmentGraphBuilder.build(
            mode: .none, startFrame: 0, endFrame: 60, fps: 30,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 1536, width: 1080, height: 230),
            captionOrigin: (x: 240, y: 1601), captionInputIndex: 1,
            keepOriginalAudio: false, dubAudioInputIndex: 2,
            freezePadFrames: 0, trailingSilence: 0)
        #expect(g.filterComplex.contains("[base]null[masked]"))
        #expect(!g.filterComplex.contains("boxblur"))
        #expect(!g.filterComplex.contains("drawbox"))
    }

    @Test("锁定段：用原音轨 atrim + 不叠字幕")
    func lockedKeepsOriginalAudioNoCaption() {
        let g = DubSegmentGraphBuilder.build(
            mode: .none, startFrame: 30, endFrame: 90, fps: 30,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 1536, width: 1080, height: 230),
            captionOrigin: nil, captionInputIndex: 1,
            keepOriginalAudio: true, dubAudioInputIndex: 2,
            freezePadFrames: 0, trailingSilence: 0)
        #expect(g.filterComplex.contains("[0:a]atrim=start=1.00000:end=3.00000"))
        #expect(!g.filterComplex.contains("overlay=240"))     // 无字幕叠加
        #expect(g.filterComplex.contains("[masked]null[vout]"))
    }

    @Test("freezePadFrames>0 用 tpad 定格")
    func freezePadUsesTpad() {
        let g = DubSegmentGraphBuilder.build(
            mode: .blur, startFrame: 0, endFrame: 60, fps: 30,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 1536, width: 1080, height: 230),
            captionOrigin: (x: 240, y: 1601), captionInputIndex: 1,
            keepOriginalAudio: false, dubAudioInputIndex: 2,
            freezePadFrames: 9, trailingSilence: 0)
        #expect(g.filterComplex.contains("tpad=stop_mode=clone:stop_duration=0.300[vout]"))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter DubSegmentGraphTests`
Expected: 编译失败 `cannot find 'DubSegmentGraphBuilder' in scope`

- [ ] **Step 3: 写实现**

```swift
import Foundation

/// 单分镜中间片的 ffmpeg 滤镜图（纯字符串，导出服务直接拼进命令）。
public struct DubSegmentGraph: Equatable, Sendable {
    public let filterComplex: String
    public let videoMapLabel: String   // 恒 "[vout]"
    public let audioMapLabel: String   // 恒 "[aout]"

    public init(filterComplex: String, videoMapLabel: String, audioMapLabel: String) {
        self.filterComplex = filterComplex
        self.videoMapLabel = videoMapLabel
        self.audioMapLabel = audioMapLabel
    }
}

/// 构建「切片 → 9:16 标准化 → 遮挡旧字幕 → 叠新字幕 → 换音轨 → 定格/补静音」滤镜图。
/// 输入约定：input 0 = 源视频；caption PNG = captionInputIndex；dub m4a = dubAudioInputIndex。
public enum DubSegmentGraphBuilder {
    private static let loudnorm = "loudnorm=I=-16:TP=-1.5:LRA=11"

    public static func build(
        mode: SubtitleMaskMode,
        startFrame: Int, endFrame: Int, fps: Double,
        outputWidth: Int, outputHeight: Int,
        maskPixel: PixelRect,
        captionOrigin: (x: Int, y: Int)?,
        captionInputIndex: Int,
        keepOriginalAudio: Bool,
        dubAudioInputIndex: Int,
        freezePadFrames: Int,
        trailingSilence: Double
    ) -> DubSegmentGraph {
        let w = outputWidth, h = outputHeight
        let fpsInt = Int(fps.rounded())
        var parts: [String] = []

        // 1) 视频：精确切片 + 9:16 标准化 → [base]
        parts.append(
            "[0:v]trim=start_frame=\(startFrame):end_frame=\(endFrame),setpts=PTS-STARTPTS," +
            "scale=\(w):\(h):force_original_aspect_ratio=decrease," +
            "pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2:black,setsar=1,fps=\(fpsInt)[base]"
        )

        // 2) 遮挡旧字幕 → [masked]
        let mx = maskPixel.x, my = maskPixel.y, mw = maskPixel.width, mh = maskPixel.height
        switch mode {
        case .none:
            parts.append("[base]null[masked]")
        case .blur:
            parts.append("[base]split=2[mb0][mb1]")
            parts.append("[mb1]crop=\(mw):\(mh):\(mx):\(my),boxblur=20:1[mbb]")
            parts.append("[mb0][mbb]overlay=\(mx):\(my)[masked]")
        case .solid:
            parts.append("[base]drawbox=x=\(mx):y=\(my):w=\(mw):h=\(mh):color=0x1A1A1A@1.0:t=fill[masked]")
        case .dim:
            parts.append("[base]drawbox=x=\(mx):y=\(my):w=\(mw):h=\(mh):color=0x000000@0.5:t=fill[masked]")
        }

        // 3) 叠新字幕 PNG → [capped]（无字幕则透传 [masked]）
        let videoBeforePad: String
        if let origin = captionOrigin {
            parts.append("[masked][\(captionInputIndex):v]overlay=\(origin.x):\(origin.y)[capped]")
            videoBeforePad = "capped"
        } else {
            videoBeforePad = "masked"
        }

        // 4) 末尾定格补帧 → [vout]
        if freezePadFrames > 0 {
            let dur = Double(freezePadFrames) / fps
            parts.append("[\(videoBeforePad)]tpad=stop_mode=clone:stop_duration=\(String(format: "%.3f", dur))[vout]")
        } else {
            parts.append("[\(videoBeforePad)]null[vout]")
        }

        // 5) 音频 → [aout]
        if keepOriginalAudio {
            let aStart = Double(startFrame) / fps
            let aEnd = Double(endFrame) / fps
            parts.append(
                "[0:a]atrim=start=\(String(format: "%.5f", aStart)):end=\(String(format: "%.5f", aEnd))," +
                "asetpts=PTS-STARTPTS,aresample=44100,\(loudnorm)[aout]"
            )
        } else if trailingSilence > 0.001 {
            parts.append("[\(dubAudioInputIndex):a]aresample=44100,\(loudnorm),apad=pad_dur=\(String(format: "%.3f", trailingSilence))[aout]")
        } else {
            parts.append("[\(dubAudioInputIndex):a]aresample=44100,\(loudnorm)[aout]")
        }

        return DubSegmentGraph(filterComplex: parts.joined(separator: ";"),
                               videoMapLabel: "[vout]",
                               audioMapLabel: "[aout]")
    }
}
```

- [ ] **Step 4: 登记 pbxproj + 跑单元测试通过**

Run: `swift test --filter DubSegmentGraphTests`
Expected: PASS（全部）
Run: `grep -c "DubSegmentGraph.swift" MixCut.xcodeproj/project.pbxproj`
Expected: `4`

- [ ] **Step 5: 真 ffmpeg 验收（验证生成的滤镜图被内置 ffmpeg 接受）**

把下面脚本存为 `/tmp/dub_graph_accept.sh` 运行（用内置 ffmpeg 跑 blur+solid 两图，断言 exit 0 出有效 mp4）：

```bash
#!/bin/bash
set -e
FF=/Users/menggang/www/Mixed_cut/MixCut/Resources/bin/ffmpeg
cd /tmp
"$FF" -hide_banner -loglevel error -y -f lavfi -i "testsrc=size=720x1280:rate=30:duration=3" \
  -f lavfi -i "sine=frequency=440:duration=3" -c:v libx264 -c:a aac -shortest src.mp4
"$FF" -hide_banner -loglevel error -y -f lavfi -i "color=c=white@0.0:s=600x90,format=rgba" -frames:v 1 cap.png
# blur 图（对应 mode=.blur, captionOrigin 非空, trailingSilence>0）
"$FF" -hide_banner -loglevel error -y -i src.mp4 -i cap.png -i src.mp4 -filter_complex \
"[0:v]trim=start_frame=15:end_frame=75,setpts=PTS-STARTPTS,scale=720:1280:force_original_aspect_ratio=decrease,pad=720:1280:(ow-iw)/2:(oh-ih)/2:black,setsar=1,fps=30[base];[base]split=2[mb0][mb1];[mb1]crop=600:90:60:1100,boxblur=20:1[mbb];[mb0][mbb]overlay=60:1100[masked];[masked][1:v]overlay=60:1100[capped];[capped]null[vout];[2:a]aresample=44100,loudnorm=I=-16:TP=-1.5:LRA=11,apad=pad_dur=0.200[aout]" \
-map "[vout]" -map "[aout]" -c:v h264_videotoolbox -b:v 8000k -pix_fmt yuv420p -c:a aac out_blur.mp4
echo "blur OK"
# solid 图
"$FF" -hide_banner -loglevel error -y -i src.mp4 -i cap.png -i src.mp4 -filter_complex \
"[0:v]trim=start_frame=15:end_frame=75,setpts=PTS-STARTPTS,scale=720:1280:force_original_aspect_ratio=decrease,pad=720:1280:(ow-iw)/2:(oh-ih)/2:black,setsar=1,fps=30[base];[base]drawbox=x=60:y=1100:w=600:h=90:color=0x1A1A1A@1.0:t=fill[masked];[masked][1:v]overlay=60:1100[capped];[capped]null[vout];[2:a]aresample=44100,loudnorm=I=-16:TP=-1.5:LRA=11[aout]" \
-map "[vout]" -map "[aout]" -c:v h264_videotoolbox -b:v 8000k -pix_fmt yuv420p -c:a aac out_solid.mp4
echo "solid OK"
test -s out_blur.mp4 && test -s out_solid.mp4 && echo "ACCEPT PASS"
```

Run: `bash /tmp/dub_graph_accept.sh`
Expected: 末行打印 `ACCEPT PASS`

- [ ] **Step 6: 提交**

```bash
git add Sources/MixCutCore/DubSegmentGraph.swift Tests/MixCutCoreTests/DubSegmentGraphTests.swift MixCut.xcodeproj/project.pbxproj
git commit -m "feat(dubbing): P4 DubSegmentGraph 单分镜遮挡+烧字幕+换音轨滤镜图"
```

---

### Task 5: DubExportService（两阶段配音导出编排）

**Files:**
- Create: `MixCut/Services/Export/DubExportService.swift`
- Modify: `MixCut.xcodeproj/project.pbxproj`（登记 App 文件 + 挂进 Services/Export 分组）

**Interfaces:**
- Consumes:
  - `SubtitleMaskMode`、`PixelRect`、`CaptionLayout`、`CaptionRenderer`、`CaptionImage`、`DubSegmentGraph`、`DubSegmentGraphBuilder`（Task 1–4，同模块直接用）
  - `FFmpegRunner`（`MixCut/Services/VideoProcessing/FFmpegRunner.swift`）：`func run(arguments: [String], totalDuration: Double?, onProgress:) async throws -> Data`
  - `ExportConfig` / `ExportProgress` / `ExportError`（`MixCut/Services/Export/ExportService.swift`，复用，不改）
  - SwiftData：`MixScheme.orderedSegments`、`SchemeSegment.segment`、`Segment`（startFrame/endFrame/text/isVoiceLocked/hasHardSubtitle/maskRect/maskStyleRaw/video）、`Video`（localPath/fps/width/height）、`DubVariant.segmentDubs`、`SegmentDub`（segment/rewrittenText/audioFilePath/freezePadFrames/trailingSilence）
  - `FileHelper.tempDirectory`（`MixCut/Utilities/FileHelper.swift`）
- Produces:
  - `struct DubSegmentSpec: Sendable { videoPath, startFrame, endFrame, fps, captionText, hasHardSubtitle, maskStyleRaw, maskRect(SubtitleMaskRect), isVoiceLocked, dubAudioPath:String?, freezePadFrames, trailingSilence }`
  - `struct DubExportInput: Sendable { segments:[DubSegmentSpec]; maxWidth:Int; maxHeight:Int; static func from(scheme: MixScheme, variant: DubVariant) -> DubExportInput? }`（`@MainActor`）
  - `actor DubExportService { init(ffmpeg: FFmpegRunner = FFmpegRunner()); func export(input: DubExportInput, outputPath: String, config: ExportConfig, onProgress:) async throws }`

> 说明：本任务把 P1–P4 已建逻辑「接成一条能跑出成片的链子」。`from(scheme:variant:)` 的解析规则：按 `scheme.orderedSegments`，逐分镜——
> - `segment.isVoiceLocked == true` → 锁定段（保留原声原画原字幕，`dubAudioPath=nil`、`captionText=segment.text`、`maskStyleRaw` 任意，渲染时按 `.none` 处理且不叠字幕）。
> - 否则在 `variant.segmentDubs` 找该 segment 且 `audioFilePath != nil` 的 dub → 配音段（`captionText = dub.rewrittenText`，空则回退 `segment.text`；带 `freezePadFrames`/`trailingSilence`）。
> - 非锁定但找不到已生成 dub → **回退按锁定段处理**（保留原声原字幕，保证导出不中断），并 `MixLog.info` 记一条。

- [ ] **Step 1: 写实现（值类型 + 映射 + 两阶段导出）**

```swift
import Foundation

/// 单分镜导出规格（值类型，可跨 actor 传递）。
struct DubSegmentSpec: Sendable {
    let videoPath: String
    let startFrame: Int
    let endFrame: Int
    let fps: Double
    let captionText: String
    let hasHardSubtitle: Bool
    let maskStyleRaw: String
    let maskRect: SubtitleMaskRect
    let isVoiceLocked: Bool
    let dubAudioPath: String?      // 配音段 m4a；锁定/回退段为 nil
    let freezePadFrames: Int
    let trailingSilence: Double
}

/// 配音导出输入（整条成片）。
struct DubExportInput: Sendable {
    let segments: [DubSegmentSpec]
    let maxWidth: Int
    let maxHeight: Int

    /// 从某方案 + 某版配音解析出导出输入（必须在 @MainActor 调用）。
    @MainActor
    static func from(scheme: MixScheme, variant: DubVariant) -> DubExportInput? {
        let ordered = scheme.orderedSegments
        guard !ordered.isEmpty else { return nil }

        // 该版配音里：segment.id -> 已生成的 SegmentDub
        var dubBySegment: [UUID: SegmentDub] = [:]
        for dub in variant.segmentDubs {
            guard let seg = dub.segment, dub.audioFilePath != nil else { continue }
            dubBySegment[seg.id] = dub
        }

        var specs: [DubSegmentSpec] = []
        var maxW = 0, maxH = 0
        for schemeSeg in ordered {
            guard let segment = schemeSeg.segment,
                  let video = segment.video,
                  FileManager.default.fileExists(atPath: video.localPath) else { continue }

            let fps = video.fps > 0 ? video.fps : 30
            maxW = max(maxW, video.width)
            maxH = max(maxH, video.height)

            if segment.isVoiceLocked {
                specs.append(DubSegmentSpec(
                    videoPath: video.localPath, startFrame: segment.startFrame, endFrame: segment.endFrame,
                    fps: fps, captionText: segment.text, hasHardSubtitle: false, maskStyleRaw: segment.maskStyleRaw,
                    maskRect: segment.maskRect, isVoiceLocked: true, dubAudioPath: nil,
                    freezePadFrames: 0, trailingSilence: 0))
            } else if let dub = dubBySegment[segment.id],
                      let audioPath = dub.audioFilePath,
                      FileManager.default.fileExists(atPath: audioPath) {
                let caption = dub.rewrittenText.isEmpty ? segment.text : dub.rewrittenText
                specs.append(DubSegmentSpec(
                    videoPath: video.localPath, startFrame: segment.startFrame, endFrame: segment.endFrame,
                    fps: fps, captionText: caption, hasHardSubtitle: segment.hasHardSubtitle, maskStyleRaw: segment.maskStyleRaw,
                    maskRect: segment.maskRect, isVoiceLocked: false, dubAudioPath: audioPath,
                    freezePadFrames: dub.freezePadFrames, trailingSilence: dub.trailingSilence))
            } else {
                // 非锁定但无已生成配音 → 回退保留原声原字幕，保证导出不中断
                MixLog.info("分镜 \(segment.segmentIndex) 无已生成配音，回退原声导出")
                specs.append(DubSegmentSpec(
                    videoPath: video.localPath, startFrame: segment.startFrame, endFrame: segment.endFrame,
                    fps: fps, captionText: segment.text, hasHardSubtitle: false, maskStyleRaw: segment.maskStyleRaw,
                    maskRect: segment.maskRect, isVoiceLocked: true, dubAudioPath: nil,
                    freezePadFrames: 0, trailingSilence: 0))
            }
        }
        guard !specs.isEmpty else { return nil }
        return DubExportInput(segments: specs, maxWidth: maxW, maxHeight: maxH)
    }
}

/// 两阶段配音导出：逐分镜中间片 → concat 拼接。现有普通导出 ExportService 不受影响。
actor DubExportService {
    private let ffmpeg: FFmpegRunner

    init(ffmpeg: FFmpegRunner = FFmpegRunner()) {
        self.ffmpeg = ffmpeg
    }

    func export(
        input: DubExportInput,
        outputPath: String,
        config: ExportConfig = ExportConfig(),
        onProgress: (@Sendable (ExportProgress) -> Void)? = nil
    ) async throws {
        guard !input.segments.isEmpty else { throw ExportError.noSegments }

        // 输出分辨率（9:16，偶数）
        let (outW, outH) = Self.resolution(config: config, maxWidth: input.maxWidth, maxHeight: input.maxHeight)

        // 临时工作目录
        let workDir = FileHelper.tempDirectory.appendingPathComponent("dubexport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        var intermediatePaths: [String] = []
        let total = input.segments.count

        // 阶段一：逐分镜中间片
        for (i, spec) in input.segments.enumerated() {
            onProgress?(ExportProgress(phase: .cutting,
                                       progress: Double(i) / Double(total) * 0.85,
                                       description: "处理分镜 \(i + 1)/\(total)…"))

            let interURL = workDir.appendingPathComponent(String(format: "seg_%03d.mp4", i))
            try await renderSegment(spec: spec, index: i, outW: outW, outH: outH,
                                    workDir: workDir, config: config, outputPath: interURL.path)
            intermediatePaths.append(interURL.path)
        }

        // 阶段二：concat 解复用器无损拼接
        onProgress?(ExportProgress(phase: .concatenating, progress: 0.9, description: "拼接成片…"))
        try await concatCopy(paths: intermediatePaths, workDir: workDir, outputPath: outputPath)

        onProgress?(ExportProgress(phase: .completed, progress: 1.0, description: "配音导出完成"))
    }

    // MARK: - 单分镜中间片

    private func renderSegment(spec: DubSegmentSpec, index: Int, outW: Int, outH: Int,
                               workDir: URL, config: ExportConfig, outputPath: String) async throws {
        let mode = spec.isVoiceLocked
            ? .none
            : SubtitleMaskMode.from(hasHardSubtitle: spec.hasHardSubtitle, maskStyleRaw: spec.maskStyleRaw)
        let maskPixel = PixelRect.from(spec.maskRect, outputWidth: outW, outputHeight: outH)

        // 字幕 PNG（锁定段不叠字幕）
        var captionOrigin: (x: Int, y: Int)? = nil
        var captionInputIndex = 1
        var dubAudioInputIndex = 1
        var extraInputs: [String] = []   // 按顺序追加在源视频之后

        let keepOriginalAudio = spec.isVoiceLocked || spec.dubAudioPath == nil

        if !spec.isVoiceLocked, !spec.captionText.isEmpty {
            let canvasW = max(2, Int(Double(outW) * 0.9))
            let withBackdrop = (mode != .solid)
            let pngURL = workDir.appendingPathComponent(String(format: "cap_%03d.png", index))
            let img = try CaptionRenderer.renderToFile(
                text: spec.captionText, canvasWidth: canvasW, withBackdrop: withBackdrop, to: pngURL)
            captionOrigin = CaptionLayout.overlayOrigin(
                outputWidth: outW, outputHeight: outH, maskRect: spec.maskRect,
                captionWidth: img.pixelWidth, captionHeight: img.pixelHeight)
            extraInputs.append(pngURL.path)
            captionInputIndex = 1
            dubAudioInputIndex = 2
        } else {
            // 无字幕：dub 音轨（若有）紧跟源视频
            dubAudioInputIndex = 1
        }

        if !keepOriginalAudio, let dubPath = spec.dubAudioPath {
            extraInputs.append(dubPath)
        }

        let graph = DubSegmentGraphBuilder.build(
            mode: mode,
            startFrame: spec.startFrame, endFrame: spec.endFrame, fps: spec.fps,
            outputWidth: outW, outputHeight: outH,
            maskPixel: maskPixel,
            captionOrigin: captionOrigin,
            captionInputIndex: captionInputIndex,
            keepOriginalAudio: keepOriginalAudio,
            dubAudioInputIndex: dubAudioInputIndex,
            freezePadFrames: spec.freezePadFrames,
            trailingSilence: spec.trailingSilence)

        var args: [String] = ["-y", "-i", spec.videoPath]
        for input in extraInputs { args += ["-i", input] }
        args += ["-filter_complex", graph.filterComplex,
                 "-map", graph.videoMapLabel, "-map", graph.audioMapLabel]

        // 统一硬件编码（中间片参数必须一致，阶段二才能 -c copy）
        let bitrate = config.quality.videoBitrateKbps(for: config.codec)
        args += ["-c:v", "h264_videotoolbox", "-b:v", "\(bitrate)k", "-maxrate", "\(bitrate * 2)k",
                 "-tag:v", "avc1", "-allow_sw", "1", "-pix_fmt", "yuv420p",
                 "-c:a", "aac", "-b:a", "192k", "-ar", "44100",
                 "-movflags", "+faststart", outputPath]

        _ = try await ffmpeg.run(arguments: args, totalDuration: nil, onProgress: nil)
    }

    // MARK: - 阶段二拼接

    private func concatCopy(paths: [String], workDir: URL, outputPath: String) async throws {
        let listURL = workDir.appendingPathComponent("list.txt")
        let body = paths.map { "file '\($0)'" }.joined(separator: "\n") + "\n"
        try body.write(to: listURL, atomically: true, encoding: .utf8)

        let args = ["-y", "-f", "concat", "-safe", "0", "-i", listURL.path,
                    "-c", "copy", "-movflags", "+faststart", outputPath]
        _ = try await ffmpeg.run(arguments: args, totalDuration: nil, onProgress: nil)
    }

    // MARK: - 分辨率

    private static func resolution(config: ExportConfig, maxWidth: Int, maxHeight: Int) -> (Int, Int) {
        switch config.resolution {
        case .original:
            let w = maxWidth > 0 ? (maxWidth + 1) / 2 * 2 : 1080
            let h = maxHeight > 0 ? (maxHeight + 1) / 2 * 2 : 1920
            return (w, h)
        case .p1080: return (1080, 1920)
        case .p720:  return (720, 1280)
        case .p480:  return (480, 854)
        }
    }
}
```

- [ ] **Step 2: 登记 pbxproj（App 文件）+ 编译 App**

Run:
```bash
xcodebuild -project MixCut.xcodeproj -scheme MixCut -configuration Debug build 2>&1 | tail -20
```
Expected: `BUILD SUCCEEDED`
Run: `grep -c "DubExportService.swift" MixCut.xcodeproj/project.pbxproj`
Expected: `3` 或 `4`（含分组挂载）

- [ ] **Step 3: 提交**

```bash
git add MixCut/Services/Export/DubExportService.swift MixCut.xcodeproj/project.pbxproj
git commit -m "feat(dubbing): P4 DubExportService 两阶段配音导出编排"
```

- [ ] **Step 4: 端到端人工验证（必做，不能甩给用户）**

由控制者执行（此步无法纯 swift test，因依赖 app bundle 内 ffmpeg）：

1. 确认手上有一条真实素材视频（带硬字幕的旁白广告）+ 已在分镜库对某分镜跑过 P3 生成了 `SegmentDub.audioFilePath`（若无，可临时用千问 key 跑一遍 P3 生成一段 m4a）。
2. 临时在调试入口（或在一个一次性 `#if DEBUG` 触发点）构造 `DubExportInput.from(scheme:variant:)` 并调用 `DubExportService().export(input:outputPath: ~/Desktop/dub_test.mp4)`。
3. 用内置 ffprobe 校验输出：
   ```bash
   FP=/Users/menggang/www/Mixed_cut/MixCut/Resources/bin/ffprobe
   "$FP" -v error -select_streams v -show_entries stream=codec_name,width,height -of default=nk=1 ~/Desktop/dub_test.mp4
   "$FP" -v error -show_entries format=duration -of csv=p=0 ~/Desktop/dub_test.mp4
   ```
   Expected: `h264` + 9:16 尺寸（如 1080 / 1920）；时长 ≈ 各分镜时长之和（含定格补帧）。
4. **肉眼播放 `~/Desktop/dub_test.mp4` 确认**：
   - 旧硬字幕被 100% 遮住（blur 段模糊不可读；solid 段实色条完全盖住）；
   - 新台词字幕清晰居中、在字幕带位置、无飘出画面（验证非 2× 落点）；
   - 配音段是新音色、对得上画面长度；锁定段（如有）保留原声原画原字幕；
   - 段与段衔接无黑帧/无错位。
5. 截图/录屏留证后，删除临时调试入口。

> P5 才接入「分镜库选音色 + 裂变 + 方案生成音色统一/混用开关 + 组合引擎消费变体」的正式 UI；本计划只保证「给定一版配音，能正确导出成片」。

---

## Self-Review

**1. Spec 覆盖**（对照 memory `project_subtitle_burn` + 用户 P4 诉求）：
- 三种情况遮挡 → `SubtitleMaskMode`(.none/.blur/.solid/.dim) + `DubSegmentGraphBuilder`（Task 1、4）✅
- 100% 遮住旧字幕 → blur 区域模糊回贴 / solid `drawbox @1.0:t=fill` 实色条（实测出片）✅
- 原生渲染字幕 PNG、系统苹方、防 2× → `CaptionRenderer` + 单测断言 `pixelWidth==canvasWidth`（Task 3）✅
- 两阶段导出、普通导出不动 → `DubExportService`（阶段一中间片 + 阶段二 concat copy），`ExportService` 零改动（Task 5）✅
- 明星锁定段保留原声原画原字幕 → `isVoiceLocked` 走 `.none` + `keepOriginalAudio` + 不叠字幕（Task 4、5）✅
- 定格补帧 / 末尾静音对齐 → 复用 P3 `freezePadFrames`/`trailingSilence`，graph 用 `tpad`/`apad`（Task 4）✅
- 纯逻辑可测 → MaskMode/Layout/Renderer/Graph 全 `swift test`（Task 1–4）✅
- 内置 ffmpeg 滤镜可用性 → 已实测 blur/solid 图 + concat copy 全 exit 0 ✅

**2. 占位符扫描**：无 TBD/TODO；每个改码步骤含完整代码与确切命令/期望输出。✅

**3. 类型一致性**：`SubtitleMaskMode`/`PixelRect`/`CaptionImage`/`CaptionLayout.overlayOrigin`/`DubSegmentGraph`/`DubSegmentGraphBuilder.build` 签名在定义任务与 Task 5 消费处逐一对齐；输入序号约定（源视频=0、caption=captionInputIndex、dub=dubAudioInputIndex）在 graph 与 service 一致；`videoMapLabel`/`audioMapLabel` 恒 `[vout]`/`[aout]`。✅

> **已知后续项（不属本计划，留给 P5/执行期）**：①`from(scheme:variant:)` 的真实触发 UI 在 P5；②锁定段若源无音轨会失败（口播段按定义有音轨，暂不处理）；③若实测 concat `-c copy` 在某些素材上时间戳异常，阶段二回退为 `concat` filter 重编码（执行期调整，非计划阻塞）。
