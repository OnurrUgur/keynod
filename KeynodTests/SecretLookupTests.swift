import XCTest

final class SecretLookupTests: XCTestCase {
    private let secrets = [
        Secret(title: "App Store Connect \u{2013} Acme\nold key #asc", fields: []),
        Secret(title: "App Store Connect \u{2013} Beta", fields: []),
        Secret(title: "fal.ai", fields: []),
        Secret(title: "fal.ai", fields: []),
    ]

    private func message(_ query: String) -> String? {
        if case .failure(let failure) = SecretLookup.exact(query, in: secrets) { return failure.message }
        return nil
    }

    func testFindsByIdInAnyCase() throws {
        let id = secrets[3].id.uuidString
        XCTAssertEqual(try SecretLookup.exact(id.lowercased(), in: secrets).get().id, secrets[3].id)
        XCTAssertEqual(try SecretLookup.exact(" \(id) ", in: secrets).get().id, secrets[3].id)
    }

    func testFindsByFullTitleIgnoringCaseDashesAndSpacing() throws {
        XCTAssertEqual(try SecretLookup.exact("app store connect - beta", in: secrets).get().id, secrets[1].id)
        XCTAssertEqual(try SecretLookup.exact("App  Store Connect \u{2014} Acme", in: secrets).get().id, secrets[0].id)
    }

    func testPartOfATitleIsNotEnough() throws {
        let text = try XCTUnwrap(message("Connect \u{2013} Beta"))
        XCTAssertTrue(text.hasPrefix("no secret has the id or the full title"))
        XCTAssertTrue(text.contains(secrets[1].id.uuidString))
        XCTAssertFalse(text.contains(secrets[0].id.uuidString))
    }

    func testTheDescriptionIsNotPartOfTheTitle() {
        XCTAssertNotNil(message("App Store Connect \u{2013} Acme old key #asc"))
    }

    func testSameTitleTwiceNeedsTheId() throws {
        let text = try XCTUnwrap(message("fal.ai"))
        XCTAssertTrue(text.contains(secrets[2].id.uuidString))
        XCTAssertTrue(text.contains(secrets[3].id.uuidString))
    }

    func testEmptyAndUnknownNamesFail() {
        XCTAssertEqual(message("   "), "empty secret name")
        XCTAssertEqual(message("nothing like this"), "no secret has the id or the full title \"nothing like this\"")
        XCTAssertNotNil(message(UUID().uuidString))
    }
}
