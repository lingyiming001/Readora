import Foundation
import Security

public actor AICredentialStore {
    public static let shared = AICredentialStore()
    private let service: String
    public init(service: String = "local.readora.mac.ai") { self.service = service }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    public func key(account: String) throws -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else { throw CredentialError(status: status) }
        return key
    }
    public func save(_ key: String, account: String) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 4096, !value.contains("\n"), !value.contains("\r") else { throw AIError.missingKey }
        let request = query(account), data = Data(value.utf8)
        let status = SecItemUpdate(request as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = request; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw CredentialError(status: added) }
        } else if status != errSecSuccess { throw CredentialError(status: status) }
    }
    public func remove(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError(status: status) }
    }
}
private struct CredentialError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "无法访问系统钥匙串（\(status)），请确认 Mac 已解锁并允许 Readora 访问。" }
}
