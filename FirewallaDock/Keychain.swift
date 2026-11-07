import Foundation
import Security

enum Keychain {
    private static let service = "FirewallaDock"
    private static let account = "msp-api-token"

    static func load() -> String {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func save(_ token: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !token.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
