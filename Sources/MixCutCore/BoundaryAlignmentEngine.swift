import Foundation

// MARK: - 纯输入数据结构（与 app 层类型解耦，便于 swift test）

/// 画面切换点（场景检测产出）
public struct SceneCut: Sendable, Equatable {
    /// 切换时间点（秒）
    public let time: Double
    /// 画面变化强度 0–1（FFmpeg scene_score）。越大表示前后两帧差异越剧烈（硬切镜）
    public let strength: Double

    public init(time: Double, strength: Double) {
        self.time = time
        self.strength = strength
    }
}

/// 静音/停顿段
public struct SilenceGap: Sendable, Equatable {
    public let start: Double
    public let end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var midpoint: Double { (start + end) / 2 }
}

/// ASR 句子时间区间
public struct SentenceSpan: Sendable, Equatable {
    public let start: Double
    public let end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

/// 边界对齐配置
public struct BoundaryAlignConfig: Sendable {
    /// 强切镜搜索窗（秒）：边界附近此范围内的强画面切换才考虑吸附
    public var sceneSearchRange: Double = 0.5
    /// 画面变化强度阈值：strength ≥ 此值才算「强切镜」（值越大越严格，只吸硬切）
    public var sceneStrengthThreshold: Double = 0.4
    /// 句子结束吸附窗（秒）：保证不在台词中间切
    public var sentenceSnapMaxOffset: Double = 0.8
    /// 静音段吸附窗（秒）
    public var silenceSearchRange: Double = 0.5
    /// 安全约束：单个边界最大移动距离（秒），超出则回退原切点
    public var maxBoundaryShift: Double = 1.5
    /// 安全约束：最小片段时长（秒）
    public var minSegmentDuration: Double = 1.0

    public init() {}
}

/// 边界落点的吸附来源（用于诊断/报告）
public enum BoundaryAnchor: String, Sendable {
    case scene      // 吸附到强画面切换点
    case sentence   // 吸附到句子结束
    case silence    // 吸附到静音停顿
    case original   // 未吸附，保留原切点
}

/// 单个边界的对齐结果
public struct BoundaryDecision: Sendable, Equatable {
    public let original: Double
    public let aligned: Double
    public let anchor: BoundaryAnchor

    public init(original: Double, aligned: Double, anchor: BoundaryAnchor) {
        self.original = original
        self.aligned = aligned
        self.anchor = anchor
    }
}

// MARK: - 边界对齐引擎（纯函数，单次带优先级择优）

/// 把语义/ASR 切点对齐到「画面 + 语音 + 编码」上最自然的落点。
///
/// 设计要点（取代旧的「四阶段串行覆盖」）：
/// - **单次择优**：每个边界只决策一次，按优先级在候选点中选最优，避免后一阶段把前一阶段对齐好的结果又推走。
/// - **强切镜优先**：只有画面变化强度达标（≥ sceneStrengthThreshold）的切换点才作为强吸附目标，
///   且搜索窗较大。这实现了「边缘画面突变大 → 贴齐切镜；画面平缓 → 保留语义切点」的直觉。
/// - **按帧量化**：最终边界吸到帧栅格 round(t·fps)/fps，消除导出时 ±1 帧的浮点抖动。
/// - **不做 I-frame 对齐**：导出走 trim 重新编码，任意帧可精确切，无需落在 I-frame 上
///   （旧实现的 I-frame 阶段反而把边界推离画面切换点，已移除）。
public enum BoundaryAlignmentEngine {

    /// 完整对齐流程，返回每个边界的决策（含吸附来源）
    public static func decide(
        boundaries: [Double],
        scenes: [SceneCut],
        silences: [SilenceGap],
        sentences: [SentenceSpan],
        duration: Double,
        fps: Double,
        config: BoundaryAlignConfig = BoundaryAlignConfig()
    ) -> [BoundaryDecision] {
        let original = boundaries.sorted()
        guard !original.isEmpty else { return [] }

        // 1) 逐边界单次择优
        var anchors: [BoundaryAnchor] = []
        var picked: [Double] = []
        for b in original {
            let (time, anchor) = chooseAnchor(
                for: b, scenes: scenes, silences: silences, sentences: sentences, config: config
            )
            picked.append(time)
            anchors.append(anchor)
        }

        // 2) 按帧栅格量化（消除 ±1 帧浮点毛刺）
        if fps > 0 {
            picked = picked.map { (($0 * fps).rounded() / fps) }
        }

        // 3) 安全约束（限幅 / 递增 / 最小时长 / clamp）
        picked = enforceConstraints(picked, original: original, duration: duration, config: config)

        // 4) 组装决策（若被约束回退，anchor 标记为 original）
        var decisions: [BoundaryDecision] = []
        for i in original.indices {
            let wasReverted = abs(picked[i] - original[i]) < 0.0005 && anchors[i] != .original
            let anchor = wasReverted ? BoundaryAnchor.original : anchors[i]
            decisions.append(BoundaryDecision(original: original[i], aligned: picked[i], anchor: anchor))
        }
        return decisions
    }

    /// 便捷入口：只取对齐后的边界数组
    public static func align(
        boundaries: [Double],
        scenes: [SceneCut],
        silences: [SilenceGap],
        sentences: [SentenceSpan],
        duration: Double,
        fps: Double,
        config: BoundaryAlignConfig = BoundaryAlignConfig()
    ) -> [Double] {
        decide(
            boundaries: boundaries, scenes: scenes, silences: silences,
            sentences: sentences, duration: duration, fps: fps, config: config
        ).map(\.aligned)
    }

    // MARK: - 优先级择优

    /// 为单个边界选择吸附落点。
    /// 优先级：强切镜 > 句子结束 > 静音停顿 > 原切点
    private static func chooseAnchor(
        for b: Double,
        scenes: [SceneCut],
        silences: [SilenceGap],
        sentences: [SentenceSpan],
        config: BoundaryAlignConfig
    ) -> (time: Double, anchor: BoundaryAnchor) {

        // ① 强切镜：变化强度达标且在搜索窗内，取最近
        let strongScenes = scenes.filter {
            $0.strength >= config.sceneStrengthThreshold && abs($0.time - b) <= config.sceneSearchRange
        }
        if let s = strongScenes.min(by: { abs($0.time - b) < abs($1.time - b) }) {
            return (s.time, .scene)
        }

        // ② 句子结束：保证不在台词中间切，取窗内最近的 endTime
        let nearEnds = sentences.map(\.end).filter { abs($0 - b) <= config.sentenceSnapMaxOffset }
        if let e = nearEnds.min(by: { abs($0 - b) < abs($1 - b) }) {
            return (e, .sentence)
        }

        // ③ 静音：落在静音段内→中点；否则附近最近静音段的中点
        if let containing = silences.first(where: { $0.start <= b && b <= $0.end }) {
            return (containing.midpoint, .silence)
        }
        let nearbySilence = silences.filter { abs($0.midpoint - b) <= config.silenceSearchRange }
        if let g = nearbySilence.min(by: { abs($0.midpoint - b) < abs($1.midpoint - b) }) {
            return (g.midpoint, .silence)
        }

        // ④ 原切点
        return (b, .original)
    }

    // MARK: - 安全约束

    private static func enforceConstraints(
        _ boundaries: [Double],
        original: [Double],
        duration: Double,
        config: BoundaryAlignConfig
    ) -> [Double] {
        var result = boundaries

        // 约束1：限制最大移动距离，超出则回退原切点
        for i in result.indices where i < original.count {
            if abs(result[i] - original[i]) > config.maxBoundaryShift {
                result[i] = original[i]
            }
        }

        // 约束2：保证边界严格递增
        if result.count > 1 {
            for i in 1..<result.count where result[i] <= result[i - 1] {
                result[i] = result[i - 1] + config.minSegmentDuration
            }
        }

        // 约束3：首尾保证最小片段时长
        if let first = result.first, first < config.minSegmentDuration {
            result[0] = config.minSegmentDuration
        }
        if duration > 0, let last = result.last, duration - last < config.minSegmentDuration {
            result[result.count - 1] = duration - config.minSegmentDuration
        }

        // 约束4：clamp 到视频时长范围内（保持数组长度不变）
        if duration > 0 {
            result = result.map { max(0.01, min($0, duration - 0.01)) }
        }

        return result
    }
}
