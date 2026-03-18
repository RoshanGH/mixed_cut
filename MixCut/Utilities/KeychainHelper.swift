import Foundation
import Security

/// API Key 存储封装（使用 macOS Keychain，安全存储）
enum KeychainHelper {

    private static let defaults = UserDefaults.standard
    private static let service = "com.mixcut.app"

    // MARK: - 多提供商 API Key 管理（Keychain）

    /// 保存 API Key
    static func saveAPIKey(_ key: String, for provider: AIProviderType) throws {
        guard let data = key.data(using: .utf8) else { return }
        let account = provider.rawValue

        // 先删除旧值
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // 写入新值
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            MixLog.error("Keychain 写入失败: \(status)")
        }

        // 迁移：清除 UserDefaults 中的旧明文存储
        defaults.removeObject(forKey: "api_key_" + provider.rawValue)
    }

    /// 获取 API Key
    static func getAPIKey(for provider: AIProviderType) -> String? {
        let account = provider.rawValue
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }

        // 兼容迁移：如果 Keychain 中没有，尝试从 UserDefaults 读取并迁移
        if let oldKey = defaults.string(forKey: "api_key_" + provider.rawValue), !oldKey.isEmpty {
            try? saveAPIKey(oldKey, for: provider)  // 迁移到 Keychain
            return oldKey
        }

        return nil
    }

    /// 删除 API Key
    static func removeAPIKey(for provider: AIProviderType) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue
        ]
        SecItemDelete(query as CFDictionary)
        // 同时清除 UserDefaults 中的旧值
        defaults.removeObject(forKey: "api_key_" + provider.rawValue)
    }

    /// 是否已配置 API Key
    static func hasAPIKey(for provider: AIProviderType) -> Bool {
        guard let key = getAPIKey(for: provider) else { return false }
        return !key.isEmpty
    }

    // MARK: - 活跃提供商（非敏感，继续用 UserDefaults）

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

    // MARK: - 模型选择（非敏感，继续用 UserDefaults）

    private static let modelKeyPrefix = "selected_model_"

    static func selectedModel(for provider: AIProviderType) -> String {
        defaults.string(forKey: modelKeyPrefix + provider.rawValue) ?? provider.defaultModel
    }

    static func setSelectedModel(_ model: String, for provider: AIProviderType) {
        defaults.set(model, forKey: modelKeyPrefix + provider.rawValue)
    }
}
