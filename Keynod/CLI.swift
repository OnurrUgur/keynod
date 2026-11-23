import Darwin
import Foundation

/// The `keynod` command. This is the same binary as the app, started through a
/// symlink named `keynod`; it only talks to the running app over the socket and
/// never touches the Vault or the Keychain itself.
enum CLI {
    static let usage = """
    keynod \u{2014} biometric secret vault & AI agent approval gate

    usage:
      keynod list [--json] [query...]            secrets and their fields (concealed values are never shown);
                                                 with a query, only secrets matching every word
                                                 (title, description, #tags, field labels, plain values)
      keynod secret add --title "T" [--details "text #tags"] [--field "Label=value"]...
                        [--concealed "Label"]... [--file "Label=path"]...
                                                 create a new secret (asks for approval; never modifies
                                                 an existing one, refuses a duplicate title or Key ID).
                                                 A --concealed value is typed without echo (or read from
                                                 stdin), so it stays out of argv and shell history
      keynod secret delete <id or full title>... permanently delete secrets and their values
                                                 (asks for approval every time; exact id or full title only)
      keynod run [--env NAME=ref]... [--file NAME=ref]... -- cmd args...
                                                 run cmd with secrets in its environment / temp files
                                                 (non-TTY output replaces secret values with <concealed>)
      keynod inject ref --to path [--force]      write a secret value to a 0600 file
      keynod get ref --reveal                    print a value (refused inside Claude Code sessions)
      keynod decide "Question?" --option A --option B [--text] [--timeout 30m]
                                                 ask on the paired iPhone and print the answer
      keynod code "Service" [--timeout 10m]      ask on the paired iPhone for a verification code
      keynod hooks install | uninstall | status  manage Claude Code hooks (~/.claude/settings.json)
                                                 that forward permission prompts and questions to iPhone
      keynod hook permission | stop | question   invoked by Claude Code with JSON on stdin

    ref is "<secret>/<field>", e.g. "App Store Connect/Private Key". The secret
    is matched by id or by title (case-insensitive, unique substring is enough).
    The stable form is "<id>/<field label>", e.g. "3F2A9C1E-.../Key ID".
    """

    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        var args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else { print(usage); exit(0) }
        let command = args.removeFirst()
        switch command {
        case "help", "-h", "--help": print(usage); exit(0)
        case "list": list(args)
        case "secret": secret(args)
        case "run": runCommand(args)
        case "inject": inject(args)
        case "get": get(args)
        case "decide": decide(args)
        case "code": code(args)
        case "hook": hook(args)
        case "hooks": hooks(args)
        default: fail("unknown command \"\(command)\" (try `keynod help`)")
        }
    }

    // MARK: list

    private static func list(_ args: [String]) -> Never {
        var json = false
        var words: [String] = []
        for a in args {
            if a == "--json" { json = true } else if a.hasPrefix("--") { fail("list: unexpected \"\(a)\"") } else { words.append(a) }
        }
        var secrets = call(CLIRequest(op: "list")).secrets ?? []
        if !words.isEmpty { secrets = secrets.filter { CLIFilter.matches($0, words: words) } }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: (try? encoder.encode(["secrets": secrets])) ?? Data(), as: UTF8.self))
            exit(0)
        }
        if secrets.isEmpty { print(words.isEmpty ? "no secrets" : "no secrets match") }
        for (i, s) in secrets.enumerated() {
            if i > 0 { print("") }
            print("\(s.title)  [\(s.id)]")
            for line in s.details.split(separator: "\n") { print("  \(line)") }
            if !s.tags.isEmpty { print("  tags: " + s.tags.map { "#" + $0 }.joined(separator: " ")) }
            for f in s.fields {
                let shown: String
                if f.concealed {
                    shown = f.filename.map { "(concealed file \($0))" } ?? "(concealed)"
                } else {
                    shown = f.value ?? ""
                }
                print("  \(f.label): \(shown)")
            }
        }
        exit(0)
    }

    // MARK: secret

    private static func secret(_ args: [String]) -> Never {
        guard let sub = args.first else { print(usage); exit(1) }
        if sub == "help" || sub == "--help" || sub == "-h" { print(usage); exit(0) }
        switch sub {
        case "add": secretAdd(Array(args.dropFirst()))
        case "delete": secretDelete(Array(args.dropFirst()))
        default: fail("secret: unknown subcommand \"\(sub)\" (try `keynod secret --help`)")
        }
    }

    private static func secretDelete(_ args: [String]) -> Never {
        if args.contains(where: { $0 == "--help" || $0 == "-h" }) { print(usage); exit(0) }
        if let flag = args.first(where: { $0.hasPrefix("--") }) {
            fail("secret delete: unexpected \"\(flag)\" (it takes only ids or full titles)")
        }
        guard !args.isEmpty else { fail("secret delete: name at least one secret by its id or its full title") }
        let reply = call(CLIRequest(op: "delete", cwd: cwd(), refs: args))
        print(reply.message ?? "deleted")
        exit(0)
    }

    private static func secretAdd(_ args: [String]) -> Never {
        var title: String?, details: String?
        var fields: [CLIField] = []
        var i = 0
        func next(_ flag: String) -> String {
            guard i + 1 < args.count else { fail("secret add: \(flag) needs a value") }
            i += 1
            return args[i]
        }
        func labelValue(_ flag: String) -> (label: String, value: String) {
            let spec = next(flag)
            guard let eq = spec.firstIndex(of: "=") else { fail("secret add: \(flag) needs Label=value") }
            let label = String(spec[..<eq]).trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { fail("secret add: \(flag) has an empty label") }
            return (label, String(spec[spec.index(after: eq)...]))
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--help", "-h": print(usage); exit(0)
            case "--title": title = next(a)
            case "--details": details = next(a)
            case "--field":
                let f = labelValue(a)
                fields.append(CLIField(label: f.label, concealed: false, value: f.value))
            case "--concealed":
                let spec = next(a)
                if spec.contains("=") {
                    // Works, but the value sits in argv (visible to `ps`) and in shell history.
                    fputs("keynod: warning: a value on the command line is visible to other processes and kept in "
                        + "shell history; pass just --concealed \"Label\" to type it instead\n", stderr)
                    i -= 1
                    let f = labelValue(a)
                    fields.append(CLIField(label: f.label, concealed: true, data: Data(f.value.utf8)))
                } else {
                    let label = spec.trimmingCharacters(in: .whitespaces)
                    guard !label.isEmpty else { fail("secret add: \(a) has an empty label") }
                    fields.append(CLIField(label: label, concealed: true, data: nil))
                }
            case "--file":
                let f = labelValue(a)
                let url = URL(fileURLWithPath: absolutePath(f.value))
                guard let data = try? Data(contentsOf: url) else { fail("secret add: could not read \(url.path)") }
                guard data.count <= AppModel.maxFileSize else { fail("secret add: \(url.lastPathComponent) is larger than 1 MB") }
                fields.append(CLIField(label: f.label, concealed: true, filename: url.lastPathComponent, data: data))
            default: fail("secret add: unexpected \"\(a)\" (try `keynod secret --help`)")
            }
            i += 1
        }
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail("secret add: missing --title (try `keynod secret --help`)")
        }
        // Concealed fields given without a value: typed without echo, or read from stdin.
        let missing = fields.indices.filter { fields[$0].concealed && fields[$0].data == nil }
        if !missing.isEmpty {
            if isatty(0) != 0 {
                for index in missing { fields[index].data = Data(promptHidden("\(fields[index].label): ").utf8) }
            } else {
                guard missing.count == 1 else {
                    fail("secret add: stdin can hold the value of only one --concealed field; give the others as Label=value")
                }
                var value = FileHandle.standardInput.readDataToEndOfFile()
                while let last = value.last, last == 0x0A || last == 0x0D { value.removeLast() }
                fields[missing[0]].data = value
            }
            for index in missing where (fields[index].data ?? Data()).isEmpty {
                fail("secret add: no value given for \(fields[index].label)")
            }
        }
        let reply = call(CLIRequest(op: "create", cwd: cwd(), title: title, details: details, fields: fields))
        print(reply.message ?? "created")
        exit(0)
    }

    /// Reads a line from the terminal without echoing it (`readpassphrase`).
    private static func promptHidden(_ prompt: String) -> String {
        var buffer = [CChar](repeating: 0, count: 16 * 1024)
        defer { buffer.withUnsafeMutableBufferPointer { _ = memset($0.baseAddress!, 0, $0.count) } }
        guard readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else {
            fail("secret add: could not read the value from the terminal")
        }
        return String(cString: buffer)
    }

    // MARK: run

    private static func runCommand(_ args: [String]) -> Never {
        var specs: [(name: String, ref: String, isFile: Bool)] = []
        var command: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--" { command = Array(args[(i + 1)...]); break }
            guard a == "--env" || a == "--file" else { fail("run: unexpected \"\(a)\" (put the command after `--`)") }
            guard i + 1 < args.count, let eq = args[i + 1].firstIndex(of: "=") else {
                fail("run: \(a) needs NAME=ref")
            }
            let spec = args[i + 1]
            let name = String(spec[..<eq])
            let ref = String(spec[spec.index(after: eq)...])
            guard isValidName(name) else { fail("run: invalid variable name \"\(name)\"") }
            specs.append((name, ref, a == "--file"))
            i += 2
        }
        guard !command.isEmpty else { fail("run: missing command (keynod run --env NAME=ref -- cmd args...)") }
        guard !specs.isEmpty else { fail("run: nothing to inject; pass --env NAME=ref or --file NAME=ref") }
        // The program is found here, the way posix_spawnp would, so the approval names
        // the exact file that will run (a PATH entry can't swap it afterwards).
        // The real file (symlinks resolved) is what the approval names and what runs; its
        // identity is checked again just before it runs, so a swap in between is refused.
        guard let found = ApprovalText.executable(command[0], path: ProcessInfo.processInfo.environment["PATH"],
                                                  cwd: cwd(), isExecutable: isExecutableFile),
              let program = realPath(found), let identity = fileIdentity(program) else {
            fputs("keynod: \(command[0]): command not found\n", stderr)
            exit(127)
        }

        var request = CLIRequest(op: "read", cwd: cwd(), purpose: "run", refs: specs.map(\.ref))
        request.caller = .current(exec: program, execFound: found == program ? nil : found, programIdentity: identity)
        let reply = call(request)
        guard let values = reply.values, values.count == specs.count else { fail("unexpected reply from Keynod") }

        var env = ProcessInfo.processInfo.environment
        var needles: [Data] = []
        var tempDir: String?
        func cleanup() { if let tempDir { try? FileManager.default.removeItem(atPath: tempDir) } }

        for (spec, value) in zip(specs, values) {
            if value.concealed { needles.append(contentsOf: maskNeedles(value.data)) }
            if spec.isFile {
                if tempDir == nil {
                    var template = Array((NSTemporaryDirectory() + "keynod-XXXXXX").utf8CString)
                    guard mkdtemp(&template) != nil else { fail("run: could not create a temp directory") }
                    tempDir = String(cString: template)
                    chmod(tempDir!, 0o700)
                }
                let base = (value.filename.map { URL(fileURLWithPath: $0).lastPathComponent }) ?? spec.name
                let path = "\(tempDir!)/\(specs.firstIndex { $0.name == spec.name }!)-\(base)"
                do { try writeFile(path, value.data, force: false) } catch {
                    cleanup()
                    fail("run: could not write temp file: \(error)")
                }
                env[spec.name] = path
            } else {
                guard let text = String(data: value.data, encoding: .utf8) else {
                    cleanup()
                    fail("run: \(value.label) is not text and can't go into an environment variable (use --file)")
                }
                env[spec.name] = text
            }
        }

        guard fileIdentity(program) == identity else {
            cleanup()
            fail("run: \(program) changed while waiting for approval; nothing was run")
        }
        let status = spawn(program, command, env: env, mask: needles)
        cleanup()
        exit(status)
    }

    /// Runs `program` (an absolute path) with `command` as its arguments.
    private static func spawn(_ program: String, _ command: [String], env: [String: String], mask needles: [Data]) -> Int32 {
        let maskOut = isatty(1) == 0
        let maskErr = isatty(2) == 0
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        for pair in [(maskOut, 0), (maskErr, 1)] where pair.0 {
            var fds: [Int32] = [-1, -1]
            guard pipe(&fds) == 0 else { fail("run: could not create a pipe") }
            fds.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
            if pair.1 == 0 { outPipe = fds } else { errPipe = fds }
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        if maskOut { posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1) }
        if maskErr { posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for s in [SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGPIPE] { sigaddset(&defaults, s) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF))

        let argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        signal(SIGINT, SIG_IGN)
        signal(SIGQUIT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGHUP, SIG_IGN)

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, program, &actions, &attr, argv, envp)
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)
        if maskOut { close(outPipe[1]) }
        if maskErr { close(errPipe[1]) }
        guard rc == 0 else {
            fputs("keynod: \(program): \(String(cString: strerror(rc)))\n", stderr)
            return rc == ENOENT ? 127 : 126
        }

        let forwarded = [SIGTERM, SIGHUP].map { sig -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { kill(pid, sig) }
            source.resume()
            return source
        }
        let group = DispatchGroup()
        if maskOut { pump(from: outPipe[0], to: 1, needles: needles, group: group) }
        if maskErr { pump(from: errPipe[0], to: 2, needles: needles, group: group) }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        group.wait()
        forwarded.forEach { $0.cancel() }
        if status & 0x7f == 0 { return (status >> 8) & 0xff }
        return 128 + (status & 0x7f)
    }

    private static func pump(from fd: Int32, to out: Int32, needles: [Data], group: DispatchGroup) {
        group.enter()
        Thread.detachNewThread {
            defer { group.leave(); close(fd) }
            var pending = Data()
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            func emit(_ data: Data) {
                let masked = mask(data, needles: needles)
                masked.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let n = write(out, raw.baseAddress! + offset, raw.count - offset)
                        if n < 0 && errno == EINTR { continue }
                        if n <= 0 { return }
                        offset += n
                    }
                }
            }
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                pending.append(contentsOf: chunk[0..<n])
                while let nl = pending.firstIndex(of: 0x0A) {
                    emit(pending[pending.startIndex...nl])
                    pending = Data(pending[(nl + 1)...])
                }
            }
            if !pending.isEmpty { emit(pending) }
        }
    }

    private static func maskNeedles(_ data: Data) -> [Data] {
        var result: [Data] = []
        let whole = trimmed(data)
        if !whole.isEmpty { result.append(whole) }
        for line in data.split(separator: 0x0A) {
            let t = trimmed(Data(line))
            if t.count >= 4, t != whole { result.append(t) }
        }
        return result
    }

    private static func trimmed(_ data: Data) -> Data {
        var d = data
        while let last = d.last, last == 0x0A || last == 0x0D || last == 0x20 { d.removeLast() }
        while let first = d.first, first == 0x0A || first == 0x0D || first == 0x20 { d.removeFirst() }
        return d
    }

    static func mask(_ data: Data, needles: [Data]) -> Data {
        guard !needles.isEmpty else { return data }
        var out = data
        let marker = Data("<concealed>".utf8)
        for needle in needles.sorted(by: { $0.count > $1.count }) where !needle.isEmpty {
            var searchStart = out.startIndex
            while let r = out.range(of: needle, in: searchStart..<out.endIndex) {
                out.replaceSubrange(r, with: marker)
                searchStart = r.lowerBound + marker.count
            }
        }
        return out
    }

    // MARK: inject / get

    private static func inject(_ args: [String]) -> Never {
        var ref: String?, target: String?, force = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--to":
                guard target == nil else { fail("inject: --to may be given only once") }
                guard i + 1 < args.count else { fail("inject: --to needs a path") }
                target = args[i + 1]; i += 1
            case "--force": force = true
            default:
                guard ref == nil, !args[i].hasPrefix("--") else { fail("inject: unexpected \"\(args[i])\"") }
                ref = args[i]
            }
            i += 1
        }
        guard let ref, let target else { fail("usage: keynod inject ref --to path [--force]") }
        // Resolved the same way the app checks it; this exact path is shown in the approval.
        guard let path = ApprovalText.destination(target, cwd: cwd(), home: NSHomeDirectory(), realpath: realPath) else {
            fail("inject: unsupported destination \"\(target)\" (use an absolute, relative or ~/ path)")
        }
        if !force && FileManager.default.fileExists(atPath: path) {
            fail("inject: \(path) already exists (use --force to overwrite)")
        }
        var request = CLIRequest(op: "read", cwd: cwd(), purpose: "inject", refs: [ref])
        request.caller = .current(target: path)
        let reply = call(request)
        guard let value = reply.values?.first else { fail("unexpected reply from Keynod") }
        do {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try writeFile(path, value.data, force: force, expected: path)
        } catch {
            fail("inject: could not write \(path): \(error)")
        }
        if !isGitIgnoredOrOutside(path) {
            fputs("keynod: warning: \(path) is inside a git work tree and is not ignored; add it to .gitignore\n", stderr)
        }
        print(path)
        exit(0)
    }

    private static func get(_ args: [String]) -> Never {
        var ref: String?, reveal = false
        for a in args {
            if a == "--reveal" { reveal = true } else if ref == nil, !a.hasPrefix("--") { ref = a } else {
                fail("get: unexpected \"\(a)\"")
            }
        }
        guard let ref else { fail("usage: keynod get ref --reveal") }
        guard reveal else {
            fail("get prints the secret value. Pass --reveal if you really want that; to use a secret in a command or file prefer `keynod run --env NAME=ref -- cmd` or `keynod inject ref --to path`.")
        }
        let reply = call(CLIRequest(op: "read", cwd: cwd(), purpose: "get", refs: [ref]))
        guard let value = reply.values?.first else { fail("unexpected reply from Keynod") }
        var data = value.data
        if isatty(1) != 0, data.last != 0x0A { data.append(0x0A) }
        FileHandle.standardOutput.write(data)
        exit(0)
    }

    // MARK: decide / code

    private static func duration(_ text: String, for command: String) -> TimeInterval {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [Character: Double] = ["s": 1, "m": 60, "h": 3600]
        var number = t, factor = 1.0
        if let last = t.last, let unit = units[last] { number = String(t.dropLast()); factor = unit }
        guard let n = Double(number), n > 0 else { fail("\(command): bad --timeout \"\(text)\" (use e.g. 90s, 30m, 1h)") }
        return n * factor
    }

    private static func decide(_ args: [String]) -> Never {
        var words: [String] = [], options: [String] = []
        var text = false
        var timeout: TimeInterval = 30 * 60
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--help", "-h": print(usage); exit(0)
            case "--option":
                guard i + 1 < args.count else { fail("decide: --option needs a value") }
                options.append(args[i + 1]); i += 1
            case "--text": text = true
            case "--timeout":
                guard i + 1 < args.count else { fail("decide: --timeout needs a value") }
                timeout = duration(args[i + 1], for: "decide"); i += 1
            default:
                guard !a.hasPrefix("--") else { fail("decide: unexpected \"\(a)\" (keynod decide \"Question?\" --option A --option B [--text])") }
                words.append(a)
            }
            i += 1
        }
        let question = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { fail("decide: missing question (keynod decide \"Question?\" --option A --option B)") }
        guard !options.isEmpty || text else { fail("decide: give at least one --option, or --text for an answer in words") }
        let reply = call(CLIRequest(op: "ask", cwd: cwd(), kind: "decide", command: "Decision", summary: question,
                                    body: question, options: options.isEmpty ? nil : options, input: text ? "text" : nil,
                                    timeout: timeout))
        printAnswer(reply, noAnswer: "decide")
    }

    private static func code(_ args: [String]) -> Never {
        var words: [String] = []
        var timeout: TimeInterval = 10 * 60
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--help", "-h": print(usage); exit(0)
            case "--timeout":
                guard i + 1 < args.count else { fail("code: --timeout needs a value") }
                timeout = duration(args[i + 1], for: "code"); i += 1
            default:
                guard !a.hasPrefix("--") else { fail("code: unexpected \"\(a)\" (keynod code \"Service\" [--timeout 10m])") }
                words.append(a)
            }
            i += 1
        }
        let service = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !service.isEmpty else { fail("code: missing service name (keynod code \"Service\")") }
        let reply = call(CLIRequest(op: "ask", cwd: cwd(), kind: "code", command: "Code",
                                    summary: "\(service) verification code", input: "code", timeout: timeout))
        printAnswer(reply, noAnswer: "code")
    }

    private static func printAnswer(_ reply: CLIResponse, noAnswer command: String) -> Never {
        switch reply.outcome {
        case "answered":
            let choice = reply.choice ?? ""
            let text = (reply.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !choice.isEmpty || !text.isEmpty else { fail("\(command): the iPhone sent an empty answer") }
            if !choice.isEmpty { print(choice) }
            if !text.isEmpty { print(text) }
            exit(0)
        case "denied": fail("\(command): declined on the iPhone")
        case "timedOut": fail("\(command): no answer from the iPhone in time")
        case "unavailable": fail("\(command): the iPhone could not be asked (\(reply.message ?? "unknown reason"))")
        default: fail("\(command): unexpected reply from Keynod")
        }
    }

    // MARK: Claude Code hooks

    private static func hooks(_ args: [String]) -> Never {
        let sub = args.first ?? "status"
        if sub == "help" || sub == "--help" || sub == "-h" { print(usage); exit(0) }
        guard args.count <= 1, ["install", "uninstall", "status"].contains(sub) else {
            fail("hooks: expected install, uninstall or status (try `keynod hooks --help`)")
        }
        do {
            if sub == "status" {
                switch ClaudeHooks.state() {
                case .installed: print("installed")
                case .partial: print("partly installed (run `keynod hooks install` to complete it)")
                case .notInstalled: print("not installed")
                case .unreadable(let why): fail("hooks: \(why)")
                }
                exit(0)
            }
            let report = try (sub == "install" ? ClaudeHooks.install() : ClaudeHooks.uninstall())
            report.lines.forEach { print($0) }
            if let backup = report.backup { print("backup: \(backup.path)") }
            exit(0)
        } catch {
            fail("hooks: \(error)")
        }
    }

    private static func hook(_ args: [String]) -> Never {
        if ClaudeHooks.isOff() { exit(0) }
        guard args.count == 1, ["permission", "stop", "question"].contains(args[0]) else {
            fail("usage: keynod hook permission|stop|question")
        }
        if isatty(0) != 0 { fail("hook reads the JSON that Claude Code sends on stdin; it isn't meant to be run by hand") }
        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        if args[0] == "question" { questionHook(stdin) }
        let permission = args[0] == "permission"
        guard let ask = permission ? ClaudeHooks.permissionAsk(stdin: stdin) : ClaudeHooks.stopAsk(stdin: stdin) else { exit(0) }
        if let dir = ask.cwd, dir.hasPrefix("/") { _ = FileManager.default.changeCurrentDirectoryPath(dir) }
        guard let reply = hookCall(CLIRequest(op: "ask", cwd: cwd(), kind: ask.kind, command: ask.command, summary: ask.summary,
                                              body: ask.body, options: ask.options, input: ask.input,
                                              images: ask.images.isEmpty ? nil : ask.images,
                                              timeout: ClaudeHooks.askTimeout, requireRemote: true)) else { exit(0) }
        let output = permission
            ? ClaudeHooks.permissionOutput(outcome: reply.outcome)
            : ClaudeHooks.stopOutput(outcome: reply.outcome, choice: reply.choice, text: reply.text)
        if let output { print(output) }
        exit(0)
    }

    private static func questionHook(_ stdin: Data) -> Never {
        guard let question = ClaudeHooks.toolQuestion(stdin: stdin) else { exit(0) }
        if let dir = question.asks.first?.cwd, dir.hasPrefix("/") { _ = FileManager.default.changeCurrentDirectoryPath(dir) }
        let each = ClaudeHooks.askTimeout / Double(question.asks.count)
        var answers: [ClaudeHooks.ToolAnswer] = []
        for ask in question.asks {
            guard let reply = hookCall(CLIRequest(op: "ask", cwd: cwd(), kind: ask.kind, command: ask.command,
                                                  summary: ask.summary, body: ask.body, options: ask.options,
                                                  input: ask.input, images: ask.images.isEmpty ? nil : ask.images,
                                                  timeout: each, requireRemote: true)),
                  reply.outcome == "answered" else { exit(0) }
            answers.append(ClaudeHooks.ToolAnswer(choice: reply.choice, text: reply.text))
        }
        if let output = ClaudeHooks.toolQuestionOutput(question, answers: answers) { print(output) }
        exit(0)
    }

    /// Nil (so the hook stays silent and Claude Code shows its own prompt) when
    /// Keynod isn't running, or when whatever listens on the socket isn't Keynod.
    private static func hookCall(_ request: CLIRequest) -> CLIResponse? {
        guard case .server(let fd) = CLIProtocol.connectVerified(to: CLIProtocol.socketPath) else { return nil }
        defer { close(fd) }
        guard let reply = try? CLIProtocol.exchange(fd, request), reply.ok else { return nil }
        return reply
    }

    // MARK: Files and git

    /// Never follows a symlink at `path` itself (O_NOFOLLOW).
    /// With `expected`, the opened file's real path (F_GETPATH) must be exactly that before a
    /// byte is written (or an existing file truncated): a folder swapped for a symlink while
    /// waiting for approval is caught, nothing is written, and a file this call created is removed.
    private static func writeFile(_ path: String, _ data: Data, force: Bool, expected: String? = nil) throws {
        var created = true
        var fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0, errno == EEXIST, force {
            created = false
            fd = open(path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { throw CLIError(String(cString: strerror(errno))) }
        defer { close(fd) }
        if let expected {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
            let actual = fcntl(fd, F_GETPATH, &buffer) == 0 ? String(cString: buffer) : nil
            guard actual == expected else {
                if created { unlink(actual ?? path) }
                throw CLIError("the destination resolves to \(actual ?? "an unknown path") instead of \(expected) "
                    + "(changed while waiting for approval?); nothing was written")
            }
        }
        if !created { guard ftruncate(fd, 0) == 0 else { throw CLIError(String(cString: strerror(errno))) } }
        fchmod(fd, 0o600)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { throw CLIError(String(cString: strerror(errno))) }
                offset += n
            }
        }
    }

    private static func isGitIgnoredOrOutside(_ path: String) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        guard git(dir, ["rev-parse", "--is-inside-work-tree"]) == 0 else { return true }
        return git(dir, ["check-ignore", "-q", path]) == 0
    }

    private static func git(_ dir: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: Helpers

    private static func isValidName(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, first == "_" || ("A"..."Z").contains(first) || ("a"..."z").contains(first)
        else { return false }
        return s.unicodeScalars.allSatisfy { $0 == "_" || ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    private static func cwd() -> String { FileManager.default.currentDirectoryPath }

    private static func absolutePath(_ p: String) -> String {
        let expanded = (p as NSString).expandingTildeInPath
        let full = expanded.hasPrefix("/") ? expanded : cwd() + "/" + expanded
        return URL(fileURLWithPath: full).standardized.path
    }

    /// This binary's real path (symlinks resolved), from the loader rather than argv[0].
    private static func executablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return realPath(String(cString: buffer))
    }

    static func realPath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard realpath(path, &buffer) != nil else { return nil }
        return String(cString: buffer)
    }

    /// Device, inode, size, modification and status-change time: changes when the file is replaced or
    /// rewritten, even if its modification time is set back (`utimes` can't set the status-change time).
    private static func fileIdentity(_ path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
            + ":\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
    }

    private static func isExecutableFile(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && access(path, X_OK) == 0
    }

    static func fail(_ message: String) -> Never {
        fputs("keynod: \(message)\n", stderr)
        exit(1)
    }

    // MARK: Transport

    private static func call(_ request: CLIRequest) -> CLIResponse {
        let fd = connectLaunchingIfNeeded()
        defer { close(fd) }
        let reply: CLIResponse
        do {
            reply = try CLIProtocol.exchange(fd, request)
        } catch let failure as ChannelKey.Failure {
            fail("could not talk to Keynod: \(failure). If an older copy of Keynod is still running, quit it and try again.")
        } catch {
            // Whatever the app said in plain text (if anything) is not shown: it isn't authenticated.
            fail("Keynod refused this command or answered in a way it can't verify (not this Keynod build, "
                + "or an incompatible version). If an older copy of Keynod is still running, quit it and try again.")
        }
        if !reply.ok { fail(reply.error ?? "failed") }
        return reply
    }

    /// A connection to the running app, verified before anything is sent. A
    /// socket held by another program counts as "not running": the app is
    /// started (it takes the socket over) and nothing is ever sent to the stand-in.
    private static func connectLaunchingIfNeeded() -> Int32 {
        let path = CLIProtocol.socketPath
        var foreign: PeerIdentity.Failure?
        func attempt() -> Int32? {
            switch CLIProtocol.connectVerified(to: path) {
            case .server(let fd): return fd
            case .foreign(let why): foreign = why
            case .none: break
            }
            return nil
        }
        func notRunning(_ fallback: String) -> Never {
            guard let foreign else { fail(fallback) }
            fail("Keynod isn't running: \(path) is held by another program (\(foreign)). "
                + "Nothing was sent. If you just rebuilt Keynod, quit the old copy and try again.")
        }
        if let fd = attempt() { return fd }
        guard Store.dataDirOverride == nil else { notRunning("Keynod isn't running") }
        // argv[0] is just "keynod" when run through PATH: use the real executable.
        guard let executable = executablePath() else { fail("could not find the Keynod app") }
        let appURL = URL(fileURLWithPath: executable)
            .deletingLastPathComponent() // MacOS
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // Keynod.app
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-gj", appURL.path]
        do { try p.run(); p.waitUntilExit() } catch { fail("could not launch Keynod") }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            usleep(150_000)
            if let fd = attempt() { return fd }
        }
        notRunning("Keynod isn't running (could not start it)")
    }
}
