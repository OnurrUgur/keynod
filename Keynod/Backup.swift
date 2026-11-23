import CommonCrypto
import CryptoKit
import Foundation

/// Passphrase-encrypted export of every secret (metadata + concealed values).
/// File: JSON envelope, AES-GCM sealed with a PBKDF2-HMAC-SHA256 key.
enum Backup {
    static let iterations = 600_000

    struct Item: Codable {
        var secret: Secret
        /// Concealed values keyed by field id string.
        var values: [String: Data]
    }

    struct Envelope: Codable {
        var version = 1
        var kdf = "pbkdf2-sha256"
        var iterations: Int
        var salt: Data
        var sealed: Data
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func encrypt(_ items: [Item], passphrase: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plain = try encoder.encode(items)
        var salt = Data(count: 16)
        let ok = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard ok == errSecSuccess else { throw Failure(description: "Could not generate random salt.") }
        let key = try deriveKey(passphrase, salt: salt, iterations: iterations)
        let sealed = try AES.GCM.seal(plain, using: key)
        let envelope = Envelope(iterations: iterations, salt: salt, sealed: sealed.combined!)
        let out = JSONEncoder()
        out.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try out.encode(envelope)
    }

    static func decrypt(_ data: Data, passphrase: String) throws -> [Item] {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == 1, envelope.kdf == "pbkdf2-sha256",
              (100_000...10_000_000).contains(envelope.iterations) else {
            throw Failure(description: "This is not a valid Keynod vault backup file.")
        }
        let key = try deriveKey(passphrase, salt: envelope.salt, iterations: envelope.iterations)
        guard let box = try? AES.GCM.SealedBox(combined: envelope.sealed),
              let plain = try? AES.GCM.open(box, using: key) else {
            throw Failure(description: "Wrong passphrase or corrupted backup file.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Item].self, from: plain)
    }

    private static func deriveKey(_ passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let password = Array(passphrase.utf8CString.dropLast())
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), password, password.count,
                saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                &derived, derived.count
            )
        }
        guard status == kCCSuccess else { throw Failure(description: "Could not derive encryption key (\(status)).") }
        return SymmetricKey(data: derived)
    }

    /// `KEYNOD_BACKUP_SELFTEST=1` round-trips fake data through encrypt/decrypt
    /// (no Keychain involved) and quits.
    static func selfTestIfRequested() {
        guard ProcessInfo.processInfo.environment["KEYNOD_BACKUP_SELFTEST"] != nil else { return }
        let field = SecretField(label: "Private Key", concealed: true, filename: "AuthKey_X.p8")
        let item = Item(secret: Secret(title: "Test Secret", fields: [field]), values: [field.id.uuidString: Data("pem".utf8)])
        do {
            let file = try encrypt([item], passphrase: "correct horse battery")
            let back = try decrypt(file, passphrase: "correct horse battery")
            let wrong = (try? decrypt(file, passphrase: "wrong passphrase!!")) == nil
            let leaked = String(decoding: file, as: UTF8.self).contains("pem")
            let good = back.first?.values[field.id.uuidString] == Data("pem".utf8)
                && back.first?.secret.id == item.secret.id && wrong && !leaked
            print(good ? "backup selftest ok" : "backup selftest MISMATCH")
            exit(good ? 0 : 1)
        } catch {
            print("backup selftest FAILED: \(error)")
            exit(1)
        }
    }
}
