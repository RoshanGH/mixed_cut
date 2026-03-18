import Foundation

/// AI 标注后的分镜结果
struct AnnotatedSegment: Codable {
    let id: String
    let startTime: Double
    let endTime: Double
    let duration: Double
    let text: String
    let types: [String]        // 语义类型（可多个，中文）
    let position: String       // 位置类型（开头/中间/结尾）
    let dataQuality: DataQuality
    let keywords: [String]

    struct DataQuality: Codable {
        let score: Double
        let reasoning: String
    }

    enum CodingKeys: String, CodingKey {
        case id
        case startTime = "start_time"
        case endTime = "end_time"
        case duration
        case text
        case types
        case type    // 兼容旧格式（单个字符串）
        case position
        case dataQuality = "data_quality"
        case keywords
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        startTime = try c.decode(Double.self, forKey: .startTime)
        endTime = try c.decode(Double.self, forKey: .endTime)
        duration = try c.decode(Double.self, forKey: .duration)
        text = try c.decode(String.self, forKey: .text)
        position = try c.decode(String.self, forKey: .position)
        dataQuality = try c.decode(DataQuality.self, forKey: .dataQuality)
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []

        // 优先解 types 数组，降级解 type 单字符串
        if let arr = try? c.decode([String].self, forKey: .types) {
            types = arr.isEmpty ? ["过渡"] : arr
        } else if let single = try? c.decode(String.self, forKey: .type) {
            types = single.isEmpty ? ["过渡"] : [single]
        } else {
            types = ["过渡"]
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(startTime, forKey: .startTime)
        try c.encode(endTime, forKey: .endTime)
        try c.encode(duration, forKey: .duration)
        try c.encode(text, forKey: .text)
        try c.encode(types, forKey: .types)
        try c.encode(position, forKey: .position)
        try c.encode(dataQuality, forKey: .dataQuality)
        try c.encode(keywords, forKey: .keywords)
    }
}

/// AI 分析输出
struct AISegmentationResult: Codable {
    let videoId: String
    let totalDuration: Double
    let totalSegments: Int
    let segments: [AnnotatedSegment]

    enum CodingKeys: String, CodingKey {
        case videoId = "video_id"
        case totalDuration = "total_duration"
        case totalSegments = "total_segments"
        case segments
    }
}

/// AI 语义分析服务
actor AIAnalysisService {

    /// 显式注入时使用固定 provider；否则每次调用动态获取最新配置
    private let injectedProvider: (any AIProvider)?
    private let promptLoader: PromptLoader

    private var aiProvider: any AIProvider {
        injectedProvider ?? AIProviderManager.currentProvider()
    }

    init(aiProvider: (any AIProvider)? = nil, promptLoader: PromptLoader = PromptLoader()) {
        self.injectedProvider = aiProvider
        self.promptLoader = promptLoader
    }

    /// 对视频进行语义分镜切分（基于本地分析数据）
    func analyzeVideo(
        videoId: String,
        transcript: TranscriptionResult,
        sceneBoundaries: [SceneBoundary],
        localAnalysis: VideoLocalAnalysis? = nil,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> AISegmentationResult {
        onProgress?("正在构建分析 prompt...")

        let prompt = buildSegmentationPrompt(
            videoId: videoId,
            transcript: transcript,
            sceneBoundaries: sceneBoundaries,
            localAnalysis: localAnalysis
        )

        onProgress?("正在等待 AI 分析...")

        let result = try await aiProvider.generateJSON(
            prompt: prompt,
            responseType: AISegmentationResult.self
        )

        onProgress?("分析完成，获得 \(result.segments.count) 个分镜")
        return result
    }

    /// 构建切分 prompt — 核心：本地数据驱动，AI 做语义决策
    private func buildSegmentationPrompt(
        videoId: String,
        transcript: TranscriptionResult,
        sceneBoundaries: [SceneBoundary],
        localAnalysis: VideoLocalAnalysis?
    ) -> String {
        // 加载类型定义
        let segmentTypesDefinition = promptLoader.loadPrompt(named: "segment_types_definition") ?? ""

        // 构建 ASR 句子数据
        let sentencesJSON = transcript.sentences.enumerated().map { i, s in
            let escapedText = s.text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "'")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\t", with: " ")
            return "  {\"idx\": \(i), \"text\": \"\(escapedText)\", \"start\": \(String(format: "%.2f", s.startTime)), \"end\": \(String(format: "%.2f", s.endTime))}"
        }.joined(separator: ",\n")

        // 构建场景切换数据
        let scenesText = sceneBoundaries.map {
            String(format: "%.3fs (置信度: %.2f)", $0.time, $0.confidence)
        }.joined(separator: ", ")

        // 构建静音段数据
        let silenceText: String
        if let analysis = localAnalysis, !analysis.silencePeriods.isEmpty {
            silenceText = analysis.silencePeriods.map {
                String(format: "%.2f-%.2fs (%.1f秒)", $0.start, $0.end, $0.duration)
            }.joined(separator: ", ")
        } else {
            silenceText = "（无静音数据）"
        }

        // 构建 I-frame 数据（只列出关键帧分布概况，不列全部）
        let iframeText: String
        if let analysis = localAnalysis, !analysis.iframePositions.isEmpty {
            let count = analysis.iframePositions.count
            let avgInterval: Double
            if count > 1 {
                avgInterval = analysis.videoDuration / Double(count - 1)
            } else {
                avgInterval = analysis.videoDuration
            }
            iframeText = "共 \(count) 个 I-frame，平均间隔 \(String(format: "%.2f", avgInterval))s"
        } else {
            iframeText = "（无 I-frame 数据）"
        }

        let duration = localAnalysis?.videoDuration ?? transcript.duration

        // 构建完整 ASR 文本供 AI 通读
        let fullText = transcript.text

        return """
        # 任务：广告视频语义分镜切分

        你是一个专业的广告视频分析专家。请基于以下本地预处理数据，将视频切分为**语义独立的最小单元**。

        ⚠️ 你不会看到视频画面，所有视觉信息已由本地 FFmpeg 分析提取。

        ---

        ## 视频基础信息
        - 视频 ID: \(videoId)
        - 总时长: \(String(format: "%.1f", duration))s
        - I-frame 分布: \(iframeText)

        ## 完整台词文本（先通读理解整体结构）
        \(fullText)

        ## ASR 逐句转录（含精确时间戳）
        [\n\(sentencesJSON)\n]

        ## 画面切换点（FFmpeg scene detection）
        检测到 \(sceneBoundaries.count) 个画面切换：
        \(scenesText.isEmpty ? "（未检测到明显画面切换）" : scenesText)

        ## 音频静音段（FFmpeg silencedetect）
        \(silenceText)

        ---

        ## 核心原则：语义独立性（最重要！）

        每个切出的片段必须是一个**语义上独立的最小单元**：
        - 能脱离上下文被独立理解
        - 表达一个完整的意思（一个痛点、一个卖点、一个号召等）
        - 不含两个不同主题（如"痛点描述"和"产品介绍"不能混在同一片段）
        - 排比/对比/因果等修辞结构保持完整，不在中间切断

        ## 切分规则（优先级从高到低）

        ### 规则 1：语义完整性 ⭐⭐⭐⭐⭐（最高优先级）
        - 每个片段必须只讲一件事，主题切换时必须切分
        - **绝对不能在一句话中间切断**
        - 片段的 text 必须是完整的句子，从 ASR 数据中精确提取
        - start_time 和 end_time 必须精确对应该片段台词在 ASR 中的时间范围

        ### 规则 2：台词与时间严格对应 ⭐⭐⭐⭐
        - text 字段必须是 start_time 到 end_time 之间 ASR 句子的原文拼接
        - 不要编造、改写或遗漏台词，必须从 ASR 数据中原样提取
        - start_time = 该片段第一个 ASR 句子的 start
        - end_time = 该片段最后一个 ASR 句子的 end

        ### 规则 3：画面切换对齐 ⭐⭐⭐
        - 切点应尽量对齐画面切换点（±0.5s 内）
        - 避免一个镜头的画面混入另一个片段

        ### 规则 4：静音段优先 ⭐⭐
        - 切点优先落在静音段内（说话间的停顿）

        ---

        ## 切分粒度

        - 目标片段时长：3-15 秒（语义完整性优先于时长）
        - **硬性上限：任何单个片段不得超过 18 秒**。超过 15 秒时必须寻找内部的语义切分点拆分
        - 短视频（< 40s）：平均 5-8s/片段
        - 中视频（40-80s）：平均 6-12s/片段
        - 长视频（> 80s）：平均 8-15s/片段
        - 宁可多切几个短片段，也不要把不同主题混在一起

        ---

        ## 片段类型定义

        \(segmentTypesDefinition)

        ⚠️ types 是一个数组，每个元素必须是以下 11 个字符串之一（精确匹配）：
        "噱头引入"、"痛点"、"产品方案"、"效果展示"、"信任背书"、"价格对比"、"活动福利"、"行动号召"、"产品定位"、"产品使用教育"、"过渡"

        一个片段可以同时具有多个语义类型。例如一段既在展示效果又在做信任背书，则 types: ["效果展示", "信任背书"]。
        至少标注 1 个类型，通常 1-2 个，最多 3 个。第一个是主类型。

        ## 位置类型

        position 字段必须是以下 3 个字符串之一，表示该片段在**原视频**中的位置：
        - "开头"：位于视频前 20%，承担吸引注意力功能
        - "中间"：核心内容区域
        - "结尾"：位于视频后 20%，承担驱动转化功能

        ---

        ## 输出格式（严格 JSON）

        ```json
        {
          "video_id": "\(videoId)",
          "total_duration": \(String(format: "%.1f", duration)),
          "total_segments": <切分数量>,
          "segments": [
            {
              "id": "seg_001",
              "start_time": <从ASR句子的start精确取值>,
              "end_time": <从ASR句子的end精确取值>,
              "duration": <end_time - start_time>,
              "text": "<从ASR原文精确提取的该时间段完整台词>",
              "types": ["<主类型>", "<可选次类型>"],
              "position": "<开头|中间|结尾>",
              "data_quality": {
                "score": <0-10>,
                "reasoning": "<评分理由>"
              },
              "keywords": ["关键词1", "关键词2", "关键词3"]
            }
          ]
        }
        ```

        ## 切分步骤

        1. 通读完整台词，识别整体内容结构和主题切换点
        2. 将 ASR 句子按语义主题分组，每组成为一个片段
        3. 每个片段的 start_time/end_time 直接取自 ASR 句子的时间戳
        4. 每个片段的 text 是该组 ASR 句子原文的拼接
        5. 标注语义类型（从 11 种中精确选择）和位置类型
        6. 自检：确认每个片段语义独立、台词完整、时间正确

        请直接输出 JSON，不要添加其他说明文字。
        """
    }
}

/// Prompt 模板加载器
struct PromptLoader {

    /// 从 bundle 资源中加载 prompt 模板
    func loadPrompt(named name: String) -> String? {
        // 先尝试从 bundle resources 加载
        if let url = Bundle.main.url(forResource: name, withExtension: "md", subdirectory: "Prompts") {
            return try? String(contentsOf: url, encoding: .utf8)
        }

        // 回退到 Resources/Prompts 目录
        if let url = Bundle.main.url(forResource: name, withExtension: "md") {
            return try? String(contentsOf: url, encoding: .utf8)
        }

        return nil
    }
}
