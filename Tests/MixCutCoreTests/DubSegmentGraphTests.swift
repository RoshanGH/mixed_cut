import Testing
@testable import MixCutCore

@Suite("DubSegmentGraph")
struct DubSegmentGraphTests {
    private func cap(_ idx: Int = 1, _ x: Int = 240, _ y: Int = 1601, _ s: Double = 0, _ e: Double = 2) -> CaptionOverlay {
        CaptionOverlay(inputIndex: idx, x: x, y: y, start: s, end: e)
    }

    private func blurDubbed() -> DubSegmentGraph {
        DubSegmentGraphBuilder.build(
            mode: .blur,
            startFrame: 15, endFrame: 75, fps: 30,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 1536, width: 1080, height: 230),
            captions: [cap()],
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

    @Test("逐句叠字幕 PNG：单句 overlay + enable=between")
    func overlaysCaption() {
        let g = blurDubbed()
        #expect(g.filterComplex.contains("[masked][1:v]overlay=240:1601:enable='between(t,0.000,2.000)'[capped]"))
    }

    @Test("多句字幕：逐句 overlay 链式串联，各自 enable 时间窗")
    func multipleCaptionsChained() {
        let g = DubSegmentGraphBuilder.build(
            mode: .none, startFrame: 0, endFrame: 60, fps: 30,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 1536, width: 1080, height: 230),
            captions: [cap(1, 240, 1601, 0, 1), cap(2, 240, 1601, 1, 2)],
            keepOriginalAudio: false, dubAudioInputIndex: 3,
            freezePadFrames: 0, trailingSilence: 0)
        #expect(g.filterComplex.contains("[masked][1:v]overlay=240:1601:enable='between(t,0.000,1.000)'[cap0]"))
        #expect(g.filterComplex.contains("[cap0][2:v]overlay=240:1601:enable='between(t,1.000,2.000)'[capped]"))
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
            captions: [cap()],
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
            captions: [cap()],
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
            captions: [],
            keepOriginalAudio: true, dubAudioInputIndex: 2,
            freezePadFrames: 0, trailingSilence: 0)
        #expect(g.filterComplex.contains("[0:a]atrim=start=1.00000:end=3.00000"))
        #expect(!g.filterComplex.contains("overlay=240"))
        #expect(g.filterComplex.contains("[masked]null[vout]"))
        #expect(!g.filterComplex.contains("loudnorm"))
    }

    @Test("freezePadFrames>0 用 tpad 定格")
    func freezePadUsesTpad() {
        let g = DubSegmentGraphBuilder.build(
            mode: .blur, startFrame: 0, endFrame: 60, fps: 30,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 1536, width: 1080, height: 230),
            captions: [cap()],
            keepOriginalAudio: false, dubAudioInputIndex: 2,
            freezePadFrames: 9, trailingSilence: 0)
        #expect(g.filterComplex.contains("tpad=stop_mode=clone:stop_duration=0.300[vout]"))
    }

    @Test("锁定段即使传了 captions 也不叠字幕")
    func lockedIgnoresCaptions() {
        let g = DubSegmentGraphBuilder.build(
            mode: .none, startFrame: 0, endFrame: 60, fps: 30,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 1536, width: 1080, height: 230),
            captions: [cap()],
            keepOriginalAudio: true, dubAudioInputIndex: 2,
            freezePadFrames: 0, trailingSilence: 0)
        #expect(!g.filterComplex.contains("overlay=240:1601"))
        #expect(g.filterComplex.contains("[masked]null[vout]"))
    }

    @Test("dim 模式用半透明 drawbox")
    func dimUsesTranslucentDrawbox() {
        let g = DubSegmentGraphBuilder.build(
            mode: .dim, startFrame: 0, endFrame: 60, fps: 30,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 1536, width: 1080, height: 230),
            captions: [cap()],
            keepOriginalAudio: false, dubAudioInputIndex: 2,
            freezePadFrames: 0, trailingSilence: 0)
        #expect(g.filterComplex.contains("drawbox=x=0:y=1536:w=1080:h=230:color=0x000000@0.5:t=fill[masked]"))
    }
}

@Suite("DubSegmentGraph BGM 混音")
struct DubSegmentGraphBGMTests {

    @Test("提供 bgmInputIndex 时音轨为 voice+bgm amix")
    func mixesBGMWhenIndexProvided() {
        let g = DubSegmentGraphBuilder.build(
            mode: .none, startFrame: 30, endFrame: 90, fps: 30,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 0, width: 0, height: 0),
            captions: [],
            keepOriginalAudio: false, dubAudioInputIndex: 1,
            freezePadFrames: 0, trailingSilence: 0,
            bgmInputIndex: 2)
        let fc = g.filterComplex
        #expect(fc.contains("[1:a]aresample=44100"))
        #expect(fc.contains("[2:a]atrim=start=1.00000:end=3.00000"))
        #expect(fc.contains("volume=0.60"))
        #expect(fc.contains("amix=inputs=2:duration=first:normalize=0[aout]"))
    }

    @Test("bgmInputIndex 为 nil 时退化为纯人声（回归保护）")
    func noBGMFallsBackToVoiceOnly() {
        let g = DubSegmentGraphBuilder.build(
            mode: .none, startFrame: 30, endFrame: 90, fps: 30,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 0, width: 0, height: 0),
            captions: [],
            keepOriginalAudio: false, dubAudioInputIndex: 1,
            freezePadFrames: 0, trailingSilence: 0)
        let fc = g.filterComplex
        #expect(!fc.contains("amix"))
        #expect(fc.contains("[1:a]aresample=44100,loudnorm=I=-16:TP=-1.5:LRA=11[aout]"))
    }

    @Test("带 trailingSilence + BGM：人声有 apad 再与 BGM 混")
    func bgmWithTrailingSilence() {
        let g = DubSegmentGraphBuilder.build(
            mode: .none, startFrame: 0, endFrame: 60, fps: 30,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 0, width: 0, height: 0),
            captions: [],
            keepOriginalAudio: false, dubAudioInputIndex: 1,
            freezePadFrames: 0, trailingSilence: 0.5,
            bgmInputIndex: 2)
        let fc = g.filterComplex
        #expect(fc.contains("apad=pad_dur=0.500"))
        #expect(fc.contains("amix=inputs=2:duration=first:normalize=0[aout]"))
    }
}
