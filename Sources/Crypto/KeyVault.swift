import Foundation
import Security

public enum VaultError: Error { case random(OSStatus), keychain(OSStatus), invalidKey }
public protocol KeyVault: AnyObject {
    func load(_ name: String) throws -> Data?
    func save(_ value: Data, name: String) throws
}

public func secureRandomKey() throws -> Data {
    var data = Data(count: 32)
    let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
    guard status == errSecSuccess else { throw VaultError.random(status) }
    return data
}

public final class KeychainVault: KeyVault {
    private let service: String
    public init(service: String) { self.service = service }
    private func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: name, kSecAttrSynchronizable as String: false]
    }
    public func load(_ name: String) throws -> Data? {
        var q = query(name); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
        guard let data = result as? Data else { throw VaultError.invalidKey }
        return data
    }
    public func save(_ value: Data, name: String) throws {
        var q = query(name); q[kSecValueData as String] = value
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        // Immutable secrets: never silently replace an existing identity/database key.
        if status == errSecDuplicateItem {
            guard try load(name) == value else { throw VaultError.invalidKey }; return
        }
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }

    /// Used only by the guarded empty-install restore flow.
    public func remove(_ name: String) throws {
        let status = SecItemDelete(query(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.keychain(status) }
    }
}
