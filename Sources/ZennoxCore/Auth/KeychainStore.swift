#if canImport(Security)
import Foundation
import Security

/// Keychain-backed SecureStore. Items are device-only (not synced, not in backups) and readable
/// after first unlock so background playback can refresh tokens.
public struct KeychainStore: SecureStore {
    public enum Failure: Error, Equatable { case status(OSStatus) }
    private let service: String

    public init(service: String = "com.anbarasu.zennox.music.oauth") { self.service = service }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    public func read(_ key: String) throws -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw Failure.status(status) }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ key: String, _ value: String) throws {
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query(key) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Failure.status(addStatus) }
        } else if status != errSecSuccess {
            throw Failure.status(status)
        }
    }

    public func delete(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.status(status) }
    }
}
#endif
