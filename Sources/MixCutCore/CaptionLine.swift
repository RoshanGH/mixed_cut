import Foundation

/// 一个带时间的字（供逐句字幕编辑器"按时间重分组"用）。
public struct TimedChar: Codable, Hashable, Sendable {
    public var ch: String
    public var end: Double   // 该字结束时间（相对分镜起点秒）
    public init(ch: String, end: Double) {
        self.ch = ch; self.end = end
    }
}

/// 一行逐句字幕：文本（原始，含标点；显示时另行 stripPunctuation）+ 相对分镜起点的秒时间窗。
/// `chars` 存该句每个字的时间，供编辑器把分界当"时间"拖动、字随时间在相邻句之间迁移/合并。
/// 导出只用 text/start/end；chars 仅编辑器用。
public struct CaptionLine: Codable, Hashable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public var chars: [TimedChar]

    public init(text: String, start: Double, end: Double, chars: [TimedChar] = []) {
        self.text = text
        self.start = start
        self.end = end
        self.chars = chars
    }
}
