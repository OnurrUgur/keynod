import XCTest

final class LinkCleanupTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
    private let id = UUID().uuidString

    func testExpiredRequestAndItsAnswerGo() {
        let items = [
            LinkCleanup.Item(name: "req-\(id)", expires: ago(120), created: ago(720)),
            LinkCleanup.Item(name: "resp-\(id)", created: ago(700)),
        ]
        XCTAssertEqual(Set(LinkCleanup.stale(items, now: now)), ["req-\(id)", "resp-\(id)"])
    }

    func testOpenRequestAndItsAnswerStay() {
        let items = [
            LinkCleanup.Item(name: "req-\(id)", expires: now.addingTimeInterval(300), created: ago(300)),
            LinkCleanup.Item(name: "resp-\(id)", created: ago(200)),
        ]
        XCTAssertEqual(LinkCleanup.stale(items, now: now), [])
    }

    func testRequestWithinGraceStays() {
        let items = [LinkCleanup.Item(name: "req-\(id)", expires: ago(30), created: ago(630))]
        XCTAssertEqual(LinkCleanup.stale(items, now: now), [])
    }

    func testOrphanAnswerGoesOnceItIsAMinuteOld() {
        XCTAssertEqual(LinkCleanup.stale([LinkCleanup.Item(name: "resp-\(id)", created: ago(90))], now: now), ["resp-\(id)"])
        XCTAssertEqual(LinkCleanup.stale([LinkCleanup.Item(name: "resp-\(id)", created: ago(10))], now: now), [])
    }

    func testOldPairingAndCommandRecordsGo() {
        let items = [
            LinkCleanup.Item(name: "pair-a", created: ago(Link.pairingTTL + 120)),
            LinkCleanup.Item(name: "pairack-a", created: ago(Link.pairingTTL + 120)),
            LinkCleanup.Item(name: "cmd-a", created: ago(Link.commandTTL + 120)),
            LinkCleanup.Item(name: "pair-b", created: ago(60)),
        ]
        XCTAssertEqual(Set(LinkCleanup.stale(items, now: now)), ["pair-a", "pairack-a", "cmd-a"])
    }

    func testModeAndAwakeRecordsAreNeverDeleted() {
        let items = [
            LinkCleanup.Item(name: Link.modeName, created: ago(1_000_000)),
            LinkCleanup.Item(name: Link.awakeName, created: ago(1_000_000)),
            LinkCleanup.Item(name: "req-nodates"),
        ]
        XCTAssertEqual(LinkCleanup.stale(items, now: now), [])
    }
}
