import XCTest

final class ClaudeHookChoiceTests: XCTestCase {
    func testLastListOfAQuestionBecomesChoices() {
        let message = """
        Status:
        - Audio works
        - Apps open

        Next steps:
        1. **iPhone screen:** same remote on the phone.
        2. **Keyboard search:** quick search across items.

        Which one should we do next?
        """
        XCTAssertEqual(ClaudeHooks.choices(in: message), ["iPhone screen", "Keyboard search"])
    }

    func testNoQuestionNoChoices() {
        XCTAssertEqual(ClaudeHooks.choices(in: "Done.\n- one\n- two"), [])
    }

    func testASingleItemIsNotAChoice() {
        XCTAssertEqual(ClaudeHooks.choices(in: "Should I do this?\n- only item"), [])
    }

    func testAtMostFiveAndShort() {
        let items = (1...9).map { "- option \($0) " + String(repeating: "long ", count: 20) }.joined(separator: "\n")
        let choices = ClaudeHooks.choices(in: "Which one?\n" + items)
        XCTAssertEqual(choices.count, 5)
        XCTAssertTrue(choices.allSatisfy { $0.count <= 60 })
    }

    func testStopAskOffersContinueChoicesAndStop() throws {
        let input = try JSONSerialization.data(withJSONObject: [
            "last_assistant_message": "Which one?\n1. Option A\n2. Option B", "cwd": "/tmp"])
        XCTAssertEqual(ClaudeHooks.stopAsk(stdin: input)?.options, ["Continue", "Option A", "Option B", "Stop"])
    }

    func testPickedChoiceKeepsClaudeGoingAndStopStops() {
        XCTAssertTrue(ClaudeHooks.stopOutput(outcome: "answered", choice: "Option A", text: nil)?
            .contains("Selected on iPhone: Option A") == true)
        XCTAssertNil(ClaudeHooks.stopOutput(outcome: "answered", choice: "Stop", text: nil))
    }
}
