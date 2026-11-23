import CryptoKit
import XCTest

final class LinkQuestionTests: XCTestCase {
    private let mac = P256.Signing.PrivateKey()
    private let approve = P256.Signing.PrivateKey()
    private let deny = P256.Signing.PrivateKey()
    private let field = P256.KeyAgreement.PrivateKey()
    private var phone: PairedPhone {
        PairedPhone(reply: PairReply(pairing: UUID(), phoneName: "iPhone", approveKey: approve.publicKey.x963Representation,
                                     fieldKey: field.publicKey.x963Representation, denyKey: deny.publicKey.x963Representation))
    }
    private var pairedMac: PairedMac { PairedMac(name: "Mac", macKey: mac.publicKey.x963Representation, pairedAt: Date()) }

    private func ask(_ kind: String, options: [String]? = nil, ttl: TimeInterval? = nil, now: Date = Date()) throws -> LinkWaiting {
        try LinkFlow.makeRequest(macName: "Mac", kind: kind, who: "claude", command: "Finished", cwd: "~/Developer/Demo",
                                 summary: "Claude finished", items: [], now: now, ttl: ttl, body: "Shall I deploy?",
                                 options: options, input: "text", signer: mac)
    }

    func testReplyTextIsSealedAndOpensOnTheMac() throws {
        let waiting = try ask("reply")
        let request = try LinkFlow.checkRequest(payload: waiting.payload, signature: waiting.signature, mac: pairedMac)
        XCTAssertEqual(request.body, "Shall I deploy?")
        let answer = try LinkFlow.answer(request, payload: waiting.payload, choice: nil, text: "yes, go ahead", signer: deny)
        XCTAssertFalse(String(decoding: answer.payload, as: UTF8.self).contains("ahead"), "text must travel encrypted")
        guard case .answered(let choice, let text) = try LinkFlow.checkResponse(payload: answer.payload, signature: answer.signature,
                                                                                for: waiting, phone: phone) else {
            return XCTFail("expected an answer")
        }
        XCTAssertNil(choice)
        XCTAssertEqual(text, "yes, go ahead")
    }

    func testDecideAcceptsOnlyOfferedOptions() throws {
        let waiting = try ask("decide", options: ["Yes", "No"])
        let request = try LinkFlow.checkRequest(payload: waiting.payload, signature: waiting.signature, mac: pairedMac)
        let good = try LinkFlow.answer(request, payload: waiting.payload, choice: "No", text: nil, signer: deny)
        guard case .answered(let choice, _) = try LinkFlow.checkResponse(payload: good.payload, signature: good.signature,
                                                                         for: waiting, phone: phone) else { return XCTFail() }
        XCTAssertEqual(choice, "No")
        let bad = try LinkFlow.answer(request, payload: waiting.payload, choice: "Maybe", text: nil, signer: deny)
        XCTAssertThrowsError(try LinkFlow.checkResponse(payload: bad.payload, signature: bad.signature, for: waiting, phone: phone))
    }

    func testPermissionAllowNeedsTheFaceIDKey() throws {
        let waiting = try ask("permission")
        let request = try LinkFlow.checkRequest(payload: waiting.payload, signature: waiting.signature, mac: pairedMac)
        let viaDenyKey = try LinkFlow.approve(request, payload: waiting.payload, fieldKey: field, approveKey: deny)
        XCTAssertThrowsError(try LinkFlow.checkResponse(payload: viaDenyKey.payload, signature: viaDenyKey.signature,
                                                        for: waiting, phone: phone))
        let real = try LinkFlow.approve(request, payload: waiting.payload, fieldKey: field, approveKey: approve)
        guard case .approved(let keys) = try LinkFlow.checkResponse(payload: real.payload, signature: real.signature,
                                                                    for: waiting, phone: phone) else { return XCTFail() }
        XCTAssertTrue(keys.isEmpty)
    }

    func testCommandsAreSignedAndExpire() throws {
        let now = Date()
        let cmd = try LinkFlow.makeCommand(action: "lock", now: now, signer: deny)
        XCTAssertEqual(try LinkFlow.checkCommand(payload: cmd.payload, signature: cmd.signature, phone: phone, now: now).action, "lock")
        XCTAssertThrowsError(try LinkFlow.checkCommand(payload: cmd.payload, signature: cmd.signature, phone: phone,
                                                       now: now.addingTimeInterval(Link.commandTTL + 1)))
        let forged = try LinkFlow.makeCommand(action: "sleep", now: now, signer: P256.Signing.PrivateKey())
        XCTAssertThrowsError(try LinkFlow.checkCommand(payload: forged.payload, signature: forged.signature, phone: phone, now: now))
    }
}
