import Foundation
import Security

// ---------------------------------------------------------------------------
// Keychain — stores the GitHub sync token (from device-flow OAuth).
//
// Credentials always use the macOS Keychain. Older development builds briefly
// stored tokens in UserDefaults; token() performs a one-time best-effort migration
// and removes that plaintext value whether or not Keychain accepts it.
// ---------------------------------------------------------------------------

private enum SecureTokenStore {
    static func save(_ token: String, service: String, account: String, devKey: String) -> Bool {
        guard !token.isEmpty else { return false }
        let query = baseQuery(service: service, account: account)
        let values: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { return false }
        UserDefaults.standard.removeObject(forKey: devKey)
        return keychainToken(service: service, account: account) == token
    }

    static func token(service: String, account: String, devKey: String) -> String? {
        if let stored = keychainToken(service: service, account: account) {
            // Also scrub a duplicate left by a short-lived development build that
            // wrote UserDefaults before the Keychain-backed version was installed.
            UserDefaults.standard.removeObject(forKey: devKey)
            return stored
        }
        guard let legacy = UserDefaults.standard.string(forKey: devKey) else { return nil }
        let migrated = save(legacy, service: service, account: account, devKey: devKey)
        // Never leave a credential in plaintext just because migration failed.
        UserDefaults.standard.removeObject(forKey: devKey)
        return migrated ? legacy : nil
    }

    private static func keychainToken(service: String, account: String) -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(service: String, account: String, devKey: String) -> Bool {
        UserDefaults.standard.removeObject(forKey: devKey)
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { return false }
        return keychainToken(service: service, account: account) == nil
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

enum Keychain {
    private static let service = "com.victorrodrigues.barpilot.sync"
    private static let account = "github-gist-token"
    private static let devKey = "devSyncToken"

    static func saveToken(_ token: String) -> Bool {
        SecureTokenStore.save(token, service: service, account: account, devKey: devKey)
    }

    static func token() -> String? {
        SecureTokenStore.token(service: service, account: account, devKey: devKey)
    }

    static func deleteToken() -> Bool {
        SecureTokenStore.delete(service: service, account: account, devKey: devKey)
    }
}

/// The account-usage credential is deliberately independent from gist sync.
/// Turning either feature off must not silently disable the other one.
enum CreditUsageKeychain {
    private static let service = "com.victorrodrigues.barpilot.usage"
    private static let account = "github-copilot-usage-token"
    private static let devKey = "devCreditUsageToken"

    static func saveToken(_ token: String) -> Bool {
        SecureTokenStore.save(token, service: service, account: account, devKey: devKey)
    }

    static func token() -> String? {
        SecureTokenStore.token(service: service, account: account, devKey: devKey)
    }

    static func deleteToken() -> Bool {
        SecureTokenStore.delete(service: service, account: account, devKey: devKey)
    }
}
