import Foundation

/// AI 整片台词改写服务（薄胶水）。
/// 纯逻辑（prompt 构建 / 结果映射 / 字数预算）在 MixCutCore，便于 swift test 覆盖。
/// 本 actor 只负责：加载模板 → 构建 prompt → 调 AIProvider → 映射结果。
actor ScriptRewriteService {
    private let injectedProvider: (any AIProvider)?
    private let promptLoader = PromptLoader()

    /// - Parameter provider: 注入用于测试；生产传 nil，运行时动态取当前 provider（Settings 改了立即生效）。
    init(provider: (any AIProvider)? = nil) {
        self.injectedProvider = provider
    }

    private var provider: any AIProvider {
        injectedProvider ?? AIProviderManager.currentProvider()
    }

    /// 改写一个视频内所有"可重配"分镜的台词（明星保留原声分镜由调用方剔除后传入）。
    /// - Parameters:
    ///   - inputs: 可重配分镜的 [原台词 + 时长 + 关键词]
    ///   - style: 本版差异化风格说明（来自 ad_styles）
    ///   - charsPerSecond: 目标语速（字/秒）
    /// - Returns: 与 inputs 同序的改写结果；AI 漏返回的分镜回退原台词并标记 isFallback。
    func rewrite(inputs: [RewriteSegmentInput],
                 style: String,
                 charsPerSecond: Double,
                 onProgress: ((String) -> Void)? = nil) async throws -> [RewrittenSegment] {
        guard !inputs.isEmpty else { return [] }

        onProgress?("正在构建改写 prompt…")
        let template = promptLoader.loadPrompt(named: "script_rewrite_prompt") ?? Self.fallbackTemplate
        let prompt = RewritePromptBuilder.build(template: template,
                                                inputs: inputs,
                                                style: style,
                                                charsPerSecond: charsPerSecond)

        onProgress?("正在调用 AI 改写台词…")
        let dto = try await provider.generateJSON(prompt: prompt, responseType: RewriteResultDTO.self)

        onProgress?("改写完成，正在校验字数预算…")
        return RewriteResultMapper.map(dto: dto, inputs: inputs, charsPerSecond: charsPerSecond)
    }

    /// 模板文件缺失时的兜底，避免整功能因资源问题挂掉。
    private static let fallbackTemplate = """
    你是广告文案改写专家。把下列分镜原台词逐条改写为全新说法，保持关键事实不变，字数落在各自预算区间内。
    风格：{{STYLE}}
    分镜：
    {{SEGMENTS}}
    严格输出 JSON：{"segments":[{"segmentId":"id","rewrittenText":"新台词"}]}
    """
}
