import CryptoKit
import XCTest

final class VaultSealTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)
    private let list = Data(#"[{"fields":[{"concealed":true,"id":"6F1C…","label":"Live Key"}],"id":"A1","text":"Stripe"}]"#.utf8)

    func testSealedFileOpensUnderTheSameKey() {
        let file = VaultSeal.seal(list, key: key)
        let opened = VaultSeal.open(file, key: key)
        XCTAssertTrue(opened.sealed)
        XCTAssertEqual(opened.list, list)
        // Still plain JSON, with the list inside.
        let object = try? JSONSerialization.jsonObject(with: file) as? [String: Any]
        XCTAssertNotNil(object?["secrets"])
        XCTAssertEqual((object?["seal"] as? String)?.count, 64)
    }

    func testAnyChangeToTheListBreaksTheSeal() {
        let file = VaultSeal.seal(list, key: key)
        // Relabel the valuable field as a harmless one, keeping its id (the attack).
        let edited = String(decoding: file, as: UTF8.self)
            .replacingOccurrences(of: #""label":"Live Key""#, with: #""label":"dummy""#)
            .replacingOccurrences(of: #""text":"Stripe""#, with: #""text":"Test token""#)
        let opened = VaultSeal.open(Data(edited.utf8), key: key)
        XCTAssertFalse(opened.sealed)
        XCTAssertTrue(String(decoding: opened.list, as: UTF8.self).contains("Test token"), "the edited list is still readable")
        // One flipped byte anywhere in the list.
        var flipped = [UInt8](file)
        flipped[20] ^= 0x01
        XCTAssertFalse(VaultSeal.open(Data(flipped), key: key).sealed)
    }

    func testAnotherKeyOrNoKeyIsNotTrusted() {
        let file = VaultSeal.seal(list, key: key)
        XCTAssertFalse(VaultSeal.open(file, key: SymmetricKey(size: .bits256)).sealed)
        let noKey = VaultSeal.open(file, key: nil)
        XCTAssertFalse(noKey.sealed)
        XCTAssertEqual(noKey.list, list)
    }

    func testABareListOrADamagedSealIsNotTrusted() {
        // What older builds wrote, and what an unconfirmed vault is saved as.
        let bare = VaultSeal.open(list, key: key)
        XCTAssertFalse(bare.sealed)
        XCTAssertEqual(bare.list, list)
        // A seal that isn't 64 hex digits, or a file cut short.
        let file = String(decoding: VaultSeal.seal(list, key: key), as: UTF8.self)
        let shortSeal = file.replacingOccurrences(of: #","seal":""#, with: #","seal":"00"#)
        XCTAssertFalse(VaultSeal.open(Data(shortSeal.utf8), key: key).sealed)
        XCTAssertFalse(VaultSeal.open(Data(file.utf8.dropLast(5)), key: key).sealed)
        let notHex = file.replacingOccurrences(of: #"[0-9a-f]{64}"#, with: String(repeating: "z", count: 64),
                                               options: .regularExpression)
        XCTAssertFalse(VaultSeal.open(Data(notHex.utf8), key: key).sealed)
    }

    func testASealCannotBeMovedToAnotherList() {
        let sealed = String(decoding: VaultSeal.seal(list, key: key), as: UTF8.self)
        let seal = String(sealed.suffix(3 + 64).prefix(64))
        let other = Data(#"[{"fields":[],"id":"B2","text":"Other"}]"#.utf8)
        let forged = Data(#"{"secrets":"#.utf8) + other + Data(#","seal":"\#(seal)"}"#.utf8) + Data("\n".utf8)
        XCTAssertFalse(VaultSeal.open(forged, key: key).sealed)
    }

    func testOnlyAnEmptyVaultIsTrustedWithoutASeal() {
        XCTAssertTrue(VaultSeal.trusted(sealed: true, secretCount: 3))
        XCTAssertTrue(VaultSeal.trusted(sealed: false, secretCount: 0))
        XCTAssertFalse(VaultSeal.trusted(sealed: false, secretCount: 1))
    }
}
