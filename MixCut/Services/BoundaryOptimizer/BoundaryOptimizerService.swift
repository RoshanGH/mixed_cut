import Foundation

/// 边界优化报告（诊断用）
struct BoundaryOptimizationReport {
    let decisions: [BoundaryDecision]

    var averageShift: Double {
        guard !decisions.isEmpty else { return 0 }
        let total = decisions.reduce(0.0) { $0 + abs($1.aligned - $1.original) }
        return total / Double(decisions.count)
    }

    var maxShift: Double {
        decisions.map { abs($0.aligned - $0.original) }.max() ?? 0
    }

    /// 各吸附来源的数量分布
    var anchorCounts: [BoundaryAnchor: Int] {
        var counts: [BoundaryAnchor: Int] = [:]
        for d in decisions {
            counts[d.anchor, default: 0] += 1
        }
        return counts
    }

    var description: String {
        let c = anchorCounts
        return """
        边界优化报告:
        - 边界数量: \(decisions.count)
        - 平均移动: \(String(format: "%.3f", averageShift))s
        - 最大移动: \(String(format: "%.3f", maxShift))s
        - 吸附分布: 强切镜 \(c[.scene] ?? 0) / 句子 \(c[.sentence] ?? 0) / 静音 \(c[.silence] ?? 0) / 原值 \(c[.original] ?? 0)
        """
    }
}

/// 边界优化服务（app 适配层）
///
/// 纯对齐算法在 `MixCutCore.BoundaryAlignmentEngine`，本类型只负责：
/// 1. 把 app 数据结构（TranscriptionSentence / VideoLocalAnalysis）转成引擎的纯输入
/// 2. 调用引擎做单次带优先级的择优吸附
/// 3. 把结果包装成诊断报告
///
/// 注意：不再传 I-frame —— 导出走 trim 重新编码，任意帧可精确切，无需对齐 I-frame
/// （旧实现的 I-frame 阶段反而把边界推离画面切换点）。
struct BoundaryOptimizerService {

    let config: BoundaryAlignConfig

    init(config: BoundaryAlignConfig = BoundaryAlignConfig()) {
        self.config = config
    }

    /// 优化分镜边界：把语义切点对齐到画面切换 / 句子结束 / 静音停顿上最自然的落点
    func optimize(
        boundaries: [Double],
        asrSentences: [TranscriptionSentence],
        localAnalysis: VideoLocalAnalysis
    ) -> (boundaries: [Double], report: BoundaryOptimizationReport) {
        let scenes = localAnalysis.sceneBoundaries.map {
            SceneCut(time: $0.time, strength: $0.confidence)
        }
        let silences = localAnalysis.silencePeriods.map {
            SilenceGap(start: $0.start, end: $0.end)
        }
        let sentences = asrSentences.map {
            SentenceSpan(start: $0.startTime, end: $0.endTime)
        }

        let decisions = BoundaryAlignmentEngine.decide(
            boundaries: boundaries,
            scenes: scenes,
            silences: silences,
            sentences: sentences,
            duration: localAnalysis.videoDuration,
            fps: localAnalysis.fps,
            config: config
        )

        return (decisions.map(\.aligned), BoundaryOptimizationReport(decisions: decisions))
    }
}
