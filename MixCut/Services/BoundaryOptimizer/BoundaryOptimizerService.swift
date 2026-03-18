import Foundation

/// 边界优化配置
struct BoundaryOptimizationConfig {
    /// 阶段1: ASR 句子边界吸附最大偏移量（秒）
    var asrSnapMaxOffset: Double = 0.8
    /// 阶段2: 场景切换对齐搜索范围（秒）
    var sceneSearchRange: Double = 0.3
    /// 阶段3: 静音段吸附搜索范围（秒）
    var silenceSearchRange: Double = 0.5
    /// 阶段4: I-frame 对齐最大距离（秒）
    var iframeAlignMaxDistance: Double = 0.1
    /// 安全约束: 最大边界移动距离（秒）
    var maxBoundaryShift: Double = 1.5
    /// 安全约束: 最小片段时长（秒）
    var minSegmentDuration: Double = 1.0
}

/// 边界优化报告
struct BoundaryOptimizationReport {
    let originalBoundaries: [Double]
    let optimizedBoundaries: [Double]
    let shifts: [Double]
    let averageShift: Double
    let maxShift: Double
    let segmentsAffected: Int

    var description: String {
        """
        边界优化报告:
        - 边界数量: \(originalBoundaries.count)
        - 平均移动: \(String(format: "%.3f", averageShift))s
        - 最大移动: \(String(format: "%.3f", maxShift))s
        - 受影响片段: \(segmentsAffected)
        """
    }
}

/// 四阶段边界优化服务
///
/// 阶段1: ASR 句子结束吸附 — 确保不在台词中间切割（优先吸附到句子 endTime）
/// 阶段2: 场景切换对齐 — 对齐到最近的画面切换点，避免镜头画面混入
/// 阶段3: 静音段吸附 — 优先切在停顿/静音处
/// 阶段4: I-frame 对齐 — 微调到最近 I-frame，确保 copy 模式不花屏
/// 安全约束: 限制移动距离、保证最小片段时长
struct BoundaryOptimizerService {

    let config: BoundaryOptimizationConfig

    init(config: BoundaryOptimizationConfig = BoundaryOptimizationConfig()) {
        self.config = config
    }

    /// 优化分镜边界（完整四阶段）
    func optimize(
        boundaries: [Double],
        asrSentences: [TranscriptionSentence],
        localAnalysis: VideoLocalAnalysis
    ) -> (boundaries: [Double], report: BoundaryOptimizationReport) {
        let original = boundaries.sorted()
        guard !original.isEmpty else {
            let report = BoundaryOptimizationReport(
                originalBoundaries: [], optimizedBoundaries: [],
                shifts: [], averageShift: 0, maxShift: 0, segmentsAffected: 0
            )
            return ([], report)
        }

        // 阶段1: ASR 句子结束吸附（最高优先级）
        var optimized = snapToSentenceEnds(boundaries: original, sentences: asrSentences)

        // 阶段2: 场景切换对齐
        optimized = alignToSceneChanges(
            boundaries: optimized,
            sceneChanges: localAnalysis.sceneBoundaries
        )

        // 阶段3: 静音段吸附
        optimized = snapToSilence(
            boundaries: optimized,
            silencePeriods: localAnalysis.silencePeriods
        )

        // 阶段4: I-frame 对齐（微调，确保编码层面干净）
        optimized = alignToIFrames(
            boundaries: optimized,
            iframePositions: localAnalysis.iframePositions
        )

        // 安全约束
        optimized = enforceConstraints(
            boundaries: optimized,
            originalBoundaries: original,
            videoDuration: localAnalysis.videoDuration
        )

        // 生成报告
        let shifts = zip(original, optimized).map { abs($1 - $0) }
        let report = BoundaryOptimizationReport(
            originalBoundaries: original,
            optimizedBoundaries: optimized,
            shifts: shifts,
            averageShift: shifts.isEmpty ? 0 : shifts.reduce(0, +) / Double(shifts.count),
            maxShift: shifts.max() ?? 0,
            segmentsAffected: shifts.filter { $0 > 0.01 }.count
        )

        return (optimized, report)
    }

    /// 兼容旧接口
    func optimize(
        boundaries: [Double],
        asrSentences: [TranscriptionSentence],
        keyframes: [SceneBoundary],
        videoDuration: Double
    ) -> (boundaries: [Double], report: BoundaryOptimizationReport) {
        let analysis = VideoLocalAnalysis(
            sceneBoundaries: keyframes,
            silencePeriods: [],
            iframePositions: [],
            videoDuration: videoDuration,
            fps: 30
        )
        return optimize(
            boundaries: boundaries,
            asrSentences: asrSentences,
            localAnalysis: analysis
        )
    }

    // MARK: - 阶段1: ASR 句子结束吸附

    /// 将切点吸附到最近的句子结束时间
    /// 核心原则：切点必须落在句子说完之后，选择距离最近的句子边界
    private func snapToSentenceEnds(
        boundaries: [Double],
        sentences: [TranscriptionSentence]
    ) -> [Double] {
        guard !sentences.isEmpty else { return boundaries }

        let sentenceEnds = sentences.map(\.endTime).sorted()

        return boundaries.map { boundary in
            // 找距离最近的句子 endTime（在阈值范围内）
            var bestEnd: Double?
            var bestDistance = Double.infinity

            for end in sentenceEnds {
                let distance = abs(end - boundary)
                if distance <= config.asrSnapMaxOffset && distance < bestDistance {
                    bestDistance = distance
                    bestEnd = end
                }
            }

            return bestEnd ?? boundary
        }
    }

    // MARK: - 阶段2: 场景切换对齐

    /// 在句子结束点附近搜索最近的画面切换，对齐过去
    /// 避免镜头 A 的尾帧混入镜头 B 的片段
    private func alignToSceneChanges(
        boundaries: [Double],
        sceneChanges: [SceneBoundary]
    ) -> [Double] {
        guard !sceneChanges.isEmpty else { return boundaries }

        let sceneTimes = sceneChanges.map(\.time).sorted()

        return boundaries.map { boundary in
            // 在搜索范围内查找最近的场景切换
            let candidates = sceneTimes.filter {
                abs($0 - boundary) <= config.sceneSearchRange
            }

            guard let closest = candidates.min(by: {
                abs($0 - boundary) < abs($1 - boundary)
            }) else {
                return boundary
            }

            return closest
        }
    }

    // MARK: - 阶段3: 静音段吸附

    /// 如果切点附近有静音段，移到静音段的中点
    /// 在停顿处切割是最自然的
    private func snapToSilence(
        boundaries: [Double],
        silencePeriods: [SilencePeriod]
    ) -> [Double] {
        guard !silencePeriods.isEmpty else { return boundaries }

        return boundaries.map { boundary in
            // 查找包含切点的静音段
            if let containing = silencePeriods.first(where: {
                $0.start <= boundary && boundary <= $0.end
            }) {
                // 已在静音段内，移到中点
                return containing.midpoint
            }

            // 查找附近的静音段
            let nearby = silencePeriods.filter {
                abs($0.midpoint - boundary) <= config.silenceSearchRange
            }

            guard let closest = nearby.min(by: {
                abs($0.midpoint - boundary) < abs($1.midpoint - boundary)
            }) else {
                return boundary
            }

            return closest.midpoint
        }
    }

    // MARK: - 阶段4: I-frame 对齐

    /// 微调到最近的 I-frame 位置
    /// I-frame 是视频编码的完整帧，在此处切割 copy 模式不会花屏
    private func alignToIFrames(
        boundaries: [Double],
        iframePositions: [Double]
    ) -> [Double] {
        guard !iframePositions.isEmpty else { return boundaries }

        return boundaries.map { boundary in
            // 找最近的 I-frame
            guard let closest = iframePositions.min(by: {
                abs($0 - boundary) < abs($1 - boundary)
            }) else {
                return boundary
            }

            // 只在很小的范围内微调
            if abs(closest - boundary) <= config.iframeAlignMaxDistance {
                return closest
            }
            return boundary
        }
    }

    // MARK: - 安全约束

    private func enforceConstraints(
        boundaries: [Double],
        originalBoundaries: [Double],
        videoDuration: Double
    ) -> [Double] {
        var result = boundaries

        // 约束1: 限制最大移动距离
        for i in 0..<result.count {
            if i < originalBoundaries.count {
                let shift = abs(result[i] - originalBoundaries[i])
                if shift > config.maxBoundaryShift {
                    result[i] = originalBoundaries[i]
                }
            }
        }

        // 约束2: 保证边界严格递增
        for i in 1..<result.count {
            if result[i] <= result[i - 1] {
                result[i] = result[i - 1] + config.minSegmentDuration
            }
        }

        // 约束3: 保证最小片段时长
        if let first = result.first, first < config.minSegmentDuration {
            result[0] = config.minSegmentDuration
        }
        if let last = result.last, videoDuration - last < config.minSegmentDuration {
            result[result.count - 1] = videoDuration - config.minSegmentDuration
        }

        // 约束4: 限定在视频时长范围内（clamp 而非 filter，保持数组长度不变）
        result = result.map { max(0.01, min($0, videoDuration - 0.01)) }

        return result
    }
}
