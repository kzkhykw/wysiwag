import Foundation
import Security

public enum SecretAccount: String, Sendable, CaseIterable {
    case jevKey, notionToken, googleRefreshToken, googleClientSecret
}

public struct KeychainStore: Sendable {
    public let service: String
    public init(service: String = "com.wysiwag.app") { self.service = service }

    private func query(_ account: SecretAccount) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account.rawValue,
         kSecAttrSynchronizable as String: false]
    }

    public func read(_ account: SecretAccount) throws -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw SafeFailure.keychain(status) }
        return value
    }

    public func contains(_ account: SecretAccount) -> Bool { (try? read(account)) != nil }

    public func set(_ value: String, for account: SecretAccount) throws {
        guard !value.isEmpty else { try delete(account); return }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let insert = query(account).merging(attributes) { _, new in new }
            let add = SecItemAdd(insert as CFDictionary, nil)
            guard add == errSecSuccess else { throw SafeFailure.keychain(add) }
        } else if status != errSecSuccess { throw SafeFailure.keychain(status) }
    }

    public func delete(_ account: SecretAccount) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SafeFailure.keychain(status) }
    }
}
