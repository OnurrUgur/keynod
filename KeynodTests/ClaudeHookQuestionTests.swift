import XCTest

final class ClaudeHookQuestionTests: XCTestCase {
    private func stdin(_ tool: String, _ input: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["tool_name": tool, "tool_input": input, "cwd": "/tmp/Demo"])
    }

    private func output(_ text: String?) -> [String: Any] {
        let root = (try? JSONSerialization.jsonObject(with: Data((text ?? "").utf8))) as? [String: Any]
        return root?["hookSpecificOutput"] as? [String: Any] ?? [:]
    }

    private let questions: [String: Any] = ["questions": [
        ["question": "Which auth method?", "header": "Auth", "multiSelect": false,
         "options": [["label": "Email", "description": "Fast"], ["label": "Apple", "description": "Low friction"]]],
        ["question": "When to ship?", "header": "Timing", "multiSelect": false,
         "options": [["label": "Today"], ["label": "Tomorrow"]]],
    ]]

    func testEachQuestionBecomesAPhoneQuestion() throws {
        let question = try XCTUnwrap(ClaudeHooks.toolQuestion(stdin: stdin("AskUserQuestion", questions)))
        XCTAssertEqual(question.asks.count, 2)
        XCTAssertEqual(question.asks[0].command, "Question: Auth")
        XCTAssertEqual(question.asks[0].summary, "Which auth method?")
        XCTAssertEqual(question.asks[0].options, ["Email", "Apple"])
        XCTAssertEqual(question.asks[0].body, "Which auth method?\n\n• **Email**: Fast\n• **Apple**: Low friction")
        XCTAssertEqual(question.asks[1].body, "When to ship?")
        XCTAssertEqual(question.asks[0].input, "text")
    }

    func testAnswersGoBackAsUpdatedInput() throws {
        let question = try XCTUnwrap(ClaudeHooks.toolQuestion(stdin: stdin("AskUserQuestion", questions)))
        let printed = ClaudeHooks.toolQuestionOutput(question, answers: [.init(choice: "Apple", text: nil),
                                                                           .init(choice: "Today", text: "tonight")])
        let out = output(printed)
        XCTAssertEqual(out["permissionDecision"] as? String, "allow")
        let updated = try XCTUnwrap(out["updatedInput"] as? [String: Any])
        XCTAssertEqual(updated["answers"] as? [String: String], ["Which auth method?": "Apple", "When to ship?": "tonight"])
    }

    func testApprovingThePlanEchoesItsInput() throws {
        let question = try XCTUnwrap(ClaudeHooks.toolQuestion(stdin: stdin("ExitPlanMode", ["plan": "# Plan\n1. Fix screen"])))
        XCTAssertEqual(question.asks.first?.command, "Plan approval")
        XCTAssertEqual(question.asks.first?.summary, "# Plan")
        let out = output(ClaudeHooks.toolQuestionOutput(question, answers: [.init(choice: ClaudeHooks.approvePlan)]))
        XCTAssertEqual(out["permissionDecision"] as? String, "allow")
        XCTAssertEqual((out["updatedInput"] as? [String: Any])?["plan"] as? String, "# Plan\n1. Fix screen")
    }

    func testFeedbackOrKeepPlanningRejectsThePlan() throws {
        let question = try XCTUnwrap(ClaudeHooks.toolQuestion(stdin: stdin("ExitPlanMode", ["plan": "Plan"])))
        let withWords = output(ClaudeHooks.toolQuestionOutput(question, answers: [.init(choice: ClaudeHooks.approvePlan,
                                                                                         text: "add unit tests too")]))
        XCTAssertEqual(withWords["permissionDecision"] as? String, "deny")
        XCTAssertTrue((withWords["permissionDecisionReason"] as? String ?? "").contains("add unit tests too"))
        let keep = output(ClaudeHooks.toolQuestionOutput(question, answers: [.init(choice: ClaudeHooks.keepPlanning)]))
        XCTAssertEqual(keep["permissionDecision"] as? String, "deny")
    }

    private let files: Set<String> = ["/Users/dev/shots/a.png", "/Users/dev/shots/b one.jpg", "/proj/rel/c.heic",
                                     "/Users/dev/d.webp", "/Users/dev/e.gif", "/Users/dev/f.jpeg"]

    private func paths(_ text: String, cwd: String? = "/proj") -> [String] {
        ClaudeHooks.imagePaths(in: text, cwd: cwd, home: "/Users/dev") { self.files.contains($0) }
    }

    func testFindsAbsoluteTildeMarkdownBacktickAndRelativePaths() {
        XCTAssertEqual(paths("see /Users/dev/shots/a.png."), ["/Users/dev/shots/a.png"])
        XCTAssertEqual(paths("see ~/shots/a.png, ok"), ["/Users/dev/shots/a.png"])
        XCTAssertEqual(paths("![shot](/Users/dev/shots/a.png)"), ["/Users/dev/shots/a.png"])
        XCTAssertEqual(paths("`~/shots/b one.jpg`"), ["/Users/dev/shots/b one.jpg"])
        XCTAssertEqual(paths("![x](rel/c.heic) and ./rel/c.heic"), ["/proj/rel/c.heic"])
    }
}
