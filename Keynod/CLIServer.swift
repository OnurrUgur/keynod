import AppKit
import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security

/// Listens on `<data dir>/keynod.sock` for the `keynod` command.
/// Metadata calls (`list`) and plain fields are answered directly; concealed
/// values are released, and secrets created or deleted, only after a Touch ID
/// dialog naming the caller (or Face ID approval on the paired iPhone).
/// Every connection is checked twice: the peer's code signature
/// (`PeerIdentity`), then the request must arrive sealed with the channel key
/// (`SecureChannel`, `ChannelKey`).
final class CLIServer {
    static let shared = CLIServer()
    private let approvals = CLIApprovals()
    private var started = false
    private var channelKey: SymmetricKey?

    /// What the keychain said when the channel key was set up. `.file` means it
    /// refused this build (-34018), so the Vault can't store secrets either;
    /// nil after `start()` means the CLI is unavailable (see `channelProblem`).
    private(set) var channelLocation: ChannelKey.Location?
    private(set) var channelProblem: String?

    func start() {
        guard !started else { return }
        started = true
        _ = PhoneLink.shared
        signal(SIGPIPE, SIG_IGN)
        let dir = Store.dataDir
        Store.makeDataDir()
        chmod(dir.path, 0o700)
        // The channel key exists before anyone can connect.
        do {
            let loaded = try ChannelKey.loadOrCreate()
            channelKey = loaded.key
            channelLocation = loaded.location
        } catch {
            channelProblem = "\(error)"
            NSLog("%@", "Keynod CLI: not listening, no channel key: \(error)")
            return
        }
        let path = CLIProtocol.socketPath
        guard var addr = CLIProtocol.makeAddress(path) else {
            NSLog("%@", "Keynod CLI: socket path too long: \(path)")
            return
        }
        // Another Keynod already answering here keeps the socket. Anything else
        // listening on the path is not trusted and loses it.
        switch CLIProtocol.connectVerified(to: path) {
        case .server(let probe):
            close(probe)
            NSLog("Keynod CLI: socket already in use by another Keynod, not listening")
            return
        case .foreign(let why):
            NSLog("%@", "Keynod CLI: replacing a socket held by another program (\(why))")
        case .none:
            break
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let old = umask(0o177)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(old)
        guard bound == 0, listen(fd, 16) == 0 else {
            NSLog("%@", "Keynod CLI: could not listen on \(path): \(String(cString: strerror(errno)))")
            close(fd)
            return
        }
        chmod(path, 0o600)
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    return
                }
                _ = fcntl(client, F_SETFD, FD_CLOEXEC)
                DispatchQueue.global(qos: .userInitiated).async { self?.serve(client) }
            }
        }
    }

    // MARK: Connection

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // Only the `keynod` command (this app's own binary) may talk here: same user,
        // and code that satisfies our designated requirement. Fails closed.
        let peer: PeerIdentity.Peer
        switch PeerIdentity.verify(fd) {
        case .success(let verified):
            peer = verified
        case .failure(let failure):
            if failure.otherUser { return }
            NSLog("%@", "Keynod CLI: refused a connection: \(failure)")
            let refusal = CLIResponse.failure("refused: \(failure); only the keynod command of this Keynod build may use this socket")
            if let data = try? JSONEncoder().encode(refusal) { _ = CLIProtocol.writeLine(fd, data) }
            return
        }

        // Then the channel: nothing that doesn't open with the channel key is processed or answered.
        // (The signature check alone can be raced: a process can write its request and then exec
        // the real binary in the same pid.)
        guard let key = channelKey else { return }
        let session: SecureChannel.Session
        let request: CLIRequest
        do {
            session = try SecureChannel.server(fd: fd, key: key)
            request = try JSONDecoder().decode(CLIRequest.self, from: try session.receive())
        } catch {
            NSLog("%@", "Keynod CLI: dropped a connection from process \(peer.pid): \(error)")
            return
        }

        let response: CLIResponse
        if let claimed = request.caller, claimed.pid == peer.pid {
            response = handle(request, caller: CallerInfo(peer: peer, claimed: claimed), connection: fd)
        } else {
            response = .failure("refused: the request's caller doesn't match the connection")
        }
        if let data = try? JSONEncoder().encode(response) { try? session.send(data) }
    }

    private func handle(_ req: CLIRequest, caller: CallerInfo, connection: Int32) -> CLIResponse {
        switch req.op {
        case "list": return list()
        case "create": return create(req, caller: caller)
        case "delete": return delete(req, caller: caller)
        case "read": return read(req, caller: caller)
        case "ask": return question(req, caller: caller, connection: connection)
        default: return .failure("unknown operation \"\(req.op)\"")
        }
    }

    // MARK: Store access (main thread)

    private func secrets() -> [Secret] {
        DispatchQueue.main.sync { Store.shared.secrets }
    }

    /// Releases and deletions name secrets by `vault.json`; they wait until its seal checks (see `VaultSeal`).
    private func vaultTrusted() -> Bool {
        DispatchQueue.main.sync { Store.shared.trusted }
    }

    static let untrustedMessage = "refused: Keynod's list of secrets (vault.json) changed outside the app or has no seal, "
        + "so an approval might name the wrong secret. Open Keynod and choose Keynod \u{203A} Trust Current Vault\u{2026} "
        + "once you've checked the list."

    private func list() -> CLIResponse {
        let iso = ISO8601DateFormatter()
        let items = secrets().map { secret in
            CLISecret(id: secret.id.uuidString, title: secret.title, details: secret.details, tags: secret.tags,
                      updatedAt: iso.string(from: secret.updatedAt), fields: secret.fields.map {
                CLIField(label: $0.label, concealed: $0.concealed, value: $0.concealed ? nil : $0.value, filename: $0.filename)
            })
        }
        return CLIResponse(ok: true, secrets: items)
    }

    // MARK: Creating secrets

    private func create(_ req: CLIRequest, caller: CallerInfo) -> CLIResponse {
        guard caller.complete else { return .failure(CallerInfo.incompleteMessage) }
        let title = (req.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let details = (req.details ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let items = req.fields ?? []
        guard !title.isEmpty else { return .failure("missing title") }
        guard !title.contains("\n") else { return .failure("the title can't contain a line break") }
        for f in items {
            guard !f.label.trimmingCharacters(in: .whitespaces).isEmpty else { return .failure("empty field label") }
            if f.concealed, (f.data?.count ?? 0) > AppModel.maxFileSize {
                return .failure("\(f.label) is larger than 1 MB")
            }
        }

        let existing = secrets()
        if existing.contains(where: { CLIRef.normalize($0.title) == CLIRef.normalize(title) }) {
            return .failure("a secret titled \"\(title)\" already exists; `keynod secret add` never changes existing secrets")
        }
        for f in items where !f.concealed && f.label.lowercased() == "key id" {
            let keyID = (f.value ?? "").trimmingCharacters(in: .whitespaces)
            if let dup = existing.first(where: { secret in
                secret.fields.contains { !$0.concealed && $0.label.lowercased() == "key id"
                    && ($0.value ?? "").trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(keyID) == .orderedSame }
            }) {
                return .failure("Key ID \(keyID) is already stored in \"\(dup.title)\" [\(dup.id.uuidString)]")
            }
        }

        let labels = items.map(\.label).joined(separator: ", ")
        let what = "(\(labels.isEmpty ? "no fields" : labels))"
        let asker = Asker(caller: caller, purpose: "secret add")
        let ask = Self.ask(kind: "create", reason: Self.reason(asker, verb: "create", fields: ["\(title) \(what)"]),
                           asker: asker, summary: "new secret \"\(title)\" \(what)")
        let approval: CLIApproval
        do {
            approval = try approvals.authorize(ask, graceKey: nil)
        } catch {
            return .failure(Self.describe(error, label: nil))
        }
        defer { approval.invalidate() }

        var fields: [SecretField] = []
        var values: [UUID: Data] = [:]
        for f in items {
            if f.concealed {
                let field = SecretField(label: f.label, concealed: true, filename: f.filename)
                fields.append(field)
                values[field.id] = f.data ?? Data()
            } else {
                fields.append(SecretField(label: f.label, value: f.value ?? ""))
            }
        }
        let text = details.isEmpty ? title : title + "\n" + details
        let result: Result<Secret, Error> = DispatchQueue.main.sync {
            Result { try Store.shared.addSecret(title: text, fields: fields, values: values) }
        }
        switch result {
        case .success(let secret): return CLIResponse(ok: true, message: "created \(secret.title) [\(secret.id.uuidString)]")
        case .failure(let error): return .failure("could not create the secret: \(error)")
        }
    }

    // MARK: Deleting secrets

    private static let maxDeletes = 20

    private func delete(_ req: CLIRequest, caller: CallerInfo) -> CLIResponse {
        guard caller.complete else { return .failure(CallerInfo.incompleteMessage) }
        guard vaultTrusted() else { return .failure(Self.untrustedMessage) }
        let names = (req.refs ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return .failure("nothing to delete: name a secret by its id or its full title") }
        guard names.count <= Self.maxDeletes else { return .failure("at most \(Self.maxDeletes) secrets can be deleted in one call") }

        let existing = secrets()
        var targets: [Secret] = []
        for name in names {
            switch SecretLookup.exact(name, in: existing) {
            case .success(let secret): if !targets.contains(where: { $0.id == secret.id }) { targets.append(secret) }
            case .failure(let failure): return .failure(failure.message)
            }
        }

        let titles = targets.map(\.title).joined(separator: ", ")
        let what = targets.count == 1 ? "\"\(titles)\"" : "\(targets.count) secrets: \(titles)"
        // The dialog must name every secret in full; nothing may hide behind a cut.
        guard ApprovalText.fieldsFit([what]) else {
            return .failure("refused: the approval dialog can't name all \(targets.count) secrets in full; "
                + "delete fewer at a time")
        }
        let asker = Asker(caller: caller, purpose: "secret delete")
        let ask = Self.ask(kind: "delete", reason: Self.reason(asker, verb: "permanently delete", fields: [what]),
                           asker: asker, summary: "delete \(what)")
        let approval: CLIApproval
        do {
            approval = try approvals.authorize(ask, graceKey: nil)
        } catch {
            return .failure(Self.describe(error, label: nil))
        }
        defer { approval.invalidate() }

        let deleted: [Secret] = DispatchQueue.main.sync {
            targets.filter { target in
                guard let secret = Store.shared.secret(target.id) else { return false }
                if AppModel.shared.selection == secret.id { AppModel.shared.selection = nil }
                Store.shared.delete(secret.id)
                return true
            }
        }
        guard !deleted.isEmpty else { return .failure("nothing was deleted: the secrets are already gone") }
        let lines = deleted.map { "  \($0.title) [\($0.id.uuidString)]" }.joined(separator: "\n")
        return CLIResponse(ok: true, message: "deleted \(deleted.count) secret\(deleted.count == 1 ? "" : "s"):\n\(lines)")
    }

    // MARK: Questions for the phone

    private final class Answer {
        private let lock = NSLock()
        private let ready = DispatchSemaphore(value: 0)
        private var value: QuestionResult?

        func set(_ result: QuestionResult) {
            lock.withLock { value = result }
            ready.signal()
        }

        func wait(seconds: TimeInterval) -> QuestionResult? {
            guard ready.wait(timeout: .now() + seconds) == .success else { return nil }
            ready.signal()
            return lock.withLock { value }
        }
    }

    private func question(_ req: CLIRequest, caller: CallerInfo, connection: Int32) -> CLIResponse {
        guard let kind = req.kind, Link.questionKinds.contains(kind) else { return .failure("unknown question kind") }
        let link = PhoneLink.shared
        let onlyRemote = req.requireRemote == true
        if onlyRemote && !link.isRemote { return CLIResponse(ok: true, outcome: "skipped") }

        // Question texts (Bash commands, Claude's last message) go to iCloud and a push
        // notification. Invisible characters go first (so none can split a secret), then
        // secrets Key Catcher recognises are replaced, then the text is shortened and signed.
        // Best effort; see SECURITY.md.
        let asker = Asker(caller: caller, purpose: "ask")
        let who = Self.oneLine(asker.who, 80)
        let cwd = Self.oneLine(asker.cwd, 200, keepEnd: true)
        let command = Self.oneLine(Self.redacted(req.command ?? ""), 160)
        let summary = Self.oneLine(Self.redacted(req.summary ?? ""), 400)
        let body = Self.readable(Self.redacted(req.body ?? "", keepLineBreaks: true), limit: 4000)
        let options = (req.options ?? []).prefix(8).map { Self.oneLine(Self.redacted($0), 60) }.filter { !$0.isEmpty }
        let input = ["text", "code"].contains(req.input ?? "") ? req.input : nil
        let timeout = min(max(req.timeout ?? 30 * 60, 5), Link.questionTTL)
        let images = QuestionImages.jpegs(paths: req.images ?? [])

        let answer = Answer()
        let task = Task.detached(priority: .userInitiated) {
            if Task.isCancelled {
                answer.set(.unavailable("withdrawn"))
                return
            }
            answer.set(await link.question(kind: kind, who: who, command: command, cwd: cwd, summary: summary,
                                           body: body.isEmpty ? nil : body, options: options.isEmpty ? nil : options,
                                           input: input, images: images, timeout: timeout))
        }
        var skipped = false
        var result: QuestionResult?
        while result == nil {
            result = answer.wait(seconds: 1)
            if result != nil || task.isCancelled { continue }
            if onlyRemote && !link.isRemote {
                skipped = true
                task.cancel()
            } else if CLIProtocol.peerClosed(connection) {
                task.cancel()
            }
        }

        if skipped { return CLIResponse(ok: true, outcome: "skipped") }
        switch result! {
        case .allowed: return CLIResponse(ok: true, outcome: "allowed")
        case .denied: return CLIResponse(ok: true, outcome: "denied")
        case .answered(let choice, let text): return CLIResponse(ok: true, text: text, outcome: "answered", choice: choice)
        case .timedOut: return CLIResponse(ok: true, outcome: "timedOut")
        case .unavailable(let why): return CLIResponse(ok: true, message: why, outcome: "unavailable")
        }
    }

    /// Text for a phone screen: line breaks and tabs stay, control, invisible and
    /// bidi characters go (`ApprovalText.sanitize`); at most `limit` characters.
    private static func readable(_ text: String, limit: Int) -> String {
        let trimmed = ApprovalText.sanitize(text, keepLineBreaks: true).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "\u{2026}" : trimmed
    }

    /// Sanitized first, then redacted, so a zero-width character can't hide a secret from Key Catcher.
    static func redacted(_ text: String, keepLineBreaks: Bool = false) -> String {
        KeyCatcher.redact(ApprovalText.sanitize(text, keepLineBreaks: keepLineBreaks))
    }

    // MARK: Reading values

    private func read(_ req: CLIRequest, caller: CallerInfo) -> CLIResponse {
        let purpose = req.purpose ?? ""
        guard ["run", "inject", "get"].contains(purpose) else { return .failure("unknown purpose \"\(purpose)\"") }
        let refs = req.refs ?? []
        guard !refs.isEmpty else { return .failure("no references given") }
        guard caller.complete else { return .failure(CallerInfo.incompleteMessage) }
        guard vaultTrusted() else { return .failure(Self.untrustedMessage) }
        // Arguments the dialog would show differently from how they run (invisible or control characters).
        if purpose == "run", !ApprovalText.argumentsDisplayFaithfully(caller.argv) {
            return .failure("refused: an argument of the command contains invisible or control characters, "
                + "so the approval couldn't show it as it would run")
        }
        // What the approval will show must be what the command does.
        if purpose == "run", caller.programIdentity == nil
            || !ApprovalText.runMatches(argv: caller.argv, exec: caller.exec, found: caller.execFound,
                                        cwd: caller.cwd ?? "", realpath: ProcInfo.realPath) {
            return .failure("refused: the program to run doesn't match the command line")
        }
        if purpose == "inject" {
            guard let target = caller.target,
                  ApprovalText.destinationMatches(argv: caller.argv, flag: "--to", target: target, cwd: caller.cwd ?? "",
                                                  home: NSHomeDirectory(), realpath: ProcInfo.realPath) else {
                return .failure("refused: the destination doesn't match the command line")
            }
            guard ApprovalText.pathDisplaysFaithfully(target) else {
                return .failure("refused: the destination path contains invisible or control characters, "
                    + "so the approval couldn't show it as it would be written")
            }
        }

        if purpose == "get" && caller.fromClaude {
            return .failure("refused: called from a Claude session \u{2014} use `keynod run` or `keynod inject`")
        }

        let all = secrets()
        var targets: [(ref: String, secret: Secret, field: SecretField)] = []
        do {
            for ref in refs {
                let hit = try CLIRef.resolve(ref, in: all)
                targets.append((ref, hit.secret, hit.field))
            }
        } catch {
            return .failure("\(error)")
        }

        let concealed = targets.filter { $0.field.concealed }
        var approval: CLIApproval?
        if !concealed.isEmpty {
            let asker = Asker(caller: caller, purpose: purpose)
            var seen = Set<UUID>()
            let unique = concealed.filter { seen.insert($0.field.id).inserted }
            let release = unique.map { (id: $0.field.id, secret: $0.secret.title, label: $0.field.label) }
            let names = unique.map { "\($0.secret.title)/\($0.field.label)" }
            // Every field must show in full in the dialog; nothing may hide behind "+N more".
            guard ApprovalText.fieldsFit(names) else {
                return .failure("refused: the approval dialog can't name all \(names.count) fields in full; "
                    + "split this into several commands with fewer fields each (or shorten long titles)")
            }
            // Arguments (or the inject destination) must show in full too; nothing may hide behind "…".
            guard ApprovalText.commandFits(command: asker.command, who: asker.who, cwd: asker.cwd,
                                           verb: "read", fields: names) else {
                return .failure("refused: the command is too long to show in full in the approval dialog; "
                    + (purpose == "inject" ? "use a shorter destination path" : "shorten its arguments or put them in a script"))
            }
            let ask = Self.ask(kind: purpose,
                               reason: Self.reason(asker, fields: names),
                               asker: asker, summary: Self.summary(of: concealed.map { (secret: $0.secret, field: $0.field) }), fields: release)
            // "get" always prompts fresh. run and inject skip the prompt only for the very same
            // command line, environment, program or destination, directory and anchor (see graceAnchor).
            let key = ApprovalText.graceKey(purpose: purpose, cwd: caller.cwd, fields: concealed.map { $0.field.id.uuidString },
                                            argv: caller.argv, environment: caller.environment,
                                            extra: [caller.exec, caller.execFound, caller.programIdentity, caller.target].compactMap { $0 }, anchor: caller.graceAnchor)
            do {
                approval = try approvals.authorize(ask, graceKey: purpose == "get" ? nil : key)
            } catch {
                return .failure(Self.describe(error, label: nil))
            }
        }

        var values: [CLIValue] = []
        for t in targets {
            let data: Data
            if t.field.concealed {
                do {
                    data = try Self.value(of: t.field, approval: approval)
                } catch {
                    if purpose == "get" { approval?.invalidate() }
                    return .failure(Self.describe(error, label: t.field.label))
                }
            } else {
                data = Data((t.field.value ?? "").utf8)
            }
            values.append(CLIValue(ref: t.ref, label: t.field.label, concealed: t.field.concealed,
                                   filename: t.field.filename, data: data))
        }
        if purpose == "get" { approval?.invalidate() }
        return CLIResponse(ok: true, values: values)
    }

    private static func value(of field: SecretField, approval: CLIApproval?) throws -> Data {
        guard case .phone(let keys)? = approval else {
            var context: LAContext?
            if case .mac(let approved)? = approval { context = approved }
            return try Vault.get(field.id, reason: "read \(field.label)", context: context)
        }
        guard let key = keys[field.id] else { throw LinkError.missingKeys }
        return try PhoneLink.shared.open(field: field.id, key: key)
    }

    private static func summary(of fields: [(secret: Secret, field: SecretField)]) -> String {
        var order: [UUID] = []
        var titles: [UUID: String] = [:]
        var labels: [UUID: [String]] = [:]
        for (secret, field) in fields {
            if titles[secret.id] == nil { order.append(secret.id); titles[secret.id] = secret.title }
            if !labels[secret.id, default: []].contains(field.label) { labels[secret.id, default: []].append(field.label) }
        }
        return order.map { "\(titles[$0] ?? ""): \((labels[$0] ?? []).joined(separator: ", "))" }.joined(separator: "; ")
    }

    private static func describe(_ error: Error, label: String?) -> String {
        if let e = error as? LinkError {
            switch e {
            case .denied: return "denied on iPhone"
            case .expired: return "not approved: the iPhone request expired"
            default: return e.description
            }
        }
        if let e = error as? LAError, [.userCancel, .appCancel, .systemCancel, .authenticationFailed].contains(e.code) {
            return "denied"
        }
        if let e = error as? Vault.Failure {
            if e.status == errSecItemNotFound { return "\(label ?? "field") has no value yet" }
            if e.status == errSecUserCanceled || e.status == errSecAuthFailed { return "denied" }
        }
        return "\(error)"
    }

    private struct Asker {
        let command: CommandText
        let who: String
        let cwd: String

        /// `command` is the whole command line, read from the kernel for the
        /// verified caller, with the program and destination the command
        /// reported (and the app checked); it is shortened only where it is shown.
        init(caller: CallerInfo, purpose: String) {
            let home = NSHomeDirectory()
            command = ApprovalText.command(purpose: purpose, argv: caller.argv, home: home,
                                           exec: caller.exec, target: caller.target)
            who = ApprovalText.who(parents: caller.chain.map(\.display), parentPID: caller.parentPID, fromClaude: caller.fromClaude)
            cwd = ApprovalText.tilde(caller.cwd ?? "", home: home)
        }
    }

    private static func reason(_ asker: Asker, verb: String = "read", fields: [String]) -> String {
        ApprovalText.reason(command: asker.command, who: asker.who, cwd: asker.cwd, verb: verb, fields: fields)
    }

    private static func ask(kind: String, reason: String, asker: Asker, summary: String,
                            fields: [(id: UUID, secret: String, label: String)] = []) -> ApprovalAsk {
        // `fullCommand` and `fullSummary` stay uncut: the iPhone's copy is redacted before it is shortened.
        ApprovalAsk(kind: kind, reason: reason, who: oneLine(asker.who, 80),
                    command: asker.command.render(160),
                    cwd: oneLine(asker.cwd, 200, keepEnd: true), summary: oneLine(summary, 400),
                    fields: fields.map { (id: $0.id, secret: oneLine($0.secret, 80), label: oneLine($0.label, 80)) },
                    fullCommand: asker.command, fullSummary: summary)
    }

    private static func oneLine(_ text: String, _ limit: Int, keepEnd: Bool = false) -> String {
        let line = ApprovalText.flatten(text)
        guard line.count > limit else { return line }
        return keepEnd ? "\u{2026}" + String(line.suffix(limit - 1)) : String(line.prefix(limit - 1)) + "\u{2026}"
    }
}

// MARK: - Approvals

enum CLIApproval {
    case mac(LAContext)
    case phone([UUID: SymmetricKey])

    func invalidate() { if case .mac(let context) = self { context.invalidate() } }
}

final class CLIApprovals {
    static let grace: TimeInterval = 5 * 60

    private let lock = NSLock()
    private let promptLock = NSLock()
    private var grants: [String: (approval: CLIApproval, expires: Date)] = [:]

    init() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: nil
        ) { [weak self] _ in self?.dropAll() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.dropAll() }
    }

    func dropAll() {
        lock.lock(); defer { lock.unlock() }
        grants.values.forEach { $0.approval.invalidate() }
        grants.removeAll()
    }

    private func grant(for key: String) -> CLIApproval? {
        lock.lock(); defer { lock.unlock() }
        guard let g = grants[key] else { return nil }
        if g.expires > Date() { return g.approval }
        g.approval.invalidate()
        grants[key] = nil
        return nil
    }

    func authorize(_ ask: ApprovalAsk, graceKey: String?) throws -> CLIApproval {
        promptLock.lock(); defer { promptLock.unlock() }
        if let graceKey, let approval = grant(for: graceKey) { return approval }

        let link = PhoneLink.shared
        let race = ApprovalRace<CLIApproval>()
        let ctx = LAContext()
        var phone: PhoneAsk?
        var phoneTried = false, macStarted = false
        let dialogGone = Once { VaultSession.setCLIAuthenticating(false) }
        defer { dialogGone.run() }

        func askPhone() {
            phoneTried = true
            phone = link.ask(ask, race: race)
        }
        func startTouchID() {
            macStarted = true
            VaultSession.setCLIAuthenticating(true)
            ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: Self.dialogText(ask.reason, phone: phone != nil)) { ok, error in
                dialogGone.run()
                if ok {
                    race.approve(.mac(ctx), by: .mac)
                } else {
                    let error = error ?? LAError(.authenticationFailed)
                    if let e = error as? LAError, e.code == .userCancel || e.code == .authenticationFailed {
                        race.deny(error, by: .mac)
                    } else {
                        race.stepAside(.mac, because: error)
                    }
                }
            }
        }

        if link.isRemote { askPhone() }
        if phone == nil { startTouchID() }

        var outcome: ApprovalRace<CLIApproval>.Outcome
        while true {
            if let decided = race.wait(timeout: 1) { outcome = decided; break }
            let remote = link.isRemote
            if remote, !phoneTried { askPhone() }
            if !remote, !macStarted { startTouchID() }
            if !macStarted, let reason = race.reason(.phone) {
                if (reason as? LinkError) == .expired { race.stepAside(.mac, because: reason) } else { startTouchID() }
            }
            if phone == nil, macStarted, let reason = race.reason(.mac) {
                race.stepAside(.phone, because: reason)
            }
        }
        phone?.close()

        switch outcome {
        case .approved(let approval, let side):
            if side == .phone { ctx.invalidate() }
            if let graceKey {
                lock.lock()
                grants[graceKey] = (approval, Date().addingTimeInterval(Self.grace))
                lock.unlock()
            }
            return approval
        case .failed(let error, _):
            ctx.invalidate()
            throw error
        }
    }

    private final class Once {
        private let lock = NSLock()
        private var action: (() -> Void)?

        init(_ action: @escaping () -> Void) { self.action = action }

        func run() {
            lock.lock()
            let action = self.action
            self.action = nil
            lock.unlock()
            action?()
        }
    }

    private static func dialogText(_ reason: String, phone: Bool) -> String {
        guard phone else { return reason }
        let hint = " \u{2014} or approve on your iPhone"
        return reason.count + hint.count <= 260 ? reason + hint : String(reason.prefix(260 - hint.count - 1)) + "\u{2026}" + hint
    }
}

// MARK: - Caller identification

struct CallerInfo {
    struct Entry {
        let pid: pid_t
        let start: UInt64?
        let path: String?
        let display: String
        let isClaude: Bool
    }

    static let incompleteMessage = "refused: the calling process can't be identified (it has exited, or its "
        + "arguments or working directory can't be read)"

    let pid: pid_t
    /// From the kernel, for the verified pid.
    let argv: [String]
    let cwd: String?
    /// The client's parent (1 when it was detached and launchd adopted it), and when that parent started.
    let parentPID: pid_t?
    let parentStart: UInt64?
    let chain: [Entry]
    /// From the sealed request (`CLICaller`).
    let environment: String
    let exec: String?
    let execFound: String?
    let programIdentity: String?
    let target: String?
    /// The verified process was still the same one after its details were read.
    let alive: Bool
    var fromClaude: Bool { chain.contains { $0.isClaude } }

    /// Approvals and changes need all of it; without it they fail closed.
    var complete: Bool { alive && !argv.isEmpty && !(cwd ?? "").isEmpty }

    var graceAnchor: String? {
        ApprovalText.graceAnchor(parentPID: parentPID, parentStart: parentStart,
                                 chain: chain.map { (pid: $0.pid, start: $0.start, isClaude: $0.isClaude) })
    }

    /// Built right after the request is opened, then the peer is checked to be
    /// the same process still, so these details can't belong to a successor.
    init(peer: PeerIdentity.Peer, claimed: CLICaller) {
        pid = peer.pid
        argv = ProcInfo.argv(pid)
        cwd = ProcInfo.cwd(of: pid)
        parentPID = ProcInfo.parent(of: pid)
        parentStart = parentPID.flatMap { ProcInfo.startTime(of: $0) }
        var entries: [Entry] = []
        var current = parentPID
        while let p = current, p > 1, entries.count < 32 {
            let path = ProcInfo.path(of: p)
            let args = ProcInfo.argv(p)
            let name = path.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? args.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?"
            let claude = ClaudeProcess.matches(name: name, path: path, argv: args)
            entries.append(Entry(pid: p, start: ProcInfo.startTime(of: p), path: path,
                                 display: claude ? "claude" : name, isClaude: claude))
            current = ProcInfo.parent(of: p)
        }
        chain = entries
        environment = claimed.environment
        exec = claimed.exec
        execFound = claimed.execFound
        programIdentity = claimed.programIdentity
        target = claimed.target
        alive = PeerIdentity.isAlive(peer)
    }
}

enum ProcInfo {
    static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return n > 0 ? String(cString: buffer) : nil
    }

    static func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    static func realPath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard realpath(path, &buffer) != nil else { return nil }
        return String(cString: buffer)
    }

    /// When the process started, in microseconds since 1970 (tells a recycled pid apart).
    static func startTime(of pid: pid_t) -> UInt64? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec)
    }

    static func argv(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = Int(buffer[0]) | Int(buffer[1]) << 8 | Int(buffer[2]) << 16 | Int(buffer[3]) << 24
        var i = 4
        while i < size, buffer[i] != 0 { i += 1 }
        while i < size, buffer[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}
