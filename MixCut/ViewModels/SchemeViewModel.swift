import Foundation
import SwiftData

/// 方案浏览 ViewModel
@MainActor
@Observable
final class SchemeViewModel {
    var strategies: [MixStrategy] = []
    var selectedStrategy: MixStrategy?
    var selectedScheme: MixScheme?
    var isGenerating = false
    var generationProgress: String = ""
    var errorMessage: String?

    private var modelContext: ModelContext?
    private let schemeService = SchemeGenerationService()

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    /// 加载项目的所有策略和方案
    func loadSchemes(for project: Project) {
        strategies = project.strategies.sorted { $0.createdAt < $1.createdAt }
        // 如果有策略但未选中，默认选第一个
        if selectedStrategy == nil, let first = strategies.first {
            selectedStrategy = first
            selectedScheme = first.orderedSchemes.first
        }
    }

    /// 所有方案的扁平列表（兼容旧接口）
    var schemes: [MixScheme] {
        strategies.flatMap(\.orderedSchemes)
    }

    // MARK: - 构建分镜目录（全局唯一 ID）

    /// 在 MainActor 上构建分镜目录和 ID 映射
    /// ID 格式：V{视频序号}_{分镜序号}，确保跨视频全局唯一
    private func buildSegmentCatalog(_ segments: [Segment]) -> SegmentCatalog {
        // 按视频分组，建立视频别名
        var videoNames: [String] = []
        var videoIndexMap: [String: Int] = [:]

        for seg in segments {
            let name = seg.video?.name ?? "unknown"
            if videoIndexMap[name] == nil {
                videoIndexMap[name] = videoNames.count + 1
                videoNames.append(name)
            }
        }

        // 视频别名
        let aliases = videoNames.enumerated().map { i, name in
            "V\(i + 1) = \(name)"
        }.joined(separator: "\n")

        // 按视频分组、按时间排序（确保 ID 稳定）
        let sortedSegments = segments.sorted { a, b in
            let aName = a.video?.name ?? ""
            let bName = b.video?.name ?? ""
            if aName != bName { return aName < bName }
            return a.startTime < b.startTime
        }

        // 构建目录表格和 ID 映射
        var idMap: [String: Segment] = [:]
        var infoMap: [String: SegmentInfo] = [:]
        var catalogLines: [String] = []
        var segCountPerVideo: [String: Int] = [:]

        for seg in sortedSegments {
            let videoName = seg.video?.name ?? "unknown"
            let vIdx = videoIndexMap[videoName] ?? 1
            let segNum = (segCountPerVideo[videoName] ?? 0) + 1
            segCountPerVideo[videoName] = segNum

            let globalId = String(format: "V%d_%02d", vIdx, segNum)
            idMap[globalId] = seg

            let types = seg.semanticTypes.map(\.rawValue)
            let dur = String(format: "%.1f", seg.duration)
            let pos = seg.positionType.rawValue

            infoMap[globalId] = SegmentInfo(
                duration: seg.duration,
                types: types,
                text: seg.text,
                position: pos
            )

            catalogLines.append("\(globalId)|\(pos)|\(types.joined(separator: ","))|\(dur)s|\(seg.text)")
        }

        let catalog = catalogLines.joined(separator: "\n")
        return SegmentCatalog(catalogText: catalog, videoAliases: aliases, idMap: idMap, infoMap: infoMap)
    }

    // MARK: - 生成

    /// 自动计算策略数量
    private func strategyCount(for targetTotal: Int) -> Int {
        if targetTotal <= 30 { return 3 }
        if targetTotal <= 80 { return 4 }
        return 5
    }

    /// 生成混剪方案（新架构：策略 + 批量组合）
    func generateSchemes(
        for project: Project,
        targetVideoCount: Int = 50,
        customPrompt: String? = nil
    ) async {
        guard let context = modelContext else { return }

        // 上限 100
        let clampedTarget = min(targetVideoCount, 100)

        isGenerating = true
        errorMessage = nil
        project.status = .generating

        do {
            let allSegments = project.videos.flatMap(\.segments)
            guard !allSegments.isEmpty else {
                errorMessage = "没有可用的分镜素材，请先导入并分析视频"
                project.status = .ready
                isGenerating = false
                return
            }

            // 构建分镜目录（全局唯一 ID + 表格格式）
            let catalog = buildSegmentCatalog(allSegments)
            let catalogText = catalog.catalogText
            let videoAliases = catalog.videoAliases

            MixLog.info(" 分镜目录: \(catalog.idMap.count) 个片段, \(catalogText.count) 字符")

            let numStrategies = strategyCount(for: clampedTarget)
            let variationsPerStrategy = max(5, Int(ceil(Double(clampedTarget) / Double(numStrategies))))

            // Step 1: 生成策略
            generationProgress = "正在生成 \(numStrategies) 个方案策略..."
            let strategyResults = try await schemeService.generateStrategies(
                segments: allSegments,
                count: numStrategies,
                customPrompt: customPrompt
            )

            // Step 2: 所有策略并行生成组合
            generationProgress = "正在并行生成 \(strategyResults.count) 个策略的变体..."

            let allResults: [(Int, SchemeStrategy, [AICompactComposition])] = await withTaskGroup(
                of: (Int, SchemeStrategy, [AICompactComposition])?.self
            ) { group in
                for (i, strategyResult) in strategyResults.enumerated() {
                    group.addTask { [schemeService, catalogText, videoAliases, variationsPerStrategy, customPrompt] in
                        do {
                            let compositions = try await schemeService.generateBatchCompositions(
                                strategy: strategyResult,
                                catalogText: catalogText,
                                videoAliases: videoAliases,
                                variationCount: variationsPerStrategy,
                                customPrompt: customPrompt
                            )
                            return (i, strategyResult, compositions)
                        } catch {
                            MixLog.info(" 策略「\(strategyResult.name)」生成失败: \(error)")
                            return nil
                        }
                    }
                }

                var results: [(Int, SchemeStrategy, [AICompactComposition])] = []
                for await result in group {
                    if let r = result {
                        results.append(r)
                        await MainActor.run {
                            generationProgress = "已完成 \(results.count)/\(strategyResults.count) 个策略..."
                        }
                    }
                }
                return results.sorted { $0.0 < $1.0 }
            }

            // 在主线程创建数据模型
            for (i, strategyResult, compositions) in allResults {
                let strategy = MixStrategy(
                    name: strategyResult.name,
                    style: strategyResult.style,
                    description: strategyResult.description,
                    targetAudience: strategyResult.targetAudience,
                    narrativeStructure: strategyResult.narrativeStructure,
                    targetDuration: strategyResult.targetDuration
                )
                strategy.project = project
                context.insert(strategy)

                for (vi, comp) in compositions.enumerated() {
                    guard !comp.segments.isEmpty else { continue }

                    // 匹配分镜并计算时长
                    let matchedSegments = comp.segments.compactMap { catalog.idMap[$0] }
                    let totalDuration = matchedSegments.reduce(0.0) { $0 + $1.duration }

                    let scheme = MixScheme(
                        variationIndex: vi + 1,
                        schemeIndex: String(format: "scheme_%03d_%03d", i + 1, vi + 1),
                        name: comp.desc.isEmpty
                            ? "\(strategyResult.name) #\(vi + 1)"
                            : comp.desc,
                        style: strategyResult.style,
                        description: strategyResult.description,
                        targetAudience: strategyResult.targetAudience,
                        narrativeStructure: strategyResult.narrativeStructure
                    )
                    scheme.estimatedDuration = totalDuration
                    scheme.strategy = strategy
                    scheme.project = project
                    context.insert(scheme)

                    // 用字典直接匹配，O(1) 查找
                    createSchemeSegments(
                        segmentIDs: comp.segments,
                        scheme: scheme,
                        idMap: catalog.idMap,
                        context: context
                    )
                }

                try context.save()
                MixLog.info(" 策略「\(strategyResult.name)」: \(compositions.count) 个变体")
            }

            project.status = .completed
            project.updatedAt = Date()
            try context.save()

            loadSchemes(for: project)
            generationProgress = "生成完成：\(strategies.count) 个策略，共 \(schemes.count) 个视频方案"
        } catch {
            errorMessage = "方案生成失败: \(error.localizedDescription)\n(\(String(describing: error).prefix(300)))"
            project.status = .ready
            context.safeSave()
        }

        isGenerating = false
    }

    // MARK: - 分镜匹配（字典直接查找）

    /// 用全局 ID 字典直接匹配，替代旧的 5 层 fallback
    private func createSchemeSegments(
        segmentIDs: [String],
        scheme: MixScheme,
        idMap: [String: Segment],
        context: ModelContext
    ) {
        var matchedCount = 0

        for (pos, segID) in segmentIDs.enumerated() {
            let matched = idMap[segID]
            if matched != nil { matchedCount += 1 }

            let schemeSeg = SchemeSegment(
                position: pos + 1,
                reasoning: "",
                positionReasoning: ""
            )
            schemeSeg.scheme = scheme
            schemeSeg.segment = matched
            context.insert(schemeSeg)
        }

        MixLog.info(" 变体「\(scheme.name)」: \(matchedCount)/\(segmentIDs.count) 分镜匹配")
    }

    // MARK: - 删除

    /// 删除整个策略及其所有变体
    func deleteStrategy(_ strategy: MixStrategy) {
        guard let context = modelContext else { return }
        if selectedStrategy?.id == strategy.id {
            selectedStrategy = nil
            selectedScheme = nil
        }
        context.delete(strategy)
        context.safeSave()
        strategies.removeAll { $0.id == strategy.id }
    }

    /// 删除单个方案变体
    func deleteScheme(_ scheme: MixScheme) {
        guard let context = modelContext else { return }
        if selectedScheme?.id == scheme.id {
            selectedScheme = nil
        }
        context.delete(scheme)
        context.safeSave()
        // 刷新策略数据
        if let strategy = scheme.strategy {
            strategies = strategies // 触发刷新
            _ = strategy.schemeCount
        }
    }

    // MARK: - 分镜编辑

    func moveSegment(in scheme: MixScheme, from source: Int, to destination: Int) {
        var ordered = scheme.orderedSegments
        guard source >= 0, source < ordered.count,
              destination >= 0, destination <= ordered.count else { return }

        let moved = ordered.remove(at: source)
        let adjustedDest = destination > source ? destination - 1 : destination
        ordered.insert(moved, at: adjustedDest)

        for (i, seg) in ordered.enumerated() {
            seg.position = i + 1
        }

        modelContext?.safeSave()
    }

    func removeSegment(_ schemeSeg: SchemeSegment, from scheme: MixScheme) {
        guard let context = modelContext else { return }
        let deletedID = schemeSeg.id
        context.delete(schemeSeg)

        let remaining = scheme.orderedSegments.filter { $0.id != deletedID }
        for (i, seg) in remaining.enumerated() {
            seg.position = i + 1
        }

        context.safeSave()
    }
}
