import Foundation
import Security

enum KeychainError: LocalizedError {
    case notFound
    case unexpectedData
    case unhandled(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notFound: return "Keychain item not found"
        case .unexpectedData: return "Keychain item is not UTF-8 text"
        case .unhandled(let s): return "Keychain error \(s)"
        }
    }
}

enum Keychain {
    static func readGenericPassword(service: String, account: String? = nil) throws -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let s = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedData
            }
            return s
        case errSecItemNotFound:
            throw KeychainError.notFound
        default:
            throw KeychainError.unhandled(status)
        }
    }
}
