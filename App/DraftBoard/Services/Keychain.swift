import Foundation
import Security

/// API keys live in the Keychain, never in UserDefaults or the source.
enum Keychain {
    enum Key: String, CaseIterable {
        case massive = "massive.apiKey"
        case fmp = "fmp.apiKey"
    }

    private static let service = Bundle.main.bundleIdentifier ?? "DraftBoard"

    private static func query(_ key: Key) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key.rawValue]
    }

    static func get(_ key: Key) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves the value, or deletes it when empty.
    @discardableResult
    static func set(_ value: String, for key: Key) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete(query(key) as CFDictionary)
        guard !trimmed.isEmpty else { return true }
        var q = query(key)
        q[kSecValueData as String] = Data(trimmed.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func has(_ key: Key) -> Bool { !(get(key) ?? "").isEmpty }
}
