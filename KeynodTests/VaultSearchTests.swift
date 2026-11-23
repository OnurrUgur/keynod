import XCTest

final class VaultSearchTests: XCTestCase {
    private func secret(_ text: String, _ fields: [SecretField]) -> Secret {
        Secret(title: text, fields: fields)
    }

    private let analytics = Secret(
        title: "Analytics Admin (stats.example.com)\nSelf-hosted web analytics dashboard. #analytics #ops",
        fields: [
            SecretField(label: "URL", value: "https://stats.example.com"),
            SecretField(label: "Username", value: "admin"),
            SecretField(label: "Password", concealed: true, hasValue: true),
        ]
    )

    func testMatchesTitleDescriptionTagsAndPlainValues() {
        for query in ["analytics", "ANALYTICS", "  Analytics  ", "self-hosted", "#ops", "ops", "stats.example", "admin", "analytics admin"] {
            XCTAssertTrue(analytics.matches(query), query)
        }
        XCTAssertFalse(analytics.matches("analytics grafana"))
    }

    func testIgnoresDiacriticsAndCase() {
        let item = secret("Café Déploy\nÜber panel #résumé", [SecretField(label: "User", value: "naïve")])
        for query in ["cafe", "CAFE", "deploy", "uber", "#resume", "naive", "café deploy"] {
            XCTAssertTrue(item.matches(query), query)
        }
    }

    func testNeverLooksAtConcealedFields() {
        var field = SecretField(label: "Password", concealed: true)
        field.value = "hunter2"
        let item = secret("Database", [field])
        XCTAssertFalse(item.matches("hunter2"))
        XCTAssertFalse(item.searchableText.contains("hunter2"))
    }

    func testFilterKeepsEverythingForAnEmptyQuery() {
        let list = [analytics, secret("App Store Connect", [])]
        XCTAssertEqual(Secret.filter(list, query: "").map(\.id), list.map(\.id))
        XCTAssertEqual(Secret.filter(list, query: "   ").map(\.id), list.map(\.id))
        XCTAssertEqual(Secret.filter(list, query: "analytics").map(\.id), [analytics.id])
    }
}
