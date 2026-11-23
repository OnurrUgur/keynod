import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The iPhone's three Secure Enclave keys (`approve`, `field`, `deny`) and its record of the paired Mac.
///
/// On a real device the keys live in the Secure Enclave: `approve` and `field` require Face ID
/// (`.biometryCurrentSet`), while `deny` needs no Face ID so a notification action can deny quickly.
/// In the iOS Simulator, software keys stand in so the flow can still be tested.
enum PhoneKeys {
    private static let service = Bundle.main.bundleIdentifier ?? "dev.keynod.phone"

    private enum Account: String, CaseIterable {
        case approve, field, deny, mac
    }

    private enum Storage: UInt8 {
        case enclave = 0x01
        case software = 0x02
    }

    struct PublicKeys {
        let approve: Data
        let field: Data
        let deny: Data
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) { self.description = description }

        init(status: OSStatus) {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            description = "Keychain error: \(message) (\(status))"
        }

        static let unusableKeys = Failure(
            "This iPhone's keys can't be used any more, probably because Face ID changed. Unpair and pair again.")
    }

    static func createKeys() throws -> PublicKeys {
        deleteKeys()
        do {
            #if targetEnvironment(simulator)
            return try createSoftwareKeys()
            #else
            return try createEnclaveKeys()
            #endif
        } catch {
            deleteKeys()
            throw error
        }
    }

    private static func createEnclaveKeys() throws -> PublicKeys {
        guard SecureEnclave.isAvailable else {
            throw Failure("This iPhone has no Secure Enclave, which Keynod needs to keep its keys safe.")
        }
        let guarded = try accessControl(kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                        [.privateKeyUsage, .biometryCurrentSet])
        let open = try accessControl(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage)
        let approve = try SecureEnclave.P256.Signing.PrivateKey(accessControl: guarded)
        let field = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: guarded)
        let deny = try SecureEnclave.P256.Signing.PrivateKey(accessControl: open)
        try save(.enclave, approve.dataRepresentation, as: .approve)
        try save(.enclave, field.dataRepresentation, as: .field)
        try save(.enclave, deny.dataRepresentation, as: .deny)
        return PublicKeys(approve: approve.publicKey.x963Representation,
                          field: field.publicKey.x963Representation,
                          deny: deny.publicKey.x963Representation)
    }

    #if targetEnvironment(simulator)
    private static func createSoftwareKeys() throws -> PublicKeys {
        let approve = P256.Signing.PrivateKey()
        let field = P256.KeyAgreement.PrivateKey()
        let deny = P256.Signing.PrivateKey()
        try save(.software, approve.rawRepresentation, as: .approve)
        try save(.software, field.rawRepresentation, as: .field)
        try save(.software, deny.rawRepresentation, as: .deny)
        return PublicKeys(approve: approve.publicKey.x963Representation,
                          field: field.publicKey.x963Representation,
                          deny: deny.publicKey.x963Representation)
    }
    #endif

    private static func accessControl(_ protection: CFString, _ flags: SecAccessControlCreateFlags) throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, protection, flags, &error) else {
            if let error { throw error.takeRetainedValue() as Error }
            throw Failure("Couldn't set up key protection on this iPhone.")
        }
        return access
    }

    static func approveKey(context: LAContext) throws -> LinkSigner {
        let (storage, bytes) = try loadKey(.approve)
        switch storage {
        case .enclave:
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: bytes, authenticationContext: context)
        case .software:
            return try softwareSigner(bytes)
        }
    }

    static func fieldKey(context: LAContext) throws -> LinkAgreer {
        let (storage, bytes) = try loadKey(.field)
        switch storage {
        case .enclave:
            return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: bytes, authenticationContext: context)
        case .software:
            return try softwareAgreer(bytes)
        }
    }

    static func denyKey() throws -> LinkSigner {
        let (storage, bytes) = try loadKey(.deny)
        switch storage {
        case .enclave:
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: bytes)
        case .software:
            return try softwareSigner(bytes)
        }
    }

    private static func softwareSigner(_ bytes: Data) throws -> LinkSigner {
        #if targetEnvironment(simulator)
        return try P256.Signing.PrivateKey(rawRepresentation: bytes)
        #else
        throw Failure.unusableKeys
        #endif
    }

    private static func softwareAgreer(_ bytes: Data) throws -> LinkAgreer {
        #if targetEnvironment(simulator)
        return try P256.KeyAgreement.PrivateKey(rawRepresentation: bytes)
        #else
        throw Failure.unusableKeys
        #endif
    }

    private static func loadKey(_ account: Account) throws -> (Storage, Data) {
        guard let blob = try read(account), let tag = blob.first, let storage = Storage(rawValue: tag) else {
            throw Failure("This iPhone's keys are missing. Unpair and pair again.")
        }
        return (storage, Data(blob.dropFirst()))
    }

    static func saveMac(_ mac: PairedMac) throws {
        try store(try LinkCoding.encode(mac), as: .mac)
    }

    static func loadMac() throws -> PairedMac? {
        guard let data = try read(.mac) else { return nil }
        return try? LinkCoding.decode(PairedMac.self, from: data)
    }

    static func deleteKeys() {
        for account in [Account.approve, .field, .deny] { remove(account) }
    }

    static func deleteAll() {
        for account in Account.allCases { remove(account) }
    }

    private static func query(_ account: Account) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func save(_ storage: Storage, _ representation: Data, as account: Account) throws {
        try store(Data([storage.rawValue]) + representation, as: account)
    }

    private static func store(_ data: Data, as account: Account) throws {
        var attributes = query(account)
        SecItemDelete(attributes as CFDictionary)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    private static func read(_ account: Account) throws -> Data? {
        var attributes = query(account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
        return data
    }

    private static func remove(_ account: Account) {
        let status = SecItemDelete(query(account) as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            phoneLog("couldn't remove \(account.rawValue) from the keychain (\(status))")
        }
    }
}
