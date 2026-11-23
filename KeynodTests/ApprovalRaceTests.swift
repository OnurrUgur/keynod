import Foundation
import XCTest

private enum Reason: Error, Equatable {
    case locked, noPhone, expired, cancelled, rejected
    case other(Int)
}

private typealias Race = ApprovalRace<String>

private func spawn(_ body: @escaping @Sendable () -> Void) {
    let thread = Thread(block: body)
    thread.qualityOfService = .userInteractive
    thread.start()
}

private func XCTAssertApproved<Grant: Equatable>(_ outcome: ApprovalRace<Grant>.Outcome?, _ grant: Grant,
                                                 by side: ApprovalRace<Grant>.Side,
                                                 file: StaticString = #filePath, line: UInt = #line) {
    guard case .approved(let got, let by)? = outcome else {
        return XCTFail("expected approved(\(grant)) by \(side)", file: file, line: line)
    }
    XCTAssertEqual(got, grant, file: file, line: line)
    XCTAssertEqual(by, side, file: file, line: line)
}

private func XCTAssertFailed<Grant, Failure: Error & Equatable>(_ outcome: ApprovalRace<Grant>.Outcome?, _ reason: Failure,
                                                                by side: ApprovalRace<Grant>.Side,
                                                                file: StaticString = #filePath, line: UInt = #line) {
    guard case .failed(let error, let by)? = outcome else {
        return XCTFail("expected failed(\(reason)) by \(side)", file: file, line: line)
    }
    XCTAssertEqual(error as? Failure, reason, file: file, line: line)
    XCTAssertEqual(by, side, file: file, line: line)
}

final class ApprovalRaceTests: XCTestCase {
    func testMacApprovesFirstAndLaterAnswersAreIgnored() {
        let race = Race()
        XCTAssertFalse(race.isDecided)
        race.approve("mac grant", by: .mac)
        XCTAssertTrue(race.isDecided)
        race.approve("phone grant", by: .phone)
        race.deny(Reason.rejected, by: .phone)
        XCTAssertApproved(race.wait(timeout: 1), "mac grant", by: .mac)
    }

    func testPhoneApprovesFirstAndLaterAnswersAreIgnored() {
        let race = Race()
        race.approve("phone grant", by: .phone)
        race.approve("mac grant", by: .mac)
        XCTAssertApproved(race.wait(timeout: 1), "phone grant", by: .phone)
    }

    func testPhoneDenialFirstFailsTheRequest() {
        let race = Race()
        race.deny(Reason.rejected, by: .phone)
        race.approve("mac grant", by: .mac)
        XCTAssertFailed(race.wait(timeout: 1), Reason.rejected, by: .phone)
    }

    func testMacStepsAsideThenPhoneApproves() {
        let race = Race()
        race.stepAside(.mac, because: Reason.locked)
        XCTAssertFalse(race.isDecided)
        race.approve("phone grant", by: .phone)
        XCTAssertApproved(race.wait(timeout: 1), "phone grant", by: .phone)
    }

    func testBothSidesSteppingAsideFailsWithLastReason() {
        let race = Race()
        race.stepAside(.mac, because: Reason.locked)
        race.stepAside(.phone, because: Reason.noPhone)
        XCTAssertFailed(race.wait(timeout: 1), Reason.noPhone, by: .phone)
    }

    func testWaitWakesUpWhenAnotherThreadDecides() {
        let race = Race()
        spawn {
            Thread.sleep(forTimeInterval: 0.05)
            race.approve("late grant", by: .phone)
        }
        XCTAssertApproved(race.wait(timeout: 5), "late grant", by: .phone)
    }
}
