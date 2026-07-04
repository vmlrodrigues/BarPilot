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

enum Keychain {
    private static let service = "com.victorrodrigues.barpilot.sync"
    private static let account = "github-gist-token"
    private static let devKey = "devSyncToken"

    static func saveToken(_ token: String) {
        if Updater.isDevBuild { UserDefaults.standard.set(token, forKey: devKey); return }
        keychainSave(token)
    }

    static func token() -> String? {
        if Updater.isDevBuild { return UserDefaults.standard.string(forKey: devKey) }
        return keychainToken()
    }

    static func deleteToken() {
        UserDefaults.standard.removeObject(forKey: devKey)
        keychainDelete()
    }

    // MARK: Keychain (release builds)

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func keychainSave(_ token: String) {
        SecItemDelete(baseQuery as CFDictionary)
        var attrs = baseQuery
        attrs[kSecValueData as String] = Data(token.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }

    private static func keychainToken() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainDelete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
