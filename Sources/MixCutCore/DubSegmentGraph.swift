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

/// 一条逐句字幕 overlay：PNG 输入序号 + 落位 + 相对分镜起点的时间窗（enable=between 用）。
public struct CaptionOverlay: Sendable, Equatable {
    public let inputIndex: Int
    public let x: Int
    public let y: Int
    public let start: Double
    public let end: Double
    public init(inputIndex: Int, x: Int, y: Int, start: Double, end: Double) {
        self.inputIndex = inputIndex; self.x = x; self.y = y; self.start = start; self.end = end
    }
}

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

/// 构建「切片 → 9:16 标准化 → 遮挡旧字幕 → 逐句叠新字幕 → 换音轨 → 定格/补静音」滤镜图。
/// 输入约定：input 0 = 源视频；每条 caption PNG = 其 CaptionOverlay.inputIndex；dub m4a = dubAudioInputIndex。
/// 逐句字幕：每句一个 overlay + `enable='between(t,起,止)'`（t=分镜内 0 起，由 trim/setpts 保证）。
/// 旧数据/整段兜底：调用方传 1 条 [0, 分镜时长] 的 CaptionOverlay 即等价整段全程。
public enum DubSegmentGraphBuilder {
    private static let loudnorm = "loudnorm=I=-16:TP=-1.5:LRA=11"
    /// trailingSilence 视为 0 的阈值（秒）
    private static let silenceEpsilon = 0.001
    /// 混音时 BGM 相对音量（人声为主、BGM 垫底）
    public static let bgmGain: Double = 0.6

    public static func build(
        mode: SubtitleMaskMode,
        startFrame: Int, endFrame: Int, fps: Double,
        outputWidth: Int, outputHeight: Int,
        maskPixel: PixelRect,
        captions: [CaptionOverlay],
        keepOriginalAudio: Bool,
        dubAudioInputIndex: Int,
        freezePadFrames: Int,
        trailingSilence: Double,
        bgmInputIndex: Int? = nil,
        vocalsSource: VocalsSource? = nil
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

        // 3) 逐句叠新字幕 PNG → [capped]（每句一个 overlay + enable=between；无字幕则透传 [masked]）
        // 锁定段（保留原声）一律不叠字幕，即使调用方误传了 captions
        let effectiveCaptions = keepOriginalAudio ? [] : captions
        let videoBeforePad: String
        if effectiveCaptions.isEmpty {
            videoBeforePad = "masked"
        } else {
            var prev = "masked"
            for (i, c) in effectiveCaptions.enumerated() {
                let out = (i == effectiveCaptions.count - 1) ? "capped" : "cap\(i)"
                parts.append(
                    "[\(prev)][\(c.inputIndex):v]overlay=\(c.x):\(c.y):" +
                    "enable='between(t,\(String(format: "%.3f", c.start)),\(String(format: "%.3f", c.end)))'[\(out)]"
                )
                prev = out
            }
            videoBeforePad = "capped"
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
            let padSuffix = trailingSilence > silenceEpsilon
                ? ",apad=pad_dur=\(String(format: "%.3f", trailingSilence))"
                : ""
            if let bgmIdx = bgmInputIndex {
                let aStart = Double(startFrame) / fps
                let aEnd = Double(endFrame) / fps
                parts.append("[\(dubAudioInputIndex):a]aresample=44100,\(loudnorm)\(padSuffix)[voice]")
                parts.append(
                    "[\(bgmIdx):a]atrim=start=\(String(format: "%.5f", aStart)):end=\(String(format: "%.5f", aEnd))," +
                    "asetpts=PTS-STARTPTS,aresample=44100,volume=\(String(format: "%.2f", Self.bgmGain))[bgmcut]"
                )
                parts.append("[voice][bgmcut]amix=inputs=2:duration=first:normalize=0[aout]")
            } else {
                parts.append("[\(dubAudioInputIndex):a]aresample=44100,\(loudnorm)\(padSuffix)[aout]")
            }
        }

        return DubSegmentGraph(filterComplex: parts.joined(separator: ";"),
                               videoMapLabel: "[vout]",
                               audioMapLabel: "[aout]")
    }
}
