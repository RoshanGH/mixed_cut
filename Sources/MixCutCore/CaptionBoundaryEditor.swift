import Foundation

/// 逐句字幕"联动分界"编辑（纯函数、可单测）。
/// 分界 = 相邻两句之间的时间点；把它当时间拖动，字按各自时间在两句间迁移；
/// 右句被吃满 → 合并删除；不允许把左句掏空。
public enum CaptionBoundaryEditor {

    /// 取一句的逐字时间；无 chars（旧数据）时按整句 text 在 [start,end] 均匀合成一份。
    public static func charsOf(_ line: CaptionLine) -> [TimedChar] {
        if !line.chars.isEmpty { return line.chars }
        let cs = Array(line.text)
        guard !cs.isEmpty else { return [] }
        let span = max(0.001, line.end - line.start)
        return cs.enumerated().map {
            TimedChar(ch: String($0.1), end: line.start + span * Double($0.0 + 1) / Double(cs.count))
        }
    }

    /// 移动第 i 句与第 i+1 句之间的分界到时间 t，返回新分区（保持字总量不变、顺序不变）。
    public static func moveBoundary(_ lines: [CaptionLine], after i: Int, to t: Double, minGap: Double = 0.05) -> [CaptionLine] {
        guard i >= 0, i + 1 < lines.count else { return lines }
        var out = lines
        // 分界最左不越过左句起点+gap（保左句非空），最右可推到右句止（吃满→合并）
        let b = min(max(t, out[i].start + minGap), out[i + 1].end)
        let merged = charsOf(out[i]) + charsOf(out[i + 1])
        guard !merged.isEmpty else { return lines }
        let left = merged.filter { $0.end <= b + 0.0005 }
        let right = merged.filter { $0.end > b + 0.0005 }
        if right.isEmpty {
            // 右句被吃满 → 合并删除，字全并入左句
            out[i].chars = merged
            out[i].text = merged.map(\.ch).joined()
            out[i].end = out[i + 1].end
            out.remove(at: i + 1)
        } else if left.isEmpty {
            return lines                                  // 不允许掏空左句
        } else {
            out[i].chars = left
            out[i].text = left.map(\.ch).joined()
            out[i].end = b
            out[i + 1].chars = right
            out[i + 1].text = right.map(\.ch).joined()
            out[i + 1].start = b
        }
        return out
    }
}
