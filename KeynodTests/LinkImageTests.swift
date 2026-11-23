import CryptoKit
import XCTest

final class LinkImageTests: XCTestCase {
    private let mac = P256.Signing.PrivateKey()
    private var pairedMac: PairedMac { PairedMac(name: "Mac", macKey: mac.publicKey.x963Representation, pairedAt: Date()) }
    private let one = Data("jpeg-one".utf8)
    private let two = Data("jpeg-two".utf8)

    private func ask(images: [Data], now: Date = Date()) throws -> LinkWaiting {
        try LinkFlow.makeRequest(macName: "Mac", kind: "reply", who: "claude", command: "Finished", cwd: "~/Developer/Demo",
                                 summary: "done", items: [], now: now, body: "Look", options: nil, input: "text",
                                 images: images, signer: mac)
    }

    func testMatchingImagesPass() throws {
        let waiting = try ask(images: [one, two])
        XCTAssertEqual(waiting.request.imageHashes, [LinkCrypto.sha256Hex(one), LinkCrypto.sha256Hex(two)])
        let request = try LinkFlow.checkRequest(payload: waiting.payload, signature: waiting.signature, mac: pairedMac,
                                                images: [one, two])
        XCTAssertEqual(request.id, waiting.request.id)
    }

    func testChangedReorderedOrMissingImagesAreRejected() throws {
        let waiting = try ask(images: [one, two])
        func check(_ images: [Data]?) throws {
            _ = try LinkFlow.checkRequest(payload: waiting.payload, signature: waiting.signature, mac: pairedMac, images: images)
        }
        XCTAssertThrowsError(try check([one, Data("evil".utf8)]))
        XCTAssertThrowsError(try check([two, one]))
        XCTAssertThrowsError(try check([one]))
        XCTAssertThrowsError(try check([]))
        XCTAssertThrowsError(try check(nil)) { XCTAssertEqual($0 as? LinkError, .missingImages) }
    }

    func testAtMostMaxImagesAreSigned() throws {
        let waiting = try ask(images: (0..<(Link.maxImages + 3)).map { Data([UInt8($0)]) })
        XCTAssertEqual(waiting.request.imageHashes?.count, Link.maxImages)
    }
}
