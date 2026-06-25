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
    /// trailingSilence 视为 0 的阈值（秒）
    private static let silenceEpsilon = 0.001
    /// 混音时 BGM 相对音量（人声为主、BGM 垫底）
    public static let bgmGain: Double = 0.6

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
        trailingSilence: Double,
        bgmInputIndex: Int? = nil
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
        // 锁定段（保留原声）一律不叠字幕，即使调用方误传了 captionOrigin
        let effectiveCaption = keepOriginalAudio ? nil : captionOrigin
        let videoBeforePad: String
        if let origin = effectiveCaption {
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
                "asetpts=PTS-STARTPTS,aresample=44100[aout]"
            )
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
