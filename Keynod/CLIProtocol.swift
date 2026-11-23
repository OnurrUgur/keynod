import Darwin
import Foundation

/// Wire format between the `keynod` command (client) and the running app (server).
/// Over the Unix socket `<data dir>/keynod.sock`, after a channel hello: one request and one response,
/// each JSON sealed into one line by `SecureChannel`.
/// The app checks who is calling itself: the peer's code signature and audit token, then the sealed
/// request's `caller` block, whose pid must be the peer's; arguments, directory and parents come from the kernel.
struct CLIRequest: Codable {
    /// "list", "read", "create", "delete" or "ask".
    var op: String
    /// The command's working directory. Not used by the app, which reads it from the kernel.
    var cwd: String?
    /// For "read": "run", "inject" or "get".
    var purpose: String?
    /// For "read": `<secret>/<field label>` references. For "delete": the secrets to delete,
    /// each by its id or its full title.
    var refs: [String]?
    /// For "create": the new secret's title, description and fields.
    var title: String?
    var details: String?
    var fields: [CLIField]?
    /// For "ask": one of `Link.questionKinds`.
    var kind: String?
    /// For "ask": the short headline ("Permission: Bash") and what it is about.
    var command: String?
    var summary: String?
    /// For "ask": the text to read on the phone.
    var body: String?
    /// For "ask": the buttons the phone offers.
    var options: [String]?
    /// For "ask": "text" if the phone may answer in words, "code" for a one-time code.
    var input: String?
    /// For "ask": image files (absolute paths) to show under the message. The app shrinks them to JPEG.
    var images: [String]?
    /// For "ask": seconds to wait for the phone.
    var timeout: Double?
    /// For "ask": only ask while remote mode is on; otherwise answer "skipped" at once.
    var requireRemote: Bool?
    /// Filled in by the command itself (see `CLICaller`). Only ever sent sealed.
    var caller: CLICaller?
}

/// What the command says about itself, inside the sealed request. The app
/// checks `pid` against the connection's audit token and reads arguments,
/// directory and parents for it from the kernel; the rest is what only the
/// command knows.
struct CLICaller: Codable {
    var pid: Int32
    /// `ApprovalText.environmentDigest` of the command's environment.
    var environment: String
    /// For "run": the real file (symlinks resolved) it will execute.
    var exec: String?
    /// For "run": the path the PATH lookup found, when it differs from `exec` (a symlink).
    var execFound: String?
    /// For "run": device, inode, size and modification time of `exec`, checked again just before it runs.
    var programIdentity: String?
    /// For "inject": the file it will write, as `ApprovalText.destination` resolves it.
    var target: String?

    static func current(exec: String? = nil, execFound: String? = nil, programIdentity: String? = nil,
                        target: String? = nil) -> CLICaller {
        CLICaller(pid: getpid(), environment: ApprovalText.environmentDigest(ProcessInfo.processInfo.environment),
                  exec: exec, execFound: execFound, programIdentity: programIdentity, target: target)
    }
}

struct CLIField: Codable {
    var label: String
    var concealed: Bool
    /// Only for plain fields.
    var value: String?
    var filename: String?
    /// Only in "create" requests, for concealed fields: the value to store.
    var data: Data?
}

struct CLISecret: Codable {
    var id: String
    var title: String
    /// Description: the lines after the title.
    var details: String
    var tags: [String]
    /// ISO8601.
    var updatedAt: String
    var fields: [CLIField]
}

/// `keynod list <query...>`: every word must match (case/diacritic-insensitive)
/// the title, description, tags, field labels or plain values; `#tag` words
/// match a tag exactly. Concealed values are never part of a CLISecret.
enum CLIFilter {
    static func matches(_ s: CLISecret, words: [String]) -> Bool {
        words.allSatisfy { word in
            if word.hasPrefix("#"), word.count > 1 { return s.tags.contains(word.dropFirst().lowercased()) }
            var haystack = [s.title, s.details] + s.tags
            haystack += s.fields.map(\.label)
            haystack += s.fields.compactMap { $0.concealed ? nil : $0.value }
            return haystack.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}

struct CLIValue: Codable {
    var ref: String
    var label: String
    var concealed: Bool
    var filename: String?
    var data: Data
}

struct CLIResponse: Codable {
    var ok: Bool
    var error: String?
    var message: String?
    var secrets: [CLISecret]?
    /// Same order as the request's refs.
    var values: [CLIValue]?
    /// For "ask": the words or code the phone sent.
    var text: String?
    /// For "ask": "allowed", "denied", "answered", "timedOut", "skipped" or "unavailable".
    var outcome: String?
    /// For "ask": the option the phone picked; the words or code are in `text`.
    var choice: String?

    static func failure(_ error: String) -> CLIResponse { CLIResponse(ok: false, error: error) }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum CLIProtocol {
    static var socketPath: String { Store.dataDir.appendingPathComponent("keynod.sock").path }

    static func makeAddress(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    static func connect(to path: String) -> Int32? {
        guard var addr = makeAddress(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 { close(fd); return nil }
        return fd
    }

    enum Connection {
        /// Connected to this Keynod build; nothing has been sent yet.
        case server(Int32)
        /// Nobody is listening (no socket, or a stale file).
        case none
        /// Something listens on the path but is not this Keynod build. Already closed; never send to it.
        case foreign(PeerIdentity.Failure)
    }

    /// Connects and checks, before anything is sent, that the listener is this
    /// Keynod build (see `PeerIdentity`). A stand-in on the socket path is never
    /// mistaken for a running Keynod.
    static func connectVerified(to path: String) -> Connection {
        guard let fd = connect(to: path) else { return .none }
        switch PeerIdentity.verify(fd) {
        case .success: return .server(fd)
        case .failure(let failure):
            close(fd)
            return .foreign(failure)
        }
    }

    /// The command's side of one request over a verified connection: channel
    /// handshake, the request sealed (with `caller` filled in when missing), the
    /// response opened. Nothing goes out in plain text, and an answer that
    /// doesn't open is never used.
    static func exchange(_ fd: Int32, _ request: CLIRequest) throws -> CLIResponse {
        var request = request
        if request.caller == nil { request.caller = .current() }
        let session = try SecureChannel.client(fd: fd, key: try ChannelKey.load())
        try session.send(try JSONEncoder().encode(request))
        return try JSONDecoder().decode(CLIResponse.self, from: try session.receive())
    }

    /// True once the other end has closed the connection (the client was killed,
    /// e.g. a hook that timed out).
    static func peerClosed(_ fd: Int32) -> Bool {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, 0) > 0 else { return false }
        if poller.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return true }
        var byte: UInt8 = 0
        let n = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if n == 0 { return true }
        return n < 0 && errno != EAGAIN && errno != EINTR
    }


    static func writeLine(_ fd: Int32, _ payload: Data) -> Bool {
        var out = payload
        out.append(0x0A)
        return out.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }
}

/// Turns `"<secret>/<field label>"` into a secret and one of its fields.
enum CLIRef {
    static func normalize(_ s: String) -> String { SecretLookup.normalize(s) }

    static func resolve(_ ref: String, in secrets: [Secret]) throws -> (secret: Secret, field: SecretField) {
        let slashes = ref.indices.filter { ref[$0] == "/" }
        guard !slashes.isEmpty else {
            throw CLIError("bad reference \"\(ref)\": expected \"<secret>/<field>\"")
        }
        // Titles and labels may themselves contain "/": try the last slash first.
        var firstError: Error?
        for slash in slashes.reversed() {
            let secretPart = String(ref[..<slash])
            let fieldPart = String(ref[ref.index(after: slash)...])
            do {
                let secret = try findSecret(secretPart, in: secrets)
                return (secret, try findField(fieldPart, in: secret))
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        throw firstError!
    }

    static func findSecret(_ query: String, in secrets: [Secret]) throws -> Secret {
        let q = normalize(query)
        guard !q.isEmpty else { throw CLIError("empty secret name in reference") }
        if let hit = secrets.first(where: { $0.id.uuidString.lowercased() == q }) { return hit }
        let exact = secrets.filter { normalize($0.title) == q }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { throw ambiguous(query, exact) }
        let partial = secrets.filter { normalize($0.title).contains(q) }
        if partial.count == 1 { return partial[0] }
        if partial.count > 1 { throw ambiguous(query, partial) }
        throw CLIError("no secret matches \"\(query)\"")
    }

    static func findField(_ label: String, in secret: Secret) throws -> SecretField {
        let q = normalize(label)
        let hits = secret.fields.filter { normalize($0.label) == q }
        if hits.count == 1 { return hits[0] }
        if hits.count > 1 { throw CLIError("\"\(label)\" matches \(hits.count) fields in \"\(secret.title)\"") }
        let labels = secret.fields.map(\.label).joined(separator: ", ")
        throw CLIError("\"\(secret.title)\" has no field \"\(label)\" (fields: \(labels.isEmpty ? "none" : labels))")
    }

    private static func ambiguous(_ query: String, _ secrets: [Secret]) -> CLIError {
        let lines = secrets.map { s in
            "  \(s.title) [\(s.id.uuidString)]" + (s.preview.isEmpty ? "" : " \u{2014} \(s.preview)")
        }.joined(separator: "\n")
        return CLIError("\"\(query)\" is ambiguous; matches:\n\(lines)\nUse the id instead, e.g. \"\(secrets[0].id.uuidString)/<field>\"")
    }
}
