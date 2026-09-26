import Foundation
import Security

extension Notification.Name {
    static let aiSettingsDidChange = Notification.Name("dev.touchbarchat.aiSettingsDidChange")
}

/// The complete configuration for one user-initiated AI request. The endpoint is the
/// exact Chat Completions URL entered by the user; callers must not append a path.
struct AIRequestConfiguration: Sendable {
    let endpoint: URL
    let model: String
    let profile: String
    let apiKey: String?
}

struct AISettingsDraft {
    let endpointText: String
    let model: String
    let profile: String
    let hasSavedAPIKey: Bool
}

enum AISettingsError: LocalizedError {
    case endpointRequired
    case endpointInvalid
    case endpointContainsQuery
    case insecureEndpoint
    case modelRequired
    case apiKeyRequired
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .endpointRequired:
            return L10n.text("请填写 Chat Completions 接口的完整 URL。")
        case .endpointInvalid:
            return L10n.text("接口 URL 无效。请填写包含主机名和路径的完整地址。")
        case .endpointContainsQuery:
            return L10n.text("接口 URL 不应包含 ? 参数。请勿将密钥放在 URL 中；请使用 API Key 输入框。")
        case .insecureEndpoint:
            return L10n.text("远程接口必须使用 HTTPS；仅 localhost 或本机回环地址可使用 HTTP。")
        case .modelRequired:
            return L10n.text("请填写模型名称。")
        case .apiKeyRequired:
            return L10n.text("远程 HTTPS 接口需要 API Key；本机回环地址的 HTTP 或 HTTPS 接口可以不填。")
        case .keychain(let status):
            // Keep the OSStatus numeric code actionable without ever exposing
            // the secret value stored behind that Keychain item.
            return L10n.text("无法访问 macOS 钥匙串（错误码 %d）。请检查钥匙串后重试。", Int(status))
        }
    }
}

/// Non-secret settings live in UserDefaults. The API key lives only in the macOS
/// Keychain and is never written to defaults, diagnostics, or the application log.
@MainActor
final class AISettingsStore {
    static let shared = AISettingsStore()

    private let defaults: UserDefaults
    private let endpointKey = "ai.chatCompletionsEndpoint"
    private let modelKey = "ai.model"
    private let profileKey = "ai.personalProfile"
    private let keychainService = "dev.touchbarchat.ai-api-key"
    private let keychainAccount = "configured-provider"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func currentDraft() throws -> AISettingsDraft {
        AISettingsDraft(
            endpointText: defaults.string(forKey: endpointKey) ?? "",
            model: defaults.string(forKey: modelKey) ?? "",
            profile: defaults.string(forKey: profileKey) ?? "",
            hasSavedAPIKey: try readAPIKey() != nil
        )
    }

    func loadValidatedConfiguration() throws -> AIRequestConfiguration {
        let endpointText = defaults.string(forKey: endpointKey) ?? ""
        let model = defaults.string(forKey: modelKey) ?? ""
        let profile = defaults.string(forKey: profileKey) ?? ""
        let endpoint = try Self.validateEndpoint(endpointText)
        let apiKey = try readAPIKey()
        if Self.requiresAPIKey(for: endpoint) && apiKey == nil {
            throw AISettingsError.apiKeyRequired
        }
        return AIRequestConfiguration(
            endpoint: endpoint,
            model: try Self.validateModel(model),
            profile: profile,
            apiKey: apiKey
        )
    }

    /// A blank apiKeyInput preserves the saved key unless clearSavedAPIKey is true.
    /// A newly entered key takes precedence over the clear flag.
    func save(
        endpointText: String,
        model: String,
        profile: String,
        apiKeyInput: String,
        clearSavedAPIKey: Bool = false
    ) throws {
        let endpoint = try Self.validateEndpoint(endpointText)
        let validatedModel = try Self.validateModel(model)
        let newKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.requiresAPIKey(for: endpoint) && newKey.isEmpty {
            let savedKey = try readAPIKey()
            if clearSavedAPIKey || savedKey == nil {
                throw AISettingsError.apiKeyRequired
            }
        }

        // Commit the Keychain operation first, so an access failure does not leave
        // the public settings half-updated.
        if !newKey.isEmpty {
            try writeAPIKey(newKey)
        } else if clearSavedAPIKey {
            try deleteAPIKey()
        }

        defaults.set(endpoint.absoluteString, forKey: endpointKey)
        defaults.set(validatedModel, forKey: modelKey)
        defaults.set(profile.trimmingCharacters(in: .whitespacesAndNewlines), forKey: profileKey)
        NotificationCenter.default.post(name: .aiSettingsDidChange, object: nil)
    }

    static func validateEndpoint(_ input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AISettingsError.endpointRequired }
        if URLComponents(string: trimmed)?.query != nil {
            throw AISettingsError.endpointContainsQuery
        }
        guard let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(),
            !host.isEmpty,
            !components.path.isEmpty,
            components.user == nil,
            components.password == nil,
            components.fragment == nil,
            let url = components.url
        else {
            throw AISettingsError.endpointInvalid
        }

        let isLoopback = Self.isLoopbackHost(host)
        guard scheme == "https" || (scheme == "http" && isLoopback) else {
            throw AISettingsError.insecureEndpoint
        }
        return url
    }

    private static func requiresAPIKey(for endpoint: URL) -> Bool {
        !isLoopbackHost(endpoint.host ?? "")
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1"
    }

    private static func validateModel(_ input: String) throws -> String {
        let model = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw AISettingsError.modelRequired }
        return model
    }

    private var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private func readAPIKey() throws -> String? {
        var query = keychainQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
            let data = result as? Data,
            let key = String(data: data, encoding: .utf8)
        else {
            throw AISettingsError.keychain(status)
        }
        return key.isEmpty ? nil : key
    }

    private func writeAPIKey(_ key: String) throws {
        let data = Data(key.utf8)
        let update = [kSecValueData as String: data] as CFDictionary
        let updateStatus = SecItemUpdate(keychainQuery as CFDictionary, update)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw AISettingsError.keychain(updateStatus)
        }

        var add = keychainQuery
        add[kSecValueData as String] = data
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AISettingsError.keychain(addStatus)
        }
    }

    private func deleteAPIKey() throws {
        let status = SecItemDelete(keychainQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AISettingsError.keychain(status)
        }
    }
}
