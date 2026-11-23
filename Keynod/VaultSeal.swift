import CryptoKit
import Foundation

/// `vault.json` with a seal, so metadata changed outside the app is noticed.
///
/// The titles and labels an approval names come from `vault.json`, while the
/// value it releases is the Keychain item keyed by the field id. A process of
/// the same user could edit the file (for example relabel the id of a valuable
/// field as a harmless one) and make the app load it. The seal is an
/// HMAC-SHA256, under a key only the app holds (`VaultSealKey`), over the whole
/// secrets list: secret ids, titles, field ids and labels together. A file
/// whose seal doesn't check, or that has none, is loaded but not trusted: the
/// command line releases nothing until the user confirms the vault in the app.
///
/// File shape, still plain JSON: `{"secrets":<list>,"seal":"<64 hex>"}`. The
/// seal covers exactly the bytes of `<list>`. A bare list (older builds, or a
/// vault the user hasn't confirmed) carries no seal.
enum VaultSeal {
    private static let head = Data(#"{"secrets":"#.utf8)
    private static let middle = Data(#","seal":""#.utf8)
    private static let tail = Data("\"}\n".utf8)
    private static let label = Data("keynod.vault.v1|".utf8)
    private static let hexCount = 64

    /// The file for `list` (the encoded secrets), sealed with `key`.
    static func seal(_ list: Data, key: SymmetricKey) -> Data {
        head + list + middle + Data(hex(mac(list, key)).utf8) + tail
    }

    /// The secrets list inside `file`, and whether it carries a seal that
    /// checks under `key` (false without a key, for a bare list, or for any
    /// file not exactly in the sealed shape).
    static func open(_ file: Data, key: SymmetricKey?) -> (list: Data, sealed: Bool) {
        let bytes = [UInt8](file)
        let h = [UInt8](head), m = [UInt8](middle), t = [UInt8](tail)
        guard bytes.count >= h.count + m.count + hexCount + t.count,
              Array(bytes.prefix(h.count)) == h, Array(bytes.suffix(t.count)) == t else { return (file, false) }
        let hexEnd = bytes.count - t.count
        let hexStart = hexEnd - hexCount
        let middleStart = hexStart - m.count
        guard middleStart >= h.count, Array(bytes[middleStart..<hexStart]) == m,
              let stored = unhex(String(decoding: bytes[hexStart..<hexEnd], as: UTF8.self)) else { return (file, false) }
        let list = Data(bytes[h.count..<middleStart])
        guard let key else { return (list, false) }
        return (list, HMAC<SHA256>.isValidAuthenticationCode(stored, authenticating: label + list, using: key))
    }

    /// Whether a loaded vault may be used for releases: a valid seal, or nothing in it to misname.
    static func trusted(sealed: Bool, secretCount: Int) -> Bool { sealed || secretCount == 0 }

    private static func mac(_ list: Data, _ key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: label + list, using: key))
    }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private static func unhex(_ text: String) -> Data? {
        guard text.count == hexCount else { return nil }
        var out = Data()
        var chars = Array(text.utf8)[...]
        while !chars.isEmpty {
            guard let byte = UInt8(String(decoding: chars.prefix(2), as: UTF8.self), radix: 16) else { return nil }
            out.append(byte)
            chars = chars.dropFirst(2)
        }
        return out
    }
}
