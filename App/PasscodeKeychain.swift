import Foundation
import Security

/**
 * APRS-IS passcodes in the system Keychain, which encrypts them at rest. Passcodes depend only on the
 * base callsign, so KC9KKO-9 and KC9KKO share one entry. Nothing is written until a login is verified.
 */
enum PasscodeKeychain {
    private static let service = "org.aprserji.aprs-is-passcode"

    static func baseCallsign(_ callsign: String) -> String {
        String(callsign.uppercased().split(separator: "-", maxSplits: 1).first ?? "")
    }

    private static func query(_ callsign: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: baseCallsign(callsign)]
    }

    static func load(for callsign: String) -> String? {
        guard !baseCallsign(callsign).isEmpty else { return nil }
        var request = query(callsign)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ passcode: String, for callsign: String) -> Bool {
        guard !baseCallsign(callsign).isEmpty, let data = passcode.data(using: .utf8) else { return false }
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query(callsign) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query(callsign)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "APRSERJi APRS-IS passcode (\(baseCallsign(callsign)))"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(for callsign: String) {
        SecItemDelete(query(callsign) as CFDictionary)
    }
}
