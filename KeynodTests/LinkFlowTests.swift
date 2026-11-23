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

private struct FaceIDCancelled: Error {}

private struct CancelledAgreer: LinkAgreer {
    let key: P256.KeyAgreement.PrivateKey
    var agreementPublicKey: P256.KeyAgreement.PublicKey { key.publicKey }
    func agree(with other: P256.KeyAgreement.PublicKey) throws -> SharedSecret { throw FaceIDCancelled() }
}

private struct CancelledSigner: LinkSigner {
    let key: P256.Signing.PrivateKey
    var signingPublicKey: P256.Signing.PublicKey { key.publicKey }
    func sign(_ data: Data) throws -> Data { throw FaceIDCancelled() }
}

private final class CountingAgreer: LinkAgreer {
    private let key: P256.KeyAgreement.PrivateKey
    private(set) var calls = 0
    init(_ key: P256.KeyAgreement.PrivateKey) { self.key = key }
    var agreementPublicKey: P256.KeyAgreement.PublicKey { key.publicKey }
    func agree(with other: P256.KeyAgreement.PublicKey) throws -> SharedSecret {
        calls += 1
        return try key.sharedSecretFromKeyAgreement(with: other)
    }
}

final class LinkFlowTests: XCTestCase {
    private typealias Answer = (payload: Data, signature: Data)

    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private let macKey = P256.Signing.PrivateKey()
    private let phoneField = P256.KeyAgreement.PrivateKey()
    private let phoneApprove = P256.Signing.PrivateKey()
    private let phoneDeny = P256.Signing.PrivateKey()

    private var phone: PairedPhone {
        PairedPhone(reply: PairReply(pairing: UUID(), phoneName: "Test iPhone",
                                     approveKey: phoneApprove.publicKey.x963Representation,
                                     fieldKey: phoneField.publicKey.x963Representation,
                                     denyKey: phoneDeny.publicKey.x963Representation),
                    pairedAt: now)
    }

    private var mac: PairedMac {
        PairedMac(name: "Test Mac", macKey: macKey.publicKey.x963Representation, pairedAt: now)
    }

    private struct Field {
        let id: UUID
        let value: Data
        let copy: LinkCrypto.Protected
        let item: LinkRequest.Item
    }

    private func field(_ title: String, _ label: String, _ value: Data) throws -> Field {
        let id = UUID()
        let copy = try LinkCrypto.protect(value, field: id, for: phoneField.publicKey)
        return Field(id: id, value: value, copy: copy,
                     item: LinkRequest.Item(field: id, secret: title, label: label, eph: copy.eph))
    }

    private func sampleField() throws -> Field { try field("App Store Connect", "Private Key", Data("secret".utf8)) }

    private func ask(_ fields: [Field], id: UUID = UUID(), kind: String = "run", at time: Date? = nil) throws -> LinkWaiting {
        try LinkFlow.makeRequest(id: id, macName: "Test Mac", kind: kind, who: "claude ← zsh",
                                 command: "keynod run -- fastlane beta", cwd: "~/Developer/DemoApp",
                                 summary: "App Store Connect: Private Key, Issuer ID",
                                 items: fields.map(\.item), now: time ?? now, signer: macKey)
    }

    private func seen(_ waiting: LinkWaiting, at time: Date? = nil) throws -> LinkRequest {
        try LinkFlow.checkRequest(payload: waiting.payload, signature: waiting.signature, mac: mac, now: time ?? now)
    }

    private func approval(of waiting: LinkWaiting) throws -> Answer {
        try LinkFlow.approve(try seen(waiting), payload: waiting.payload, fieldKey: phoneField, approveKey: phoneApprove, now: now)
    }

    private func denial(of waiting: LinkWaiting, signedBy signer: LinkSigner? = nil) throws -> Answer {
        try LinkFlow.deny(try seen(waiting), payload: waiting.payload, denyKey: signer ?? phoneDeny, now: now)
    }

    private func verdict(_ answer: Answer, for waiting: LinkWaiting, at time: Date? = nil,
                         phone paired: PairedPhone? = nil) throws -> LinkVerdict {
        try LinkFlow.checkResponse(payload: answer.payload, signature: answer.signature, for: waiting,
                                   phone: paired ?? phone, now: time ?? now)
    }

    private func released(_ verdict: LinkVerdict, file: StaticString = #filePath, line: UInt = #line) -> [UUID: SymmetricKey] {
        guard case .approved(let keys) = verdict else {
            XCTFail("expected an approval", file: file, line: line)
            return [:]
        }
        return keys
    }

    private func isDenied(_ verdict: LinkVerdict) -> Bool {
        if case .denied = verdict { return true }
        return false
    }

    private func resignedAnswer(_ answer: Answer, signedBy signer: LinkSigner? = nil,
                                _ change: (inout LinkResponse) -> Void) throws -> Answer {
        var response = try LinkCoding.decode(LinkResponse.self, from: answer.payload)
        change(&response)
        let payload = try LinkCoding.encode(response)
        return (payload, try (signer ?? phoneApprove).sign(payload))
    }

    func testApprovalRecoversBothValuesOnTheMac() throws {
        let text = try field("App Store Connect", "Issuer ID", Data("69a6de70-03db-47e3-e053-5b8c7c11a4d1".utf8))
        let binary = try field("App Store Connect", "Private Key", noise(4096))
        let unrelated = try field("Other", "Token", Data("not requested".utf8))

        let waiting = try ask([text, binary])
        let request = try seen(waiting)
        XCTAssertEqual(request, waiting.request)

        let keys = released(try verdict(try approval(of: waiting), for: waiting))
        XCTAssertEqual(Set(keys.keys), [text.id, binary.id])
        XCTAssertEqual(try LinkCrypto.open(text.copy, field: text.id, key: try XCTUnwrap(keys[text.id])), text.value)
        XCTAssertEqual(try LinkCrypto.open(binary.copy, field: binary.id, key: try XCTUnwrap(keys[binary.id])), binary.value)
        XCTAssertNil(keys[unrelated.id])
    }

    func testMessagesCarryNeitherValuesNorFieldKeys() throws {
        // Assembled so the file holds no literal that looks like a live key to secret scanners.
        let secret = try field("Stripe", "Secret Key", Data(["sk", "live", "51H8-super-secret-token-value"].joined(separator: "_").utf8))
        let waiting = try ask([secret])
        let answer = try approval(of: waiting)
        let key = bytes(try XCTUnwrap(released(try verdict(answer, for: waiting))[secret.id]))
        for payload in [waiting.payload, answer.payload] {
            for needle in [secret.value, key] {
                XCTAssertNil(payload.range(of: needle))
                XCTAssertNil(payload.range(of: Data(needle.base64EncodedString().utf8)))
            }
        }
    }

    func testApprovalSignedWithDenyKeyIsRejected() throws {
        let waiting = try ask([try sampleField()])
        let answer = try approval(of: waiting)
        let byDenyKey: Answer = (answer.payload, try phoneDeny.sign(answer.payload))
        XCTAssertThrowsLinkError(try verdict(byDenyKey, for: waiting), .badSignature)
    }

    func testReplayedAnswerCannotApproveANewRequest() throws {
        let a = try sampleField()
        let first = try ask([a])
        let answer = try approval(of: first)
        XCTAssertNoThrow(try verdict(answer, for: first))
        let second = try ask([a])
        XCTAssertThrowsLinkError(try verdict(answer, for: second), .wrongRequest)

        let forged = try resignedAnswer(answer) {
            $0.request = second.request.id
            $0.requestHash = LinkCrypto.sha256(second.payload)
        }
        XCTAssertThrowsLinkError(try verdict(forged, for: second), .badKey)
    }

    func testDenialWorksWithDenyKey() throws {
        let waiting = try ask([try sampleField()])
        let answer = try denial(of: waiting)
        XCTAssertTrue(isDenied(try verdict(answer, for: waiting)))
    }

    func testApproveStopsWhenFaceIDCancelled() throws {
        let waiting = try ask([try sampleField()])
        let req = try seen(waiting)
        XCTAssertThrowsError(try LinkFlow.approve(req, payload: waiting.payload, fieldKey: CancelledAgreer(key: phoneField),
                                                  approveKey: phoneApprove, now: now)) { XCTAssertTrue($0 is FaceIDCancelled) }
        XCTAssertThrowsError(try LinkFlow.approve(req, payload: waiting.payload, fieldKey: phoneField,
                                                  approveKey: CancelledSigner(key: phoneApprove), now: now)) { XCTAssertTrue($0 is FaceIDCancelled) }
    }

    func testDuplicateFieldIsDeduplicated() throws {
        let a = try sampleField()
        let waiting = try ask([a, a])
        XCTAssertEqual(waiting.request.items.count, 1)
        let counter = CountingAgreer(phoneField)
        let answer = try LinkFlow.approve(try seen(waiting), payload: waiting.payload, fieldKey: counter, approveKey: phoneApprove, now: now)
        XCTAssertEqual(counter.calls, 1)
        XCTAssertEqual(try LinkCrypto.open(a.copy, field: a.id, key: try XCTUnwrap(released(try verdict(answer, for: waiting))[a.id])), a.value)
    }

    func testPairingEndToEnd() throws {
        let offer = PairOffer(macName: "Test Mac", macKey: macKey.publicKey.x963Representation,
                              secret: LinkCrypto.randomBytes(32), expires: now.addingTimeInterval(Link.pairingTTL))
        let scanned = try PairOffer(qrText: offer.qrText)
        let sent = try LinkFlow.makePairReply(scanned, phoneName: "Test iPhone",
                                              approveKey: phoneApprove.publicKey.x963Representation,
                                              fieldKey: phoneField.publicKey.x963Representation,
                                              denyKey: phoneDeny.publicKey.x963Representation)
        let received = try LinkFlow.checkPairReply(payload: sent.payload, mac: sent.mac, offer: offer, now: now)
        XCTAssertEqual(received.code, sent.code)
        let ackPayload = try LinkCoding.encode(PairAck(pairing: offer.id, accepted: true,
                                                       reply: LinkFlow.pairReplyDigest(sent.payload)))
        let ack = try LinkFlow.checkPairAck(payload: ackPayload, signature: try macKey.sign(ackPayload), offer: scanned,
                                            sentReply: sent.payload)
        XCTAssertTrue(ack.accepted)
    }

    func testPairingAckMustNameThePhonesOwnReply() throws {
        let offer = PairOffer(macName: "Test Mac", macKey: macKey.publicKey.x963Representation,
                              secret: LinkCrypto.randomBytes(32), expires: now.addingTimeInterval(Link.pairingTTL))
        let sent = try LinkFlow.makePairReply(offer, phoneName: "Test iPhone",
                                              approveKey: phoneApprove.publicKey.x963Representation,
                                              fieldKey: phoneField.publicKey.x963Representation,
                                              denyKey: phoneDeny.publicKey.x963Representation)
        // The Mac accepted some other reply (one swapped in with the same six digits).
        let other = Data("another reply".utf8)
        for reply in [LinkFlow.pairReplyDigest(other), nil] {
            let payload = try LinkCoding.encode(PairAck(pairing: offer.id, accepted: true, reply: reply))
            XCTAssertThrowsError(try LinkFlow.checkPairAck(payload: payload, signature: try macKey.sign(payload),
                                                           offer: offer, sentReply: sent.payload))
        }
        // A refusal needs no digest.
        let refusal = try LinkCoding.encode(PairAck(pairing: offer.id, accepted: false))
        XCTAssertFalse(try LinkFlow.checkPairAck(payload: refusal, signature: try macKey.sign(refusal),
                                                 offer: offer, sentReply: sent.payload).accepted)
    }
}
