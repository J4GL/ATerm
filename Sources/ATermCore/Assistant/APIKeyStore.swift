import Foundation
import Security

/// Where the OpenRouter key is kept. See SPEC/assistant/keys.md.
public protocol APIKeyStore: AnyObject, Sendable {
    func load() -> String?
    func save(_ key: String) throws
    func delete()
}

public struct KeychainError: Error, Equatable {
    public let status: OSStatus
}

/// A generic password in the login keychain.
public final class KeychainAPIKeyStore: APIKeyStore, @unchecked Sendable {
    public let service: String
    public let account: String

    public init(service: String = "gl.j4.ATerm", account: String = "OpenRouter API Key") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() -> String? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ key: String) throws {
        let data = Data(key.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "ATerm — OpenRouter API key"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// A key kept in memory (tests).
public final class MemoryAPIKeyStore: APIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    public init(key: String? = nil) {
        self.key = key
    }

    public func load() -> String? { lock.withLock { key } }
    public func save(_ key: String) throws { lock.withLock { self.key = key } }
    public func delete() { lock.withLock { key = nil } }
}

/// The key used for requests: the stored one, else `OPENROUTER_API_KEY` when the fallback is on.
public struct APIKeySource: Sendable {
    public let store: APIKeyStore
    public let environmentFallback: Bool
    public let environment: [String: String]

    public init(store: APIKeyStore, environmentFallback: Bool = true,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.store = store
        self.environmentFallback = environmentFallback
        self.environment = environment
    }

    public func key() -> String? {
        if let key = store.load(), !key.isEmpty { return key }
        guard environmentFallback, let key = environment["OPENROUTER_API_KEY"], !key.isEmpty else { return nil }
        return key
    }
}
