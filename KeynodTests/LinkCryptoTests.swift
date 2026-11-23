import CryptoKit
import XCTest

private func XCTAssertThrowsLinkError<T>(_ expression: @autoclosure () throws -> T, _ expected: LinkError,
                                         _ message: @autoclosure () -> String = "",
                                         file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try expression(), message(), file: file, line: line) { error in
        guard let error = error as? LinkError else {
            return XCTFail("expected \(expected), got \(error) \(message())", file: file, line: line)
        }
        switch (error, expected) {
        case (.malformed, .malformed): break
        default: XCTAssertEqual(error, expected, message(), file: file, line: line)
        }
    }
}

private func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

private func flipped(_ data: Data, at index: Int) -> Data {
    var copy = Data(data)
    copy[copy.startIndex + index] ^= 0x01
    return copy
}

private func noise(_ count: Int) -> Data {
    var x: UInt32 = 0x1234_5678
    return Data((0..<count).map { i in
        x = x &* 1_664_525 &+ 1_013_904_223
        return i < 256 ? UInt8(i) : UInt8(truncatingIfNeeded: x >> 24)
    })
}

private extension Data {
    init(hex: String) {
        let digits = Array(hex)
        self.init(stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! })
    }
}

final class LinkCryptoTests: XCTestCase {
    private let field = UUID()
    private let request = UUID()
    private let phone = P256.KeyAgreement.PrivateKey()

    private func protect(_ value: Data, as id: UUID? = nil,
                         for owner: P256.KeyAgreement.PrivateKey? = nil) throws -> (copy: LinkCrypto.Protected, key: SymmetricKey) {
        let id = id ?? field
        let owner = owner ?? phone
        let copy = try LinkCrypto.protect(value, field: id, for: owner.publicKey)
        return (copy, try LinkCrypto.fieldKey(field: id, eph: copy.eph, with: owner))
    }

    func testFieldCopyRoundTripsText() throws {
        let value = Data("p@ssw0rd — ünïcode ✓\nsecond line".utf8)
        let (copy, key) = try protect(value)
        XCTAssertEqual(try LinkCrypto.open(copy, field: field, key: key), value)
    }

    func testFieldCopyRoundTripsBinary4KB() throws {
        let value = noise(4096)
        let (copy, key) = try protect(value)
        XCTAssertEqual(copy.eph.count, 65)
        XCTAssertEqual(copy.box.count, value.count + 12 + 16)
        XCTAssertEqual(try LinkCrypto.open(copy, field: field, key: key), value)
    }

    func testFieldCopyRoundTripsAnEmptyValue() throws {
        let (copy, key) = try protect(Data())
        XCTAssertEqual(try LinkCrypto.open(copy, field: field, key: key), Data())
    }

    func testFieldCopyDoesNotContainThePlaintext() throws {
        let (copy, _) = try protect(Data(repeating: 0x41, count: 64))
        XCTAssertNil(copy.box.range(of: Data(repeating: 0x41, count: 16)))
    }

    func testEveryCopyGetsItsOwnEphemeralKeyAndNonce() throws {
        let value = Data("same value".utf8)
        let (a, keyA) = try protect(value)
        let (b, keyB) = try protect(value)
        XCTAssertNotEqual(a.eph, b.eph)
        XCTAssertNotEqual(a.box, b.box)
        XCTAssertNotEqual(bytes(keyA), bytes(keyB))
        XCTAssertThrowsLinkError(try LinkCrypto.open(a, field: field, key: keyB), .badKey)
    }

    func testOpenFailsForAnotherFieldID() throws {
        let other = UUID()
        let (copy, key) = try protect(Data("value".utf8))
        let wrongKey = try LinkCrypto.fieldKey(field: other, eph: copy.eph, with: phone)
        XCTAssertNotEqual(bytes(key), bytes(wrongKey))
        XCTAssertThrowsLinkError(try LinkCrypto.open(copy, field: field, key: wrongKey), .badKey)
        XCTAssertThrowsLinkError(try LinkCrypto.open(copy, field: other, key: key), .badKey)
    }

    func testAnotherPhonesFieldKeyCannotOpenTheCopy() throws {
        let (copy, _) = try protect(Data("value".utf8))
        let stranger = P256.KeyAgreement.PrivateKey()
        let key = try LinkCrypto.fieldKey(field: field, eph: copy.eph, with: stranger)
        XCTAssertThrowsLinkError(try LinkCrypto.open(copy, field: field, key: key), .badKey)
    }

    func testAnyChangeToTheBoxFailsToOpen() throws {
        let (copy, key) = try protect(noise(40))
        for i in 0..<copy.box.count {
            let tampered = LinkCrypto.Protected(eph: copy.eph, box: flipped(copy.box, at: i))
            XCTAssertThrowsLinkError(try LinkCrypto.open(tampered, field: field, key: key), .badKey, "box byte \(i)")
        }
    }

    func testSealedFieldKeyRoundTripsAndRejectsTampering() throws {
        let reply = P256.KeyAgreement.PrivateKey()
        let key = SymmetricKey(size: .bits256)
        let sealed = try LinkCrypto.seal(key, request: request, field: field, to: reply.publicKey)
        XCTAssertEqual(bytes(try LinkCrypto.open(sealed, request: request, with: reply)), bytes(key))
        XCTAssertThrowsLinkError(try LinkCrypto.open(sealed, request: UUID(), with: reply), .badKey)
        XCTAssertThrowsLinkError(try LinkCrypto.open(sealed, request: request, with: P256.KeyAgreement.PrivateKey()), .badKey)
    }

    func testPairingCodeAndMAC() {
        let macKey = Data(repeating: 4, count: 65)
        let reply = Data("golden reply".utf8)
        let code = LinkCrypto.pairingCode(macKey: macKey, reply: reply)
        XCTAssertEqual(code, "383 188")

        let mac = LinkCrypto.pairingMAC(Data("Hi There".utf8), secret: Data(repeating: 0x0b, count: 20))
        XCTAssertEqual(mac, Data(hex: "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"))
    }

    func testQRTextRoundTripsAndRejectsBadPrefixOrTruncation() throws {
        let offer = PairOffer(id: UUID(), macName: "Dev MacBook Pro",
                              macKey: P256.Signing.PrivateKey().publicKey.x963Representation,
                              secret: LinkCrypto.randomBytes(32),
                              expires: Date(timeIntervalSince1970: 1_750_000_600))
        let text = offer.qrText
        XCTAssertTrue(text.hasPrefix(Link.pairingPrefix))
        XCTAssertEqual(try PairOffer(qrText: text), offer)
        XCTAssertEqual(try PairOffer(qrText: " \n\(text)\r\n "), offer)
        XCTAssertThrowsLinkError(try PairOffer(qrText: "wrong-prefix:abc"), .malformed(""))
        XCTAssertThrowsLinkError(try PairOffer(qrText: String(text.prefix(15))), .malformed(""))
    }
}
