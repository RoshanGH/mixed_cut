import Foundation

/// 对齐器需要的最小 word 结构（app 层用 ASRWord 映射进来）。
public struct AlignWord: Sendable {
    public let text: String
    public let start: Double
    public let end: Double
    public init(text: String, start: Double, end: Double) {
        self.text = text; self.start = start; self.end = end
    }
}

/// 把"改写台词"按标点切句，用配音 ASR（或比例）给每句配上 [start,end]。纯函数、可单测。
/// 规则见 spec §4.2：主策略=按去标点字符数比例分到"语音跨度"；有 words 时用字符顺序匹配精修边界。
public enum SentenceTimingAligner {

    private static let sentenceEnders: Set<Character> = ["。", "！", "？", "!", "?", ".", ";", "；", "\n"]
    private static let stripped: Set<Character> = ["，", ",", "、", "。", "！", "？", "!", "?", ".", ";", "；", " ", "\n", "\r", "\t", "…", "·", "：", ":"]

    /// 去标点/空白，返回纯字符数组（用于比例与匹配）。
    static func chars(_ s: String) -> [Character] { s.filter { !stripped.contains($0) } }

    /// 按句末标点/换行切句，返回每句原文（保留内部非句末标点；空/纯标点段丢弃）。
    static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in text {
            cur.append(ch)
            if sentenceEnders.contains(ch) {
                if !chars(cur).isEmpty { out.append(cur.trimmingCharacters(in: .whitespacesAndNewlines)) }
                cur = ""
            }
        }
        if !chars(cur).isEmpty { out.append(cur.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return out
    }

    public static func align(text: String, words: [AlignWord], audioDuration: Double, segmentDuration: Double) -> [CaptionLine] {
        let sentences = splitSentences(text)
        guard !sentences.isEmpty else { return [] }

        // 语音跨度：有 words 用 [首词.start, 末词.end]，否则 [0, audioDuration]
        let spanStart = words.first?.start ?? 0
        let spanEnd = max(spanStart + 0.01, words.last?.end ?? max(audioDuration, 0.01))

        // 主策略：按去标点字符数比例分配到跨度
        let counts = sentences.map { max(1, chars($0).count) }
        let total = counts.reduce(0, +)
        var lines: [CaptionLine] = []
        var acc = 0
        for (i, s) in sentences.enumerated() {
            let a = spanStart + (spanEnd - spanStart) * Double(acc) / Double(total)
            acc += counts[i]
            let b = spanStart + (spanEnd - spanStart) * Double(acc) / Double(total)
            lines.append(CaptionLine(text: s, start: a, end: b))
        }

        // 精修（有 words 时）
        if !words.isEmpty {
            lines = refine(lines: lines, sentences: sentences, words: words)
        }

        // 归一化后给每句填"每字时间"（供编辑器按时间重分组）：句内按字数均匀，句边界由 ASR 决定
        return normalize(lines, segmentDuration: segmentDuration).map(withCharTimes)
    }

    /// 给一行填充"每字时间"（句内按字数均匀分布在 [start,end]）。
    private static func withCharTimes(_ line: CaptionLine) -> CaptionLine {
        var l = line
        let cs = chars(line.text)
        guard !cs.isEmpty else { l.chars = []; return l }
        let span = max(0.001, line.end - line.start)
        l.chars = cs.enumerated().map { (k, c) in
            TimedChar(ch: String(c), end: line.start + span * Double(k + 1) / Double(cs.count))
        }
        return l
    }

    /// 阿拉伯数字 → 中文单字（逐位），让台词「69」能和 ASR 的「六十九」逐字匹配（跳过多余的「十」）。
    private static let digitCN: [Character: Character] = [
        "0": "〇", "1": "一", "2": "二", "3": "三", "4": "四",
        "5": "五", "6": "六", "7": "七", "8": "八", "9": "九",
    ]
    private static func fold(_ c: Character) -> Character { digitCN[c] ?? c }

    /// 字符级时间序列（一个多字 token 的 [start,end] 按字符线性内插；数字折叠成中文单字）。
    private static func charTimeline(_ words: [AlignWord]) -> [(Character, Double, Double)] {
        var seq: [(Character, Double, Double)] = []
        for wd in words {
            let cs = chars(wd.text)
            guard !cs.isEmpty else { continue }
            let dur = max(0, wd.end - wd.start) / Double(cs.count)
            for (k, c) in cs.enumerated() {
                seq.append((fold(c), wd.start + dur * Double(k), wd.start + dur * Double(k + 1)))
            }
        }
        return seq
    }

    /// 用配音 ASR 精修每句边界。
    /// 逐句贪心匹配字符时间线；匹配成功的句子作「锚点」，匹配失败的连续句子在相邻锚点之间
    /// 按字数插值分配时间——绝不让失败句保留会与邻居打架的旧比例值（否则会被挤成零宽度不显示）。
    private static func refine(lines: [CaptionLine], sentences: [String], words: [AlignWord]) -> [CaptionLine] {
        let tl = charTimeline(words)
        guard !tl.isEmpty else { return lines }
        let n = sentences.count
        var mStart = [Double?](repeating: nil, count: n)
        var mEnd = [Double?](repeating: nil, count: n)
        var ptr = 0
        for i in 0..<n {
            let sc = chars(sentences[i]).map(fold)
            guard !sc.isEmpty else { continue }
            var startT: Double? = nil, endT: Double? = nil
            var j = ptr
            var matched = 0
            while j < tl.count && matched < sc.count {
                if tl[j].0 == sc[matched] {
                    if matched == 0 { startT = tl[j].1 }
                    endT = tl[j].2
                    matched += 1
                }
                j += 1
            }
            if let s = startT, let e = endT, matched >= max(1, sc.count / 2) {
                mStart[i] = s
                mEnd[i] = max(s + 0.05, e)
                ptr = j
            }
        }

        // 语音跨度端点（给首尾未匹配句兜底）
        let spanStart = words.first?.start ?? lines.first?.start ?? 0
        let spanEnd = max(spanStart + 0.01, words.last?.end ?? lines.last?.end ?? spanStart + 0.01)

        var out = lines
        var i = 0
        while i < n {
            if let s = mStart[i], let e = mEnd[i] {
                out[i].start = s; out[i].end = e; i += 1; continue
            }
            // 收集一段连续未匹配 [i, k)，在前后锚点之间按字数插值
            var k = i
            while k < n && mStart[k] == nil { k += 1 }
            let leftAnchor = i > 0 ? (mEnd[i - 1] ?? spanStart) : spanStart
            let rightAnchor = k < n ? (mStart[k] ?? spanEnd) : spanEnd
            let hi = max(leftAnchor + 0.0001, rightAnchor)
            let width = hi - leftAnchor
            let counts = (i..<k).map { max(1, chars(sentences[$0]).count) }
            let totalC = counts.reduce(0, +)
            var accC = 0
            for (idx, s) in (i..<k).enumerated() {
                let a = leftAnchor + width * Double(accC) / Double(totalC)
                accC += counts[idx]
                let b = leftAnchor + width * Double(accC) / Double(totalC)
                out[s].start = a; out[s].end = b
            }
            i = k
        }
        return out
    }

    private static func normalize(_ lines: [CaptionLine], segmentDuration: Double) -> [CaptionLine] {
        var out = lines.sorted { $0.start < $1.start }
        for i in out.indices {
            out[i].start = min(max(0, out[i].start), segmentDuration)
            out[i].end = min(max(out[i].start + 0.05, out[i].end), segmentDuration)
            if i > 0, out[i].start < out[i - 1].end { out[i].start = out[i - 1].end }
            if out[i].end < out[i].start { out[i].end = out[i].start + 0.05 }
        }
        return out
    }
}
