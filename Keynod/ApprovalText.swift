import CryptoKit
import Foundation

/// Pure helpers behind CLI approvals: what the Touch ID dialog and the iPhone
/// say, how long an approval is remembered for, and which processes count as
/// Claude Code. Filesystem lookups are passed in, so all of it is unit-tested.
enum ApprovalText {
    static let tool = "keynod"

    /// The Touch ID reason is cut by the system at about 260 characters. The
    /// iPhone hint is left room for, so the dialog never cuts the reason itself.
    static let phoneHint = " \u{2014} or approve on your iPhone"
    static let reasonLimit = 260 - phoneHint.count
    /// Maximum rendered command length on the iPhone approval card.
    static let phoneCommandLimit = 160

    static let ellipsis = "\u{2026}"

    // MARK: Text shaping

    /// Invisible characters outside Unicode's control and format categories.
    private static let invisible: Set<UInt32> = [0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x3164, 0xFFA0]

    /// Removes control characters, format characters (zero-width, bidi
    /// overrides and isolates, BOM), variation selectors and other invisible
    /// ones. Line breaks and tabs stay when `keepLineBreaks` (a lone CR becomes
    /// a line break, CR LF one), otherwise they become spaces. Run this before
    /// redacting, so an invisible character can't split a secret.
    static func sanitize(_ text: String, keepLineBreaks: Bool = false) -> String {
        var out = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        for (i, s) in scalars.enumerated() {
            switch s.value {
            case 0x0A, 0x09:
                out.append(keepLineBreaks ? s : " ")
            case 0x0B, 0x0C, 0x85, 0x2028, 0x2029:
                out.append(keepLineBreaks ? "\n" : " ")
            case 0x0D:
                if !keepLineBreaks {
                    out.append(" ")
                } else if i + 1 >= scalars.count || scalars[i + 1].value != 0x0A {
                    out.append("\n")
                }
            case 0xFE00...0xFE0F, 0xE0100...0xE01EF:
                continue
            default:
                if CharacterSet.controlCharacters.contains(s) || invisible.contains(s.value) { continue }
                out.append(s)
            }
        }
        return String(out)
    }

    /// One line: sanitized, runs of whitespace collapsed.
    static func flatten(_ text: String) -> String {
        sanitize(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// At most `limit` characters, keeping the start and the end with a visible
    /// " … " between them, so neither a harmless-looking start nor a long middle
    /// can hide what the end of a command does.
    static func elideMiddle(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        let gap = " \(ellipsis) "
        guard limit > gap.count + 2 else { return String(text.prefix(max(limit - 1, 0))) + ellipsis }
        let keep = limit - gap.count
        let head = (keep + 1) / 2
        return String(text.prefix(head)) + gap + String(text.suffix(keep - head))
    }

    /// At most `limit` characters, keeping the end (for paths).
    static func elideStart(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return ellipsis + String(text.suffix(max(limit - 1, 0)))
    }

    /// At most `limit` characters, keeping the start.
    static func elideEnd(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(limit - 1, 0))) + ellipsis
    }

    /// `path` with the home folder shortened to "~".
    static func tilde(_ path: String, home: String) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    // MARK: Paths and programs (shared by the command and the app)

    /// The absolute file a destination argument (`inject --to`) names: "~" and "~/" are the home folder, a relative path is
    /// relative to `cwd`, and symlinks in the existing part of the parent folder
    /// are resolved (the file itself is opened with O_NOFOLLOW). Nil for "~user"
    /// forms and empty names. Both sides call this, so they agree on the path.
    static func destination(_ raw: String, cwd: String, home: String, realpath: (String) -> String?) -> String? {
        guard !raw.isEmpty else { return nil }
        var path = raw
        if path == "~" || path.hasPrefix("~/") {
            path = home + path.dropFirst()
        } else if path.hasPrefix("~") {
            return nil
        }
        if !path.hasPrefix("/") { path = cwd + "/" + path }
        let standard = URL(fileURLWithPath: path).standardized.path
        let name = (standard as NSString).lastPathComponent
        guard !name.isEmpty, name != "/", name != ".", name != ".." else { return nil }
        let parent = resolveExisting((standard as NSString).deletingLastPathComponent, realpath: realpath)
        return parent == "/" ? "/" + name : parent + "/" + name
    }

    /// `dir` with its longest existing prefix put through `realpath`.
    private static func resolveExisting(_ dir: String, realpath: (String) -> String?) -> String {
        var head = dir
        var rest: [String] = []
        while true {
            if let real = realpath(head) {
                return rest.reversed().reduce(real) { ($0 == "/" ? "" : $0) + "/" + $1 }
            }
            if head == "/" || head.isEmpty { return dir }
            rest.append((head as NSString).lastPathComponent)
            head = (head as NSString).deletingLastPathComponent
        }
    }

    /// The program `posix_spawnp` would run for `name`: a name with a slash is
    /// taken as a path (relative to `cwd`); otherwise the first executable in
    /// `path` (default "/usr/bin:/bin"; an empty entry is `cwd`). Nil when it
    /// isn't an executable file. Symlinks are not resolved here (see `runMatches`).
    static func executable(_ name: String, path: String?, cwd: String, isExecutable: (String) -> Bool) -> String? {
        guard !name.isEmpty else { return nil }
        if name.contains("/") {
            let full = URL(fileURLWithPath: name.hasPrefix("/") ? name : cwd + "/" + name).standardized.path
            return isExecutable(full) ? full : nil
        }
        for dir in (path ?? "/usr/bin:/bin").split(separator: ":", omittingEmptySubsequences: false).map(String.init) {
            let base = dir.isEmpty ? cwd : (dir.hasPrefix("/") ? dir : cwd + "/" + dir)
            let candidate = URL(fileURLWithPath: base + "/" + name).standardized.path
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    /// The `--` index of a `run` invocation, as the command parses it: after
    /// `run`, only `--env X=y` / `--file X=y` pairs come before it.
    static func runSeparator(_ argv: [String]) -> Int? {
        guard argv.count >= 2, argv[1] == "run" else { return nil }
        var i = 2
        while i < argv.count {
            if argv[i] == "--" { return i }
            guard argv[i] == "--env" || argv[i] == "--file", i + 1 < argv.count else { return nil }
            i += 2
        }
        return nil
    }

    /// The program a `run` request reports matches what its arguments name.
    /// `found` is the path the lookup found (nil when it was already the real
    /// file); `exec` is the real file it resolves to, which is what runs.
    static func runMatches(argv: [String], exec: String?, found: String?, cwd: String,
                           realpath: (String) -> String?) -> Bool {
        guard let exec, exec.hasPrefix("/"), let dd = runSeparator(argv), dd + 1 < argv.count else { return false }
        let path = found ?? exec
        guard path.hasPrefix("/"), realpath(path) == exec else { return false }
        let name = argv[dd + 1]
        if name.contains("/") {
            let full = name.hasPrefix("/") ? name : cwd + "/" + name
            return URL(fileURLWithPath: full).standardized.path == path
        }
        return (path as NSString).lastPathComponent == name
    }

    /// The destination a request reports matches its arguments: `flag` appears
    /// at most once, and its value resolves to `target` (or neither is there).
    static func destinationMatches(argv: [String], flag: String, target: String?, cwd: String, home: String,
                                   realpath: (String) -> String?) -> Bool {
        let hits = argv.indices.filter { argv[$0] == flag }
        guard hits.count <= 1 else { return false }
        guard let at = hits.first else { return target == nil }
        guard at + 1 < argv.count, let target else { return false }
        return destination(argv[at + 1], cwd: cwd, home: home, realpath: realpath) == target
    }

    // MARK: What is asking

    /// The full, unshortened command a request comes from: for `run` the real
    /// file that will be executed (absolute path) and its arguments, each
    /// shown as it runs (see `displayArgument`); for `inject` the destination
    /// as it will be written.
    static func command(purpose: String, argv: [String], home: String, exec: String? = nil, target: String? = nil) -> CommandText {
        var text = "\(tool) \(purpose)"
        if purpose == "run", let dd = runSeparator(argv), dd + 1 < argv.count {
            return CommandText(lead: flatten(text + " --"), program: displayArgument(exec ?? argv[dd + 1]),
                               arguments: argv[(dd + 2)...].map(displayArgument).joined(separator: " "))
        } else if purpose == "inject" {
            if let target { text += " --to " + tilde(target, home: home) }
            if argv.dropFirst(2).contains("--force") { text += " --force" }
        }
        return CommandText(lead: flatten(text), program: nil, arguments: "")
    }

    /// One argument as the dialog shows it: line breaks and tabs as `\n`, `\r`,
    /// `\t`, and in single quotes when it is empty or holds a space, quote,
    /// backslash or line break, so `sh -c "a b"` and `sh -c a b` look different.
    /// Arguments with other invisible characters are refused before this
    /// (`argumentsDisplayFaithfully`).
    static func displayArgument(_ argument: String) -> String {
        var shown = ""
        for s in argument.unicodeScalars {
            switch s {
            case "\n": shown += "\\n"
            case "\r": shown += "\\r"
            case "\t": shown += "\\t"
            case "'": shown += "'\\''"
            default: shown.unicodeScalars.append(s)
            }
        }
        let quoted = argument.isEmpty || argument.unicodeScalars.contains { " \t\n\r'\"\\".unicodeScalars.contains($0) }
        return quoted ? "'" + shown + "'" : shown
    }

    /// True when every argument of a `run` command (the program and what
    /// follows) can be shown exactly as it runs: no control, format, bidi,
    /// variation-selector or other invisible characters besides line breaks and tabs.
    static func argumentsDisplayFaithfully(_ argv: [String]) -> Bool {
        guard let dd = runSeparator(argv) else { return true }
        return argv[(dd + 1)...].allSatisfy { argument in
            argument.unicodeScalars.allSatisfy { s in
                s == "\n" || s == "\r" || s == "\t" || !isHidden(s)
            }
        }
    }

    /// True when a destination path (`inject --to`) can be shown as it will be
    /// written: no control, line-break, tab, format, bidi, variation-selector or
    /// other invisible characters.
    static func pathDisplaysFaithfully(_ path: String) -> Bool {
        path.unicodeScalars.allSatisfy { s in
            s != "\n" && s != "\r" && s != "\t" && !isHidden(s)
        }
    }

    /// What `sanitize` removes or turns into a space (apart from line breaks and tabs).
    static func isHidden(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x0B, 0x0C, 0x85, 0x2028, 0x2029, 0xFE00...0xFE0F, 0xE0100...0xE01EF: return true
        default: return CharacterSet.controlCharacters.contains(s) || invisible.contains(s.value)
        }
    }

    /// The iPhone's copy of an approval command: from the uncut text, redacted
    /// first, shortened last (so a secret can't straddle the cut).
    static func phoneCommand(_ command: CommandText, redact: (String) -> String) -> String {
        command.mapped(redact).render(phoneCommandLimit)
    }

    /// The iPhone's copy of an approval summary, in the same order.
    static func phoneSummary(_ summary: String, redact: (String) -> String) -> String {
        elideEnd(flatten(redact(sanitize(summary))), 400)
    }

    /// Who is asking, by the client's parent processes (nearest first).
    /// `parentPID` 1 means the client was detached from its shell (its parent is launchd).
    static func who(parents: [String], parentPID: pid_t?, fromClaude: Bool) -> String {
        guard let parent = parents.first else {
            let nobody = parentPID == 1 ? "a detached process (its parent is launchd)" : "an unknown parent process"
            return fromClaude ? "claude \u{2190} \(nobody)" : nobody
        }
        guard fromClaude else { return parent }
        return parent == "claude" ? "claude" : "claude \u{2190} \(parent)"
    }

    /// Room for field names in the Touch ID text.
    static let fieldBudget = 90
    /// A field name longer than this is shortened in the middle.
    static let fieldNameLimit = 60

    /// True when every name shows in full in the dialog (none shortened, no "+N more").
    /// Requests that don't fit are refused rather than shown in part.
    static func fieldsFit(_ fields: [String]) -> Bool {
        let names = fields.map(flatten)
        return names.allSatisfy { $0.count <= fieldNameLimit } && names.joined(separator: ", ").count <= fieldBudget
    }

    /// Field names, as many as fit in `budget`, then "+N more". A single long
    /// name is shortened in the middle.
    static func fieldList(_ fields: [String], budget: Int) -> String {
        let names = fields.map { elideMiddle(flatten($0), fieldNameLimit) }
        var shown: [String] = []
        for (i, name) in names.enumerated() {
            let later = names.count - i - 1
            let candidate = (shown + [name]).joined(separator: ", ")
            if candidate.count + (later > 0 ? ", +\(later) more".count : 0) <= budget {
                shown.append(name)
                continue
            }
            guard !shown.isEmpty else {
                let more = names.count > 1 ? " +\(names.count - 1) more" : ""
                return elideEnd(name, max(budget - more.count, 8)) + more
            }
            return shown.joined(separator: ", ") + " +\(names.count - shown.count) more"
        }
        return shown.joined(separator: ", ")
    }

    /// True when `command` fits both the Touch ID dialog and the iPhone card
    /// without shortening its arguments, program file name, or `inject` path.
    /// (Only the middle of a `run` program's folder may be shortened.)
    static func commandFits(command: CommandText, who: String, cwd: String, verb: String, fields: [String],
                            limit: Int = reasonLimit) -> Bool {
        let layout = reasonLayout(command: command, who: who, cwd: cwd, verb: verb, fields: fields, limit: limit)
        return command.fitsInFull(within: min(layout.room, phoneCommandLimit))
    }

    private static func reasonLayout(command: CommandText, who: String, cwd: String, verb: String, fields: [String],
                                     limit: Int) -> (what: String, who: String, cwd: String, room: Int) {
        let what = fieldList(fields, budget: fieldBudget)
        let who = flatten(who), cwd = flatten(cwd)
        func overhead(_ whoBudget: Int, _ cwdBudget: Int) -> Int {
            let w = elideMiddle(who, whoBudget), c = elideStart(cwd, cwdBudget)
            return "allow \"\" from \(w)\(c.isEmpty ? "" : " in " + c) to \(verb): \(what)".count
        }
        let wanted = max(72, min(command.full.count, phoneCommandLimit))
        var whoBudget = min(who.count, 48), cwdBudget = min(cwd.count, 60)
        while limit - overhead(whoBudget, cwdBudget) < wanted, whoBudget > 16 || cwdBudget > 16 {
            if cwdBudget > 16 { cwdBudget -= 4 } else { whoBudget -= 4 }
        }
        let room = max(limit - overhead(whoBudget, cwdBudget), 24)
        return (what, elideMiddle(who, whoBudget), elideStart(cwd, cwdBudget), room)
    }

    /// The Touch ID dialog text, at most `limit` characters. Field names get up
    /// to 90 characters (then "+N more") and the command at least 72 (see
    /// `CommandText.render`: the program's file name always shows); who and the
    /// folder shrink first, so the end of the text is never cut.
    static func reason(command: String, who: String, cwd: String, verb: String, fields: [String],
                       limit: Int = reasonLimit) -> String {
        reason(command: CommandText(lead: flatten(command), program: nil, arguments: ""), who: who, cwd: cwd,
               verb: verb, fields: fields, limit: limit)
    }

    static func reason(command: CommandText, who: String, cwd: String, verb: String, fields: [String],
                       limit: Int = reasonLimit) -> String {
        let layout = reasonLayout(command: command, who: who, cwd: cwd, verb: verb, fields: fields, limit: limit)
        let rendered = command.render(layout.room)
        let full = "allow \"\(rendered)\" from \(layout.who)\(layout.cwd.isEmpty ? "" : " in " + layout.cwd) to \(verb): \(layout.what)"
        return full.count > limit ? elideEnd(full, limit) : full
    }

    // MARK: Remembering an approval

    /// A digest of a process environment (sorted `NAME=value` entries).
    static func environmentDigest(_ environment: [String: String]) -> String {
        var data = Data()
        for (name, value) in environment.sorted(by: { $0.key < $1.key }) {
            data.append(contentsOf: Array("\(name)=\(value)".utf8))
            data.append(0)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// What the grace window is tied to: the immediate parent, by pid and start
    /// time (a recycled pid doesn't match). Nil (no grace, every call asks) when
    /// Claude Code is anywhere in the chain (an agent can change what an
    /// approved command reads, such as a script or a Makefile, and re-run it),
    /// for a detached caller (parent launchd), or when the parent can't be read.
    static func graceAnchor(parentPID: pid_t?, parentStart: UInt64?,
                            chain: [(pid: pid_t, start: UInt64?, isClaude: Bool)]) -> String? {
        if chain.contains(where: { $0.isClaude }) { return nil }
        guard let pid = parentPID, pid > 1, let start = parentStart else { return nil }
        return "parent:\(pid)@\(start)"
    }

    /// What a CLI approval is remembered under for the grace window, or nil
    /// for "always ask". A repeat skips the prompt only for the same purpose,
    /// fields, directory, arguments, environment, program or destination
    /// (`extra`), and anchor.
    static func graceKey(purpose: String, cwd: String?, fields: [String], argv: [String], environment: String?,
                         extra: [String] = [], anchor: String?) -> String? {
        guard let cwd, !cwd.isEmpty, !argv.isEmpty, let environment, !environment.isEmpty, let anchor else { return nil }
        struct Scope: Encodable {
            let purpose: String
            let cwd: String
            let fields: [String]
            let argv: [String]
            let environment: String
            let extra: [String]
            let anchor: String
        }
        let scope = Scope(purpose: purpose, cwd: cwd, fields: Set(fields).sorted(), argv: argv,
                          environment: environment, extra: extra, anchor: anchor)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(scope)).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// A command line as an approval shows it, kept in parts so that shortening
/// can never hide the program: for `run`, the program's directory is shortened
/// in the middle (its root always shows) and so are its arguments, but its file name always
/// shows in full.
struct CommandText: Equatable {
    /// e.g. "keynod run --", or the whole text when there is no program.
    let lead: String
    /// For `run`: the absolute path of the real file that runs.
    let program: String?
    /// For `run`: the program's arguments, on one line.
    let arguments: String

    var full: String {
        guard let program else { return lead }
        return lead + " " + program + (arguments.isEmpty ? "" : " " + arguments)
    }

    func mapped(_ transform: (String) -> String) -> CommandText {
        CommandText(lead: transform(lead), program: program.map(transform), arguments: transform(arguments))
    }

    /// True when `render(limit)` shows the command without shortening its
    /// arguments or program file name (only the middle of a `run` program's
    /// folder may be shortened), or without shortening the whole text when
    /// there is no program (e.g. `inject --to`).
    func fitsInFull(within limit: Int) -> Bool {
        if full.count <= limit { return true }
        guard let program else { return false }
        let rawName = (program as NSString).lastPathComponent
        guard rawName.count <= 40 else { return false }
        let dir = (program as NSString).deletingLastPathComponent
        let gap = arguments.isEmpty ? 0 : 1
        let room = limit - lead.count - 1 - rawName.count - 1 - gap
        guard room > 0 else { return false }
        let minDir = dir == "/" ? 0 : min(dir.count, max(room / 3, 6))
        guard arguments.count <= room - minDir else { return false }
        let rendered = render(limit)
        guard rendered.count <= limit else { return false }
        return arguments.isEmpty
            ? rendered.hasSuffix("/" + rawName)
            : rendered.hasSuffix("/" + rawName + " " + arguments)
    }

    /// At most `limit` characters (for any `limit` of about 40 or more).
    func render(_ limit: Int) -> String {
        let whole = full
        guard whole.count > limit else { return whole }
        guard let program else { return ApprovalText.elideMiddle(whole, limit) }
        let name = ApprovalText.elideMiddle((program as NSString).lastPathComponent, 40)
        let dir = (program as NSString).deletingLastPathComponent
        let gap = arguments.isEmpty ? 0 : 1
        let room = limit - lead.count - 1 - name.count - 1 - gap
        // The arguments get two thirds of what is left (all they need if less); the directory the rest.
        var argBudget = arguments.isEmpty ? 0 : max(min(arguments.count, room - min(dir.count, max(room / 3, 6))), 12)
        var dirBudget = min(dir.count, max(room - argBudget, 2))
        if dirBudget + argBudget > room { argBudget = max(room - dirBudget, 12); dirBudget = max(room - argBudget, 2) }
        let dirText = dir == "/" ? "" : ApprovalText.elideMiddle(dir, dirBudget)
        let args = arguments.isEmpty ? "" : " " + ApprovalText.elideMiddle(arguments, argBudget)
        let text = lead + " " + dirText + "/" + name + args
        return text.count > limit ? ApprovalText.elideEnd(text, limit) : text
    }
}

/// Recognises Claude Code in a process chain. A guardrail, not a boundary:
/// a caller that detaches from Claude's process tree is not seen.
enum ClaudeProcess {
    /// Claude Code runs as a native binary named `claude` (the installer's
    /// `~/.local/share/claude/versions/<version>`), or as node running the npm
    /// package `@anthropic-ai/claude-code`. Only whole path components count,
    /// so `/Users/claude/bin/zsh` or `/opt/claudette` are not Claude.
    static func matches(name: String, path: String?, argv: [String]) -> Bool {
        if name.lowercased() == "claude" { return true }
        if let path, isClaudePath(path) { return true }
        return argv.prefix(3).contains(where: isClaudePath)
    }

    static func isClaudePath(_ path: String) -> Bool {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        guard let last = parts.last else { return false }
        if last == "claude" { return true }
        if parts.count >= 3, parts[parts.count - 3] == "claude", parts[parts.count - 2] == "versions" { return true }
        if let i = parts.firstIndex(of: "@anthropic-ai"), i + 1 < parts.count, parts[i + 1] == "claude-code" { return true }
        return false
    }
}
