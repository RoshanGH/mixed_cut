import Foundation

/// AI 提供商工厂
enum AIProviderManager {

    /// 根据当前设置创建 AI 提供商实例
    /// 优先使用 activeProvider；如果它没有 key，自动回退到有 key 的提供商
    static func currentProvider() -> any AIProvider {
        let providerType = KeychainHelper.activeProvider

        if KeychainHelper.hasAPIKey(for: providerType) {
            MixLog.info("使用活跃提供商: \(providerType.displayName)")
            return createProvider(for: providerType)
        }

        // 回退：查找有 key 的提供商
        for fallback in AIProviderType.allCases where fallback != providerType {
            if KeychainHelper.hasAPIKey(for: fallback) {
                MixLog.info("活跃提供商 \(providerType.displayName) 无 key，回退到 \(fallback.displayName)")
                return createProvider(for: fallback)
            }
        }

        // 都没有 key，返回活跃提供商（会在请求时报错）
        MixLog.error("所有提供商均未配置 API Key！")
        return createProvider(for: providerType)
    }

    /// 创建指定类型的 AI 提供商
    static func createProvider(for type: AIProviderType) -> any AIProvider {
        let model = KeychainHelper.selectedModel(for: type)
        let apiKey = KeychainHelper.getAPIKey(for: type) ?? ""
        MixLog.info("创建 AI 客户端: provider=\(type.displayName), model=\(model), hasKey=\(!apiKey.isEmpty)")
        return OpenAICompatibleClient(providerType: type, apiKey: apiKey, modelName: model)
    }
}
