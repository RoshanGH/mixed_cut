import Foundation

/// 方案策略（Step 1 输出）
struct SchemeStrategy: Decodable {
    let name: String
    let style: String
    let description: String
    let targetAudience: String
    let narrativeStructure: String
    let targetDuration: Double
    let estimatedQuality: Double

    enum CodingKeys: String, CodingKey {
        case name, style, description
        case targetAudience = "target_audience"
        case narrativeStructure = "narrative_structure"
        case targetDuration = "target_duration"
        case estimatedQuality = "estimated_quality"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name)) ?? "未命名方案"
        style = (try? container.decode(String.self, forKey: .style)) ?? "通用"
        description = (try? container.decode(String.self, forKey: .description)) ?? ""
        targetAudience = (try? container.decode(String.self, forKey: .targetAudience)) ?? "通用受众"
        narrativeStructure = (try? container.decode(String.self, forKey: .narrativeStructure)) ?? ""
        targetDuration = (try? container.decode(Double.self, forKey: .targetDuration)) ?? 60
        estimatedQuality = (try? container.decode(Double.self, forKey: .estimatedQuality)) ?? 7.0
    }
}

// MARK: - 精简 AI 输出格式（只有 segment ID 序列）

struct AICompactComposition: Decodable {
    let segments: [String]
    let desc: String

    enum CodingKeys: String, CodingKey {
        case segments, desc
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        segments = (try? container.decode([String].self, forKey: .segments)) ?? []
        desc = (try? container.decode(String.self, forKey: .desc)) ?? ""
    }
}

struct AICompactBatch: Decodable {
    let compositions: [AICompactComposition]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        compositions = (try? container.decode([AICompactComposition].self, forKey: .compositions)) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case compositions
    }
}

/// 分镜简要信息（值类型，可跨 actor 传递）
struct SegmentInfo: Sendable {
    let duration: Double
    let types: [String]
    let text: String
    let position: String
}

/// 分镜目录（表格格式 + ID 映射）
struct SegmentCatalog {
    let catalogText: String
    let videoAliases: String
    let idMap: [String: Segment]
    let infoMap: [String: SegmentInfo]
}

/// 素材分析报告
struct SegmentAnalysis {
    let totalSegments: Int
    let totalDuration: Double
    let typeDistribution: [String: Int]
    let highQualityCount: Int
    let averageQuality: Double
    let hasHook: Bool
    let hasCTA: Bool
    let warnings: [String]
    let suggestions: [String]
}

/// 方案生成服务
actor SchemeGenerationService {

    private let injectedProvider: (any AIProvider)?
    private let promptLoader: PromptLoader

    private var aiProvider: any AIProvider {
        injectedProvider ?? AIProviderManager.currentProvider()
    }

    init(aiProvider: (any AIProvider)? = nil, promptLoader: PromptLoader = PromptLoader()) {
        self.injectedProvider = aiProvider
        self.promptLoader = promptLoader
    }

    // MARK: - 素材分析

    func analyzeSegments(_ segments: [Segment]) -> SegmentAnalysis {
        let totalDuration = segments.reduce(0.0) { $0 + $1.duration }

        var typeDistribution: [String: Int] = [:]
        for seg in segments {
            for t in seg.semanticTypes {
                typeDistribution[t.rawValue, default: 0] += 1
            }
        }

        let highQuality = segments.filter { $0.qualityScore >= 8.5 }
        let avgQuality = segments.isEmpty ? 0 :
            segments.reduce(0.0) { $0 + $1.qualityScore } / Double(segments.count)

        let hasHook = segments.contains { $0.semanticTypes.contains(.hook) }
        let hasCTA = segments.contains { $0.semanticTypes.contains(.callToAction) }

        var warnings: [String] = []
        var suggestions: [String] = []

        if !hasHook {
            warnings.append("缺少开场类型片段（噱头引入），可能影响开场效果")
        }
        if !hasCTA {
            warnings.append("缺少行动号召类型片段，可能影响转化效果")
        }
        if highQuality.count < 3 {
            warnings.append("高质量片段（评分>=8.5）数量不足，可能影响方案质量")
        }
        if segments.count < 5 {
            suggestions.append("建议导入更多视频以获得更丰富的素材")
        }

        return SegmentAnalysis(
            totalSegments: segments.count,
            totalDuration: totalDuration,
            typeDistribution: typeDistribution,
            highQualityCount: highQuality.count,
            averageQuality: avgQuality,
            hasHook: hasHook,
            hasCTA: hasCTA,
            warnings: warnings,
            suggestions: suggestions
        )
    }

    // MARK: - Step 1: 生成策略

    func generateStrategies(
        segments: [Segment],
        count: Int = 3,
        customPrompt: String? = nil
    ) async throws -> [SchemeStrategy] {
        let adStyles = promptLoader.loadPrompt(named: "ad_styles") ?? ""
        let principles = promptLoader.loadPrompt(named: "recombination_principles") ?? ""
        let segmentSummary = buildSegmentSummary(segments)

        let prompt = """
        # 任务：生成 \(count) 个差异化的视频混剪方案策略

        你是一个专业的视频混剪策划师。请基于以下素材信息，设计 \(count) 个差异化的方案策略。

        ## 可用素材摘要
        \(segmentSummary)

        ## 广告风格参考
        \(adStyles)

        ## 混剪原则参考
        \(principles)

        \(customPrompt.map { "## 用户自定义要求（必须严格遵守）\n\($0)" } ?? "")

        ## 输出要求
        请输出 JSON 数组，每个元素包含：
        - name: 方案名称（6-10字）
        - style: 广告风格
        - description: 一句话描述核心策略（20-30字）
        - target_audience: 目标受众（8-15字）
        - narrative_structure: 叙事结构（箭头连接）
        - target_duration: 目标时长（秒）
        - estimated_quality: 预估质量分（0-10）

        确保 \(count) 个策略之间有明显差异（不同风格、不同受众、不同时长）。
        直接输出 JSON 数组，不要包含其他内容。
        """

        return try await aiProvider.generateJSON(
            prompt: prompt,
            responseType: [SchemeStrategy].self
        )
    }

    // MARK: - Step 2: 批量组合生成

    func generateBatchCompositions(
        strategy: SchemeStrategy,
        catalogText: String,
        videoAliases: String,
        variationCount: Int = 20,
        batchSize: Int = 10,
        customPrompt: String? = nil
    ) async throws -> [AICompactComposition] {
        var allCompositions: [AICompactComposition] = []
        var remaining = variationCount

        while remaining > 0 {
            let batchCount = min(remaining, batchSize)
            let fingerprints = buildExistingFingerprints(allCompositions)

            let prompt = """
            你是信息流广告混剪专家。基于策略和素材，生成 **\(batchCount) 个**不同的分镜排列组合。

            ## 策略
            风格: \(strategy.style) | 受众: \(strategy.targetAudience) | 叙事: \(strategy.narrativeStructure) | 时长: \(strategy.targetDuration)s

            ## 视频别名
            \(videoAliases)

            ## 可用片段（ID|位置|类型|时长|台词）
            \(catalogText)

            ## 已有变体（不要重复相同的 ID 顺序）
            \(fingerprints)

            \(customPrompt.map { "## 用户自定义要求（必须严格遵守）\n\($0)\n" } ?? "")
            ## 规则
            1. position="开头"的片段只放视频开头，"结尾"只放结尾，"中间"可灵活排列
            2. 相邻片段台词衔接自然，符合信息流广告叙事
            3. 每个组合之间必须有差异（换开场/换中间段/换结尾/调整顺序）
            4. 同一组合内不重复同一片段，不同组合间可重复使用相同片段
            5. 时长 \(max(30, strategy.targetDuration - 20))-\(strategy.targetDuration + 20)s
            6. 必须生成恰好 \(batchCount) 个组合，不能少于这个数量

            ## 输出格式（JSON，只需片段 ID 序列）
            {"compositions":[{"segments":["V1_01","V2_03","V1_05"],"desc":"一句话描述"},{"segments":["V1_02","V2_01","V1_04"],"desc":"另一个描述"}]}

            直接输出 JSON，不要其他文字。必须包含 \(batchCount) 个 composition。
            """

            let batchResult: [AICompactComposition]
            do {
                let batch = try await aiProvider.generateJSON(
                    prompt: prompt,
                    responseType: AICompactBatch.self
                )
                batchResult = batch.compositions
            } catch {
                do {
                    batchResult = try await aiProvider.generateJSON(
                        prompt: prompt,
                        responseType: [AICompactComposition].self
                    )
                } catch {
                    let single = try await aiProvider.generateJSON(
                        prompt: prompt,
                        responseType: AICompactComposition.self
                    )
                    batchResult = [single]
                }
            }

            let valid = batchResult.filter { !$0.segments.isEmpty }
            allCompositions.append(contentsOf: valid)
            remaining -= valid.count

            if valid.isEmpty {
                MixLog.info(" AI 返回变体为空，提前结束")
                break
            }

            MixLog.info(" 批次完成: +\(valid.count) 个变体，累计 \(allCompositions.count)/\(variationCount)")
        }

        return allCompositions
    }

    // MARK: - 辅助方法

    private func buildSegmentSummary(_ segments: [Segment]) -> String {
        let analysis = analyzeSegments(segments)
        var summary = """
        总片段数: \(analysis.totalSegments)
        总时长: \(String(format: "%.1f", analysis.totalDuration)) 秒
        平均质量: \(String(format: "%.1f", analysis.averageQuality))
        高质量片段: \(analysis.highQualityCount) 个
        """

        summary += "\n\n类型分布:\n"
        for (type, count) in analysis.typeDistribution.sorted(by: { $0.key < $1.key }) {
            summary += "- \(type): \(count) 个\n"
        }

        return summary
    }

    private func buildExistingFingerprints(_ compositions: [AICompactComposition]) -> String {
        if compositions.isEmpty { return "无（这是第一批）" }
        return "已有\(compositions.count)个变体:\n" +
            compositions.enumerated().map { i, comp in
                "\(i + 1): \(comp.segments.joined(separator: "→"))"
            }.joined(separator: "\n")
    }
}
