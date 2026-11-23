import Foundation

/// Claude Code hooks that forward permission prompts, questions, plan approvals,
/// and finished turns to the paired iPhone while Remote Mode is on.
/// `keynod hook permission|stop|question` is invoked by Claude Code; this file
/// shapes what those hooks ask and print, and manages `~/.claude/settings.json`.
/// Foundation only, so unit tests compile it directly.
enum ClaudeHooks {
    struct Ask {
        var kind: String
        /// Headline on the phone, e.g. "Permission: Bash".
        var command: String
        /// One-line summary.
        var summary: String
        /// Full context to read before answering.
        var body: String?
        var options: [String]?
        var input: String?
        /// Claude's working directory, so the phone names the right project.
        var cwd: String?
        /// Absolute paths of picture files mentioned in the text (at most four).
        var images: [String] = []
    }

    // MARK: Pictures mentioned in text

    static let imageExtensions = ["png", "jpg", "jpeg", "gif", "heic", "webp"]
    static let maxImages = 4

    static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    static func imagePaths(in text: String, cwd: String?, home: String = NSHomeDirectory(),
                           isFile: (String) -> Bool = isRegularFile) -> [String] {
        let ext = imageExtensions.joined(separator: "|")
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var found: [(at: Int, raw: String)] = []
        let spans = [#"`([^`\n]+)`"#, #"\]\(([^)\n]+)\)"#]
        for pattern in spans {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: whole) where match.numberOfRanges > 1 {
                let raw = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: " <>\"'"))
                if imageExtensions.contains((raw as NSString).pathExtension.lowercased()) { found.append((match.range.location, raw)) }
            }
        }
        if let regex = try? NSRegularExpression(pattern: #"[\w~.\-/+@%]+\.(?:\#(ext))(?![\w])"#, options: .caseInsensitive) {
            for match in regex.matches(in: text, range: whole) { found.append((match.range.location, ns.substring(with: match.range))) }
        }
        var seen = Set<String>()
        var result: [String] = []
        for (_, raw) in found.sorted(by: { $0.at < $1.at }) {
            guard !raw.contains("://"), let path = resolved(raw, cwd: cwd, home: home),
                  seen.insert(path).inserted, isFile(path) else { continue }
            result.append(path)
            if result.count == maxImages { break }
        }
        return result
    }

    private static func resolved(_ raw: String, cwd: String?, home: String) -> String? {
        let path: String
        if raw.hasPrefix("~/") {
            path = home + raw.dropFirst(1)
        } else if raw.hasPrefix("/") {
            path = raw
        } else if let cwd, cwd.hasPrefix("/") {
            path = cwd + "/" + raw
        } else {
            return nil
        }
        return (path as NSString).standardizingPath
    }

    /// Set `KEYNOD_HOOKS_OFF=1` to bypass hooks for automated/headless Claude runs.
    static let offVariable = "KEYNOD_HOOKS_OFF"

    static func isOff(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[offVariable] == "1"
    }

    static let askTimeout: TimeInterval = 30 * 60
    static let hookTimeout = 1900

    static let continueLabel = "Continue"
    static let stopLabel = "Stop"

    static let permissionSummaryLimit = 300
    static let permissionBodyLimit = 1500

    /// Nil (so the hook stays silent and Claude Code shows its own full prompt)
    /// when the tool input doesn't fit the phone card whole: an Allow there
    /// covers the whole call, so the phone must show all of it.
    static func permissionAsk(stdin: Data) -> Ask? {
        guard let json = object(stdin), let tool = json["tool_name"] as? String, !tool.isEmpty else { return nil }
        let input = json["tool_input"] as? [String: Any] ?? [:]
        let summary = summary(tool: tool, input: input, limit: .max)
        let body = readable(input, limit: .max)
        guard summary.count <= permissionSummaryLimit, (body?.count ?? 0) <= permissionBodyLimit else { return nil }
        return Ask(kind: "permission", command: "Permission: \(tool)", summary: summary,
                   body: body, options: nil, input: nil, cwd: json["cwd"] as? String)
    }

    static func stopAsk(stdin: Data, isFile: (String) -> Bool = isRegularFile) -> Ask? {
        guard let json = object(stdin), let raw = json["last_assistant_message"] as? String else { return nil }
        let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, asksSomething(message) else { return nil }
        let firstLine = message.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let cwd = json["cwd"] as? String
        return Ask(kind: "reply", command: "Finished", summary: oneLine(firstLine, limit: 160), body: cut(message, 4000),
                   options: [continueLabel] + choices(in: message) + [stopLabel], input: "text", cwd: cwd,
                   images: imagePaths(in: message, cwd: cwd, isFile: isFile))
    }

    struct ToolQuestion {
        var tool: String
        var input: [String: Any]
        var asks: [Ask]
    }

    static let questionTools = ["AskUserQuestion", "ExitPlanMode"]
    static let approvePlan = "Approve"
    static let keepPlanning = "Keep planning"

    static func toolQuestion(stdin: Data, isFile: (String) -> Bool = isRegularFile) -> ToolQuestion? {
        guard let json = object(stdin), let tool = json["tool_name"] as? String, questionTools.contains(tool) else { return nil }
        let input = json["tool_input"] as? [String: Any] ?? [:]
        let cwd = json["cwd"] as? String
        if tool == "ExitPlanMode" {
            let plan = (input["plan"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = plan.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "Plan ready"
            let ask = Ask(kind: "reply", command: "Plan approval", summary: oneLine(firstLine, limit: 160),
                          body: plan.isEmpty ? nil : cut(plan, 4000), options: [approvePlan, keepPlanning],
                          input: "text", cwd: cwd, images: imagePaths(in: plan, cwd: cwd, isFile: isFile))
            return ToolQuestion(tool: tool, input: input, asks: [ask])
        }
        guard let questions = input["questions"] as? [[String: Any]], !questions.isEmpty else { return nil }
        var asks: [Ask] = []
        for question in questions {
            guard let text = question["question"] as? String, !text.isEmpty else { return nil }
            let options = question["options"] as? [[String: Any]] ?? []
            let labels = options.compactMap { $0["label"] as? String }.filter { !$0.isEmpty }
            let explained = options.compactMap { option -> String? in
                guard let label = option["label"] as? String else { return nil }
                let about = (option["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let preview = (option["preview"] as? String ?? "").trimmingCharacters(in: .newlines)
                    .replacingOccurrences(of: "```", with: "\u{00B4}\u{00B4}\u{00B4}")
                let hasPreview = !preview.trimmingCharacters(in: .whitespaces).isEmpty
                if about.isEmpty && !hasPreview { return nil }
                var entry = about.isEmpty ? "• **\(label)**" : "• **\(label)**: \(about)"
                if hasPreview { entry += "\n```\n\(cut(preview, 900))\n```" }
                return entry
            }
            var body = ([text] + (explained.isEmpty ? [] : [explained.joined(separator: "\n")])).joined(separator: "\n\n")
            if body.count > 3000 {
                body = cut(body, 3000)
                if body.components(separatedBy: "```").count % 2 == 0 { body += "\n```" }
            }
            let mentioned = ([text, question["header"] as? String ?? ""]
                + options.flatMap { [$0["label"] as? String ?? "", $0["description"] as? String ?? "", $0["preview"] as? String ?? ""] })
                .joined(separator: "\n")
            let header = (question["header"] as? String).map { oneLine($0, limit: 40) } ?? ""
            let multi = question["multiSelect"] as? Bool ?? false
            let headline = multi ? "Multi-select" : "Question"
            asks.append(Ask(kind: "reply", command: header.isEmpty ? (multi ? headline : "Claude asks") : headline + ": " + header,
                            summary: oneLine(text, limit: 300), body: body,
                            options: labels.prefix(7).map { oneLine($0, limit: 60) }, input: "text", cwd: cwd,
                            images: imagePaths(in: mentioned, cwd: cwd, isFile: isFile)))
        }
        return ToolQuestion(tool: tool, input: input, asks: asks)
    }

    struct ToolAnswer {
        var choice: String?
        var text: String?
    }

    static func toolQuestionOutput(_ question: ToolQuestion, answers: [ToolAnswer]) -> String? {
        guard answers.count == question.asks.count else { return nil }
        func words(_ answer: ToolAnswer) -> String {
            (answer.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if question.tool == "ExitPlanMode" {
            let answer = answers[0]
            let feedback = words(answer)
            if feedback.isEmpty && answer.choice == approvePlan {
                return allowOutput(question.input)
            }
            guard !feedback.isEmpty || answer.choice == keepPlanning else { return nil }
            let reason = feedback.isEmpty
                ? "The user did not approve the plan from iPhone: keep planning and present an updated plan."
                : "The user did not approve the plan from iPhone. Feedback: " + cut(feedback, 4000) + "\nRevise the plan accordingly and present it again."
            return json(["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "deny",
                                                "permissionDecisionReason": reason]])
        }
        guard let questions = question.input["questions"] as? [[String: Any]] else { return nil }
        var map: [String: String] = [:]
        for (item, answer) in zip(questions, answers) {
            guard let text = item["question"] as? String else { return nil }
            let typed = words(answer)
            let picked = typed.isEmpty ? (answer.choice ?? "") : typed
            guard !picked.isEmpty else { return nil }
            map[text] = picked
        }
        var input = question.input
        input["answers"] = map
        return allowOutput(input)
    }

    private static func allowOutput(_ input: [String: Any]) -> String? {
        json(["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": input]])
    }

    /// A finished turn reaches the phone only when it ends by asking something.
    static func asksSomething(_ message: String) -> Bool {
        let paragraphs = message.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return paragraphs.suffix(2).contains { $0.contains("?") }
    }

    static func choices(in message: String) -> [String] {
        guard message.contains("?") else { return [] }
        var blocks: [[String]] = []
        var current: [String] = []
        for line in message.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let item = listItem(trimmed) {
                current.append(item)
            } else if !trimmed.isEmpty, !line.hasPrefix(" ") {
                if !current.isEmpty { blocks.append(current); current = [] }
            }
        }
        if !current.isEmpty { blocks.append(current) }
        guard let last = blocks.last, last.count >= 2 else { return [] }
        var seen = Set<String>()
        return last.prefix(5).compactMap { item in
            var label = item.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            if let colon = label.firstIndex(of: ":"), label.distance(from: label.startIndex, to: colon) <= 50 {
                label = String(label[..<colon])
            }
            label = oneLine(label, limit: 60)
            guard !label.isEmpty, ![continueLabel, stopLabel].contains(label), seen.insert(label).inserted else { return nil }
            return label
        }
    }

    private static func listItem(_ line: String) -> String? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
            return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    static func permissionOutput(outcome: String?) -> String? {
        switch outcome {
        case "allowed":
            return #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
        case "denied":
            return #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from iPhone via Keynod."}}}"#
        default:
            return nil
        }
    }

    static func stopOutput(outcome: String?, choice: String?, text: String?) -> String? {
        guard outcome == "answered" else { return nil }
        let words = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let reason: String
        if !words.isEmpty {
            reason = "Reply from iPhone: " + cut(words, 4000)
        } else if choice == continueLabel {
            reason = "Reply from iPhone: continue."
        } else if let choice, !choice.isEmpty, choice != stopLabel {
            reason = "Selected on iPhone: " + choice
        } else {
            return nil
        }
        return json(["decision": "block", "reason": reason])
    }

    // MARK: Shaping text

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func cut(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "\u{2026}" : text
    }

    private static func oneLine(_ text: String, limit: Int) -> String {
        cut(text.split(whereSeparator: \.isWhitespace).joined(separator: " "), limit)
    }

    private static func cutMarked(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        let keep = limit - 24
        return String(text.prefix(keep)) + "\n\u{2026} (+\(text.count - keep) chars)"
    }

    private static func json(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value) || value is String || value is NSNumber,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func summary(tool: String, input: [String: Any], limit: Int = 300) -> String {
        let specific: [String]
        switch tool {
        case "Bash": specific = ["command"]
        case "Edit", "MultiEdit", "Write", "Read": specific = ["file_path"]
        case "NotebookEdit": specific = ["notebook_path"]
        default: specific = []
        }
        for key in specific + ["description"] {
            if let text = input[key] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return oneLine(text, limit: limit)
            }
        }
        guard !input.isEmpty, let text = json(input) else { return tool }
        return oneLine(text, limit: limit)
    }

    private static func readable(_ input: [String: Any], limit: Int) -> String? {
        let first = ["command", "file_path", "notebook_path", "path", "pattern", "url", "query", "description"]
        let keys = input.keys.sorted {
            let a = first.firstIndex(of: $0) ?? first.count, b = first.firstIndex(of: $1) ?? first.count
            return a != b ? a < b : $0 < $1
        }
        let text = keys.map { key -> String in
            let value = display(input[key])
            return value.contains("\n") ? "\(key):\n\(value)" : "\(key): \(value)"
        }.joined(separator: "\n")
        return text.isEmpty ? nil : cutMarked(text, limit)
    }

    private static func display(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return "null"
        case let text as String: return text
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
        case let other?: return json(other) ?? "\(other)"
        }
    }

    // MARK: Installing into Claude's settings

    enum State: Equatable {
        case notInstalled, partial, installed
        case unreadable(String)
    }

    struct Report {
        var lines: [String]
        var changed: Bool
        var backup: URL?
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static let events: [(event: String, sub: String)] = [("PermissionRequest", "permission"), ("Stop", "stop"),
                                                                  ("PreToolUse", "question")]

    private static let matchers = ["question": questionTools.joined(separator: "|")]

    static var settingsURL: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json") }

    static var keynodPath: String { NSHomeDirectory() + "/.local/bin/keynod" }

    static func state(settings: URL = settingsURL) -> State {
        do {
            let root = try load(settings).root
            let hooks = root["hooks"] as? [String: Any] ?? [:]
            let present = events.filter { hasOurs(hooks[$0.event], sub: $0.sub) }.count
            return present == 0 ? .notInstalled : present == events.count ? .installed : .partial
        } catch {
            return .unreadable("\(error)")
        }
    }

    @discardableResult
    static func install(settings: URL = settingsURL, keynod: String = keynodPath) throws -> Report {
        guard FileManager.default.isExecutableFile(atPath: keynod) else {
            throw Failure("\(keynod) doesn't exist; run `make link` first so Claude can call `keynod`")
        }
        let loaded = try load(settings)
        var root = loaded.root
        var hooks = try hooksSection(root)
        var lines: [String] = []
        var changed = false
        for (event, sub) in events {
            var entries = try eventEntries(hooks[event], event: event)
            if hasOurs(entries, sub: sub) {
                lines.append("\(event): already installed")
                continue
            }
            var entry: [String: Any] = ["hooks": [["type": "command", "command": "\(shellQuoted(keynod)) hook \(sub)", "timeout": hookTimeout]]]
            if let matcher = matchers[sub] { entry["matcher"] = matcher }
            entries.append(entry)
            hooks[event] = entries
            lines.append("\(event): added `keynod hook \(sub)`")
            changed = true
        }
        guard changed else { return Report(lines: lines, changed: false, backup: nil) }
        root["hooks"] = hooks
        let backup = try save(root, to: settings, existed: loaded.existed)
        return Report(lines: lines, changed: true, backup: backup)
    }

    @discardableResult
    static func uninstall(settings: URL = settingsURL) throws -> Report {
        let loaded = try load(settings)
        guard loaded.existed else { return Report(lines: ["no Claude settings file, nothing to remove"], changed: false, backup: nil) }
        var root = loaded.root
        var hooks = try hooksSection(root)
        var lines: [String] = []
        var changed = false
        for (event, sub) in events {
            var kept: [Any] = []
            var removed = 0
            for entry in try eventEntries(hooks[event], event: event) {
                guard var dict = entry as? [String: Any], let inner = dict["hooks"] as? [Any] else { kept.append(entry); continue }
                let rest = inner.filter { !isOurs(($0 as? [String: Any])?["command"] as? String, sub: sub) }
                removed += inner.count - rest.count
                if rest.count == inner.count {
                    kept.append(entry)
                } else if !rest.isEmpty {
                    dict["hooks"] = rest
                    kept.append(dict)
                }
            }
            guard removed > 0 else { lines.append("\(event): not installed"); continue }
            hooks[event] = kept.isEmpty ? nil : kept
            lines.append("\(event): removed `keynod hook \(sub)`")
            changed = true
        }
        guard changed else { return Report(lines: lines, changed: false, backup: nil) }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        let backup = try save(root, to: settings, existed: true)
        return Report(lines: lines, changed: true, backup: backup)
    }

    // MARK: Reading and writing settings

    private static func load(_ settings: URL) throws -> (root: [String: Any], existed: Bool) {
        let url = settings.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: url.path) else { return ([:], false) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw Failure("could not read \(url.path): \(error.localizedDescription)") }
        if data.allSatisfy({ [0x20, 0x0A, 0x0D, 0x09].contains($0) }) { return ([:], true) }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure("\(url.path) isn't a JSON object; fix it first (nothing was changed)")
        }
        return (root, true)
    }

    private static func hooksSection(_ root: [String: Any]) throws -> [String: Any] {
        guard let value = root["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else { throw Failure("\"hooks\" in the Claude settings isn't an object (nothing was changed)") }
        return hooks
    }

    private static func eventEntries(_ value: Any?, event: String) throws -> [Any] {
        guard let value else { return [] }
        guard let list = value as? [Any] else { throw Failure("\"hooks.\(event)\" in the Claude settings isn't a list (nothing was changed)") }
        return list
    }

    private static func save(_ root: [String: Any], to settings: URL, existed: Bool) throws -> URL? {
        let url = settings.resolvingSymlinksInPath()
        let fm = FileManager.default
        var backup: URL?
        var mode: Any?
        do {
            if existed {
                let stamp = DateFormatter()
                stamp.locale = Locale(identifier: "en_US_POSIX")
                stamp.dateFormat = "yyyyMMdd-HHmmss"
                let base = url.lastPathComponent + ".keynod-backup-" + stamp.string(from: Date())
                var target = url.deletingLastPathComponent().appendingPathComponent(base)
                var n = 1
                while fm.fileExists(atPath: target.path) {
                    n += 1
                    target = url.deletingLastPathComponent().appendingPathComponent("\(base)-\(n)")
                }
                try fm.copyItem(at: url, to: target)
                backup = target
                mode = try fm.attributesOfItem(atPath: url.path)[.posixPermissions]
            } else {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try Data((pretty(root) + "\n").utf8).write(to: url, options: .atomic)
            if let mode { try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
        } catch {
            throw Failure("could not write \(url.path): \(error.localizedDescription)")
        }
        return backup
    }

    private static func pretty(_ value: Any, level: Int = 0) -> String {
        let pad = String(repeating: "  ", count: level), inner = pad + "  "
        switch value {
        case let dict as [String: Any]:
            if dict.isEmpty { return "{}" }
            let rows = dict.keys.sorted().map { "\(inner)\(scalar($0)): \(pretty(dict[$0]!, level: level + 1))" }
            return "{\n" + rows.joined(separator: ",\n") + "\n\(pad)}"
        case let list as [Any]:
            if list.isEmpty { return "[]" }
            return "[\n" + list.map { inner + pretty($0, level: level + 1) }.joined(separator: ",\n") + "\n\(pad)]"
        default:
            return scalar(value)
        }
    }

    private static func scalar(_ value: Any) -> String {
        json(value) ?? "null"
    }

    private static func hasOurs(_ value: Any?, sub: String) -> Bool {
        guard let entries = value as? [Any] else { return false }
        return entries.contains { entry in
            ((entry as? [String: Any])?["hooks"] as? [Any])?.contains {
                isOurs(($0 as? [String: Any])?["command"] as? String, sub: sub)
            } ?? false
        }
    }

    private static func isOurs(_ command: String?, sub: String) -> Bool {
        guard let command, command.hasSuffix(" hook \(sub)") else { return false }
        let path = command.dropLast(" hook \(sub)".count).trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
        return URL(fileURLWithPath: path).lastPathComponent == "keynod"
    }

    private static func shellQuoted(_ path: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+@%:,=")
        if path.unicodeScalars.allSatisfy({ safe.contains($0) }) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
