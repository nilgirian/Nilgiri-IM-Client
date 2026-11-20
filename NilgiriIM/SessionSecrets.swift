import Foundation
import Security

/// Keychain store for bearer tokens, session ids, and character passwords.
/// Passwords and session secrets stay out of UserDefaults.
/// Each character has their own three accounts. A build that stored one
/// untitled token, session id, and password is copied into the first
/// character's accounts and the untitled entries are removed.
enum SessionSecrets {
    static let service = "net.nilgiri.imclient"

    enum Account {
        static let token = "token"
        static let sessionId = "sessionId"
        static let password = "password"
    }

    /// Account name for one character. The character key is the lowercased name.
    static func slot(_ kind: String, _ character: String) -> String {
        let slug = character.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(kind).\(slug)"
    }

    /// Copies the single pre-multi entry into `character` when that slot is empty,
    /// then deletes the untitled accounts so the next launch does not copy them again.
    static func migrateSingleEntry(into character: String) {
        let name = character.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty == false else { return }
        for kind in [Account.token, Account.sessionId, Account.password] {
            let scoped = slot(kind, name)
            if get(scoped) == nil, let legacy = get(kind), legacy.isEmpty == false {
                set(legacy, account: scoped)
            }
            set(nil, account: kind)
        }
    }

    static func set(_ value: String?, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, value.isEmpty == false else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8),
              string.isEmpty == false else { return nil }
        return string
    }
}
