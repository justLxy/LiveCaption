import Foundation
import Security

enum KeychainCredentialStore {
    private static let service = "local.xuescribe.mac.credentials"
    private static let assemblyAIAccount = "assemblyai-api-key"

    enum StoreError: LocalizedError {
        case unexpectedStatus(OSStatus)
        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                return "无法访问 macOS 钥匙串（错误 \(status)）。"
            }
        }
    }

    static var hasAssemblyAIKey: Bool { assemblyAIKey() != nil }

    static func assemblyAIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: assemblyAIAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data:data,encoding:.utf8), !key.isEmpty else { return nil }
        return key
    }

    static func saveAssemblyAIKey(_ rawKey: String) throws {
        let key = rawKey.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !key.isEmpty else { try deleteAssemblyAIKey(); return }
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: assemblyAIAccount
        ]
        let update = SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw StoreError.unexpectedStatus(update) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let add = SecItemAdd(item as CFDictionary,nil)
        guard add == errSecSuccess else { throw StoreError.unexpectedStatus(add) }
    }

    static func deleteAssemblyAIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: assemblyAIAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.unexpectedStatus(status)
        }
    }
}
