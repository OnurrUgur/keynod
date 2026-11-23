import CryptoKit
import Darwin
import Foundation
import Security

/// The key behind `SecureChannel` (see `LocalKey`).
enum ChannelKey {
    typealias Location = LocalKey.Location
    typealias Failure = LocalKey.Failure

    static let key = LocalKey(name: "channel key", service: AppIdentity.bundleID + ".channel",
                              account: "cli-channel-v1", fileName: "channel.key")

    /// Reads the key, creating it on first use. Called by the app before it listens.
    static func loadOrCreate() throws -> (key: SymmetricKey, location: Location) { try key.loadOrCreate() }

    /// Reads the key the app created. Never creates one in the keychain.
    static func load() throws -> SymmetricKey { try key.load() }
}

/// The key that seals `vault.json` (see `VaultSeal`). Only the app uses it.
enum VaultSealKey {
    static let key = LocalKey(name: "vault seal key", service: AppIdentity.bundleID + ".vault-seal",
                              account: "vault-mac-v1", fileName: "vault.key")
}

/// A 32-byte key the app keeps for itself.
///
/// - A build with a working keychain access group (Team-signed) keeps it in
///   the Data Protection Keychain: only code signed into that group can read
///   it. The app creates it; the command only reads it.
/// - A build without one (ad-hoc, CI) gets -34018 from the keychain and uses a
///   `0600` file in the data folder instead. Same use, but any process of the
///   same user can read that file, so it protects nothing against them.
///
/// Which one applies is decided by what the keychain answers (an add that
/// fails with -34018), never by reading the entitlements, and a build whose
/// keychain works never falls back to the file. Any other keychain error fails closed.
struct LocalKey {
    enum Location: Equatable {
        case keychain
        /// The keychain refused this build (-34018): the Vault can't hold secrets either.
        case file
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static let size = 32

    /// For messages, e.g. "channel key".
    let name: String
    let service: String
    let account: String
    let fileName: String

    private var probeService: String { AppIdentity.bundleID + ".probe" }
    var fileURL: URL { Store.dataDir.appendingPathComponent(fileName) }

    // MARK: App

    /// Reads the key, creating it on first use.
    func loadOrCreate() throws -> (key: SymmetricKey, location: Location) {
        switch readKeychain() {
        case .found(let data):
            return (SymmetricKey(data: data), .keychain)
        case .failed(let status):
            throw Failure("the \(name) can't be read from the keychain (\(status))")
        case .missing:
            break
        }
        let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let status = SecItemAdd(query(adding: fresh) as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return (SymmetricKey(data: fresh), .keychain)
        case errSecDuplicateItem:
            if case .found(let data) = readKeychain() { return (SymmetricKey(data: data), .keychain) }
            throw Failure("the \(name) can't be read from the keychain")
        case errSecMissingEntitlement:
            return (try fileKey(create: true), .file)
        default:
            throw Failure("the \(name) can't be stored in the keychain (\(status))")
        }
    }

    // MARK: Command

    /// Reads the key the app created. Never creates one in the keychain.
    func load() throws -> SymmetricKey {
        switch readKeychain() {
        case .found(let data):
            return SymmetricKey(data: data)
        case .failed(let status):
            throw Failure("the \(name) can't be read from the keychain (\(status))")
        case .missing:
            // Without the entitlement a read also says "not found"; only an add tells.
            guard keychainRefusesThisBuild() else {
                throw Failure("the \(name) is missing from the keychain; start the app once so it creates it")
            }
            return try fileKey(create: false)
        }
    }

    /// True when the keychain answers an add with -34018 (no keychain access
    /// group). The probe item is deleted again if the add works.
    private func keychainRefusesThisBuild() -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: UUID().uuidString,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var add = base
        add[kSecValueData as String] = Data([0])
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { SecItemDelete(base as CFDictionary) }
        return status == errSecMissingEntitlement
    }

    // MARK: Keychain

    private enum ReadResult {
        case found(Data)
        case missing
        case failed(OSStatus)
    }

    private func readKeychain() -> ReadResult {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == Self.size else { return .failed(errSecDecode) }
            return .found(data)
        case errSecItemNotFound, errSecMissingEntitlement:
            // Either way the add (or the add probe) decides; a read alone never switches to the file.
            return .missing
        default:
            return .failed(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func query(adding data: Data) -> [String: Any] {
        var q = baseQuery()
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return q
    }

    // MARK: File (builds without a keychain access group)

    /// A regular `0600` file owned by this user, exactly 32 bytes, never a symlink.
    private func fileKey(create: Bool) throws -> SymmetricKey {
        let path = fileURL.path
        if create {
            Store.makeDataDir()
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd >= 0 {
                defer { close(fd) }
                let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                let written = fresh.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
                guard written == fresh.count else { unlink(path); throw Failure("the \(name) file can't be written") }
                return SymmetricKey(data: fresh)
            }
            guard errno == EEXIST else { throw Failure("the \(name) file can't be created (\(String(cString: strerror(errno))))") }
        }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure("the \(name) file can't be opened (\(String(cString: strerror(errno))))") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0, info.st_size == off_t(Self.size) else {
            throw Failure("the \(name) file has the wrong owner, mode or size")
        }
        var bytes = [UInt8](repeating: 0, count: Self.size)
        guard read(fd, &bytes, bytes.count) == bytes.count else { throw Failure("the \(name) file can't be read") }
        return SymmetricKey(data: Data(bytes))
    }
}
