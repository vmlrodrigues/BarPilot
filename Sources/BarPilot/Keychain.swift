import Foundation
import Security

// ---------------------------------------------------------------------------
// Keychain — stores the GitHub sync token (from device-flow OAuth).
//
// Release builds use the macOS Keychain (secure, and their stable Developer ID
// signature keeps access across app updates). DEV builds are ad-hoc signed and
// get a *new* code signature on every rebuild, which invalidates Keychain access
// — so for dev builds only, the token is kept in UserDefaults instead, so it
// survives rebuilds during testing. Never ships that way.
// ---------------------------------------------------------------------------

private enum SecureTokenStore {
    static func save(_ token: String, service: String, account: String, devKey: String) {
        if Updater.isDevBuild {
            UserDefaults.standard.set(token, forKey: devKey)
            return
        }
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        var attrs = baseQuery(service: service, account: account)
        attrs[kSecValueData as String] = Data(token.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func token(service: String, account: String, devKey: String) -> String? {
        if Updater.isDevBuild { return UserDefaults.standard.string(forKey: devKey) }
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(service: String, account: String, devKey: String) {
        UserDefaults.standard.removeObject(forKey: devKey)
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
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

    static func saveToken(_ token: String) {
        SecureTokenStore.save(token, service: service, account: account, devKey: devKey)
    }

    static func token() -> String? {
        SecureTokenStore.token(service: service, account: account, devKey: devKey)
    }

    static func deleteToken() {
        SecureTokenStore.delete(service: service, account: account, devKey: devKey)
    }
}

/// The account-usage credential is deliberately independent from gist sync.
/// Turning either feature off must not silently disable the other one.
enum CreditUsageKeychain {
    private static let service = "com.victorrodrigues.barpilot.usage"
    private static let account = "github-copilot-usage-token"
    private static let devKey = "devCreditUsageToken"

    static func saveToken(_ token: String) {
        SecureTokenStore.save(token, service: service, account: account, devKey: devKey)
    }

    static func token() -> String? {
        SecureTokenStore.token(service: service, account: account, devKey: devKey)
    }

    static func deleteToken() {
        SecureTokenStore.delete(service: service, account: account, devKey: devKey)
    }
}
