import Foundation
import LocalAuthentication
import Security

/// Secret values live in the data protection keychain, never in vault.json.
/// Each item is keyed by the owning field's id and gated by user presence
/// (Touch ID, falling back to the login password).
enum Vault {
    static let service = AppIdentity.bundleID + ".secret"

    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            if status == errSecMissingEntitlement {
                return "this Keynod build has no keychain access group, so the Vault can't store or read secrets "
                    + "(\(status)); set KEYNOD_TEAM_ID in Local.xcconfig and rebuild"
            }
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "\(message) (\(status))"
        }
    }

    /// A plain, user-facing error.
    struct Message: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func set(_ data: Data, for id: UUID, requirePresence: Bool = true) throws {
        try? delete(id)
        var query = baseQuery(id)
        query[kSecValueData as String] = data
        if requirePresence {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error
            ) else { throw error!.takeRetainedValue() }
            query[kSecAttrAccessControl as String] = access
        } else {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
        // Secret fields also get a copy that only the paired iPhone can unlock.
        if requirePresence { PhoneLink.shared.didStore(data, field: id) }
    }

    /// `context` carries an earlier Touch ID approval so a grace window
    /// doesn't prompt again; nil prompts with `reason`.
    static func get(_ id: UUID, reason: String, context: LAContext? = nil) throws -> Data {
        var query = baseQuery(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let ctx = context ?? LAContext()
        ctx.localizedReason = reason
        query[kSecUseAuthenticationContext as String] = ctx
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
        return data
    }

    static func delete(_ id: UUID) throws {
        let status = SecItemDelete(baseQuery(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
        PhoneLink.shared.didDelete(field: id)
    }

    private static func baseQuery(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// `KEYNOD_VAULT_SELFTEST=1` (plain item) or `=presence` (Touch ID item)
    /// round-trips a throwaway secret and quits. Proves signing and
    /// entitlements are right before any real secret is stored.
    static func selfTestIfRequested() {
        guard let mode = ProcessInfo.processInfo.environment["KEYNOD_VAULT_SELFTEST"] else { return }
        let id = UUID()
        let value = Data("keynod-selftest-\(id.uuidString.prefix(8))".utf8)
        do {
            try set(value, for: id, requirePresence: mode == "presence")
            let read = try get(id, reason: "run the Keynod keychain self-test")
            try delete(id)
            print(read == value ? "vault selftest ok (\(mode))" : "vault selftest MISMATCH")
            exit(read == value ? 0 : 1)
        } catch {
            try? delete(id)
            print("vault selftest FAILED: \(error)")
            exit(1)
        }
    }
}
