import CryptoKit
import XCTest

final class LinkModeTests: XCTestCase {
    private let mac = P256.Signing.PrivateKey()
    private let phoneDeny = P256.Signing.PrivateKey()
    private var keys: [Data] { [mac.publicKey.x963Representation, phoneDeny.publicKey.x963Representation] }

    func testModeSignedByEitherDeviceVerifies() throws {
        for (signer, by) in [(mac, "mac"), (phoneDeny, "phone")] {
            let signed = try LinkFlow.makeMode(remote: true, by: by, signer: signer)
            let mode = try LinkFlow.checkMode(payload: signed.payload, signature: signed.signature, keys: keys)
            XCTAssertTrue(mode.remote)
            XCTAssertEqual(mode.by, by)
        }
    }

    func testModeSignedByStrangerIsRejected() throws {
        let signed = try LinkFlow.makeMode(remote: true, by: "phone", signer: P256.Signing.PrivateKey())
        XCTAssertThrowsError(try LinkFlow.checkMode(payload: signed.payload, signature: signed.signature, keys: keys)) {
            XCTAssertEqual($0 as? LinkError, .badSignature)
        }
    }

    func testTamperedModeIsRejected() throws {
        let signed = try LinkFlow.makeMode(remote: false, by: "phone", signer: phoneDeny)
        let decoded = try LinkCoding.decode(LinkMode.self, from: signed.payload)
        let flipped = try LinkCoding.encode(LinkMode(remote: true, at: decoded.at, by: "phone"))
        XCTAssertThrowsError(try LinkFlow.checkMode(payload: flipped, signature: signed.signature, keys: keys))
    }

    func testAwakeStateSignedByMacVerifies() throws {
        let until = Date().addingTimeInterval(3600)
        let signed = try LinkFlow.makeAwake(until: until, signer: mac)
        let awake = try LinkFlow.checkAwake(payload: signed.payload, signature: signed.signature,
                                            macKey: mac.publicKey.x963Representation)
        XCTAssertEqual(awake.until?.timeIntervalSince1970 ?? 0, until.timeIntervalSince1970, accuracy: 1)
        XCTAssertNotNil(awake.activeUntil())
    }

    func testAwakeInThePastIsNotActive() {
        let awake = LinkAwake(until: Date().addingTimeInterval(-60), at: Date().addingTimeInterval(-3600))
        XCTAssertNil(awake.activeUntil())
    }

    func testAwakeStateFromNonMacIsRejected() throws {
        let signed = try LinkFlow.makeAwake(until: nil, signer: phoneDeny)
        XCTAssertThrowsError(try LinkFlow.checkAwake(payload: signed.payload, signature: signed.signature,
                                                     macKey: mac.publicKey.x963Representation)) {
            XCTAssertEqual($0 as? LinkError, .badSignature)
        }
    }
}
