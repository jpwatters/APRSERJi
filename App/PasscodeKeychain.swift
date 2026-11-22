import Foundation
import Security

/**
 * APRS-IS passcodes in the system Keychain, which encrypts them at rest. Passcodes depend only on the
 * base callsign, so KC9KKO-9 and KC9KKO share one entry. Nothing is written until a login is verified.
 *
 * On the Mac the passcode goes in the data-protection keychain, where access belongs to the app's signing
 * team and is never prompted for. A build without a team signature cannot use it (errSecMissingEntitlement),
 * so the file-based login keychain remains the fallback; an older entry found there is moved over once.
 */
enum PasscodeKeychain {
    private static let service = "org.aprserji.aprs-is-passcode"

    static func baseCallsign(_ callsign: String) -> String {
        String(callsign.uppercased().split(separator: "-", maxSplits: 1).first ?? "")
    }

    private static func query(_ callsign: String, modern: Bool) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: baseCallsign(callsign)]
        #if os(macOS)
        if modern { query[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return query
    }

    /** On iOS there is only one keychain, so the legacy path is never needed. */
    private static var hasLegacyKeychain: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    private static func read(_ callsign: String, modern: Bool) -> String? {
        var request = query(callsign, modern: modern)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ passcode: String, for callsign: String, modern: Bool) -> OSStatus {
        guard let data = passcode.data(using: .utf8) else { return errSecParam }
        let status = SecItemUpdate(query(callsign, modern: modern) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var item = query(callsign, modern: modern)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "APRSERJi APRS-IS passcode (\(baseCallsign(callsign)))"
        return SecItemAdd(item as CFDictionary, nil)
    }

    static func load(for callsign: String) -> String? {
        guard !baseCallsign(callsign).isEmpty else { return nil }
        if let passcode = read(callsign, modern: true) { return passcode }
        guard hasLegacyKeychain, let legacy = read(callsign, modern: false) else { return nil }
        // Move an entry saved by an earlier build into the prompt-free keychain, if this build can use it.
        if write(legacy, for: callsign, modern: true) == errSecSuccess {
            SecItemDelete(query(callsign, modern: false) as CFDictionary)
        }
        return legacy
    }

    @discardableResult
    static func save(_ passcode: String, for callsign: String) -> Bool {
        guard !baseCallsign(callsign).isEmpty else { return false }
        if write(passcode, for: callsign, modern: true) == errSecSuccess { return true }
        return hasLegacyKeychain && write(passcode, for: callsign, modern: false) == errSecSuccess
    }

    static func delete(for callsign: String) {
        SecItemDelete(query(callsign, modern: true) as CFDictionary)
        if hasLegacyKeychain { SecItemDelete(query(callsign, modern: false) as CFDictionary) }
    }
}
