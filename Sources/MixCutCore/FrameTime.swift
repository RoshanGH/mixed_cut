import Foundation

/// 帧 ↔ 秒 ↔ 时间码 的换算。
///
/// 帧化重构的基石：分镜边界以「帧号」为唯一真相，秒只是 `帧号 / fps` 的精确派生值。
/// 所有「秒 → 帧」一律 round 到最近帧，消除浮点取整歧义（永不差帧）。
public enum FrameTime {

    /// 帧号 → 秒（精确落在帧栅格点）
    public static func seconds(frame: Int, fps: Double) -> Double {
        guard fps > 0 else { return 0 }
        return Double(frame) / fps
    }

    /// 秒 → 最近帧号（四舍五入；负数夹到 0）
    public static func frame(seconds: Double, fps: Double) -> Int {
        guard fps > 0, seconds > 0 else { return 0 }
        return Int((seconds * fps).rounded())
    }

    /// SMPTE 风格时间码：`时:分:秒:帧`（省略前导 0 小时则为 `分:秒:帧`）。
    ///
    /// 帧位按帧率进位（剪映式）：30fps → 帧位 0–29，60fps → 帧位 0–59。
    /// 非整数帧率（29.97/23.976）用四舍五入的整数帧率做进位基数（近似 non-drop-frame，够预览显示用）。
    public static func timecode(frame: Int, fps: Double) -> String {
        let f = max(0, frame)
        let rate = max(1, Int(fps.rounded()))
        let totalSeconds = f / rate
        let frames = f % rate
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d:%02d", hours, minutes, seconds, frames)
        }
        return String(format: "%02d:%02d:%02d", minutes, seconds, frames)
    }

    /// 时长帧数 → 秒数文案（如 "1.5s"），用于卡片角标等粗略显示
    public static func durationText(frames: Int, fps: Double) -> String {
        let secs = seconds(frame: frames, fps: fps)
        return String(format: "%.1fs", secs)
    }
}
