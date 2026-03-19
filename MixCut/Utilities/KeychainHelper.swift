import Foundation

/// API Key 存储封装（使用 UserDefaults，避免 Keychain 弹窗）
enum KeychainHelper {

    private static let defaults = UserDefaults.standard
    private static let apiKeyPrefix = "api_key_"

    // MARK: - API Key 管理（UserDefaults）

    /// 保存 API Key
    static func saveAPIKey(_ key: String, for provider: AIProviderType) throws {
        defaults.set(key, forKey: apiKeyPrefix + provider.rawValue)
    }

    /// 获取 API Key
    static func getAPIKey(for provider: AIProviderType) -> String? {
        let key = defaults.string(forKey: apiKeyPrefix + provider.rawValue)
        return (key?.isEmpty == true) ? nil : key
    }

    /// 删除 API Key
    static func removeAPIKey(for provider: AIProviderType) throws {
        defaults.removeObject(forKey: apiKeyPrefix + provider.rawValue)
    }

    /// 是否已配置 API Key
    static func hasAPIKey(for provider: AIProviderType) -> Bool {
        guard let key = getAPIKey(for: provider) else { return false }
        return !key.isEmpty
    }

    // MARK: - 活跃提供商

    private static let activeProviderKey = "active_ai_provider"

    static var activeProvider: AIProviderType {
        get {
            guard let raw = defaults.string(forKey: activeProviderKey),
                  let type = AIProviderType(rawValue: raw) else {
                return .qwen
            }
            return type
        }
        set {
            defaults.set(newValue.rawValue, forKey: activeProviderKey)
        }
    }

    // MARK: - 自定义提供商配置

    static var customBaseURL: String {
        get { defaults.string(forKey: "custom_base_url") ?? "" }
        set { defaults.set(newValue, forKey: "custom_base_url") }
    }

    static var customModelName: String {
        get { defaults.string(forKey: "custom_model_name") ?? "" }
        set { defaults.set(newValue, forKey: "custom_model_name") }
    }

    // MARK: - 模型选择

    private static let modelKeyPrefix = "selected_model_"

    static func selectedModel(for provider: AIProviderType) -> String {
        defaults.string(forKey: modelKeyPrefix + provider.rawValue) ?? provider.defaultModel
    }

    static func setSelectedModel(_ model: String, for provider: AIProviderType) {
        defaults.set(model, forKey: modelKeyPrefix + provider.rawValue)
    }
}
