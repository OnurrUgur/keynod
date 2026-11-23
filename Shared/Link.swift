import Foundation

/// The Mac ↔ iPhone approval link. The Mac app, the iPhone app, and the unit
/// tests all compile this folder.
///
/// The Mac writes a signed request to the user's private CloudKit database and
/// the iPhone answers with a signed decision. Secret values never travel: an
/// approval only carries per-field keys, sealed to a one-time key that lives in
/// the waiting Mac process.
enum Link {
    /// CloudKit container identifier read from Info.plist (`KeynodCloudContainer`).
    /// Empty or unset disables iCloud gracefully so local-only Mac builds work without a Team ID.
    static var containerID: String? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "KeynodCloudContainer") as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }

    static let zoneName = "keynod"
    static let version = 1
    /// How long the iPhone can answer a secret approval request.
    static let requestTTL: TimeInterval = 10 * 60
    /// Questions (a reply to Claude, a decision, a code) may wait longer.
    static let questionTTL: TimeInterval = 60 * 60
    static let questionKinds: Set<String> = ["permission", "reply", "decide", "code"]
    /// The longest a request of this kind may stay open; the phone refuses longer ones.
    static func maxLifetime(kind: String) -> TimeInterval {
        questionKinds.contains(kind) ? questionTTL : requestTTL
    }
    /// How long a command from the phone stays valid.
    static let commandTTL: TimeInterval = 10 * 60
    /// How long a pairing code stays valid.
    static let pairingTTL: TimeInterval = 10 * 60
    /// How often a waiting side looks at iCloud.
    static let pollInterval: TimeInterval = 2
    /// Clock difference tolerated between the Mac and the iPhone.
    static let clockSkew: TimeInterval = 2 * 60
    /// Text in the pairing QR code starts with this.
    static let pairingPrefix = "keynod-pair:"

    enum RecordType {
        static let request = "KeynodRequest"
        static let response = "KeynodResponse"
        static let pairing = "KeynodPairing"
        static let pairingAck = "KeynodPairingAck"
        static let mode = "KeynodMode"
        static let command = "KeynodCommand"
        static let awake = "KeynodAwake"
    }

    /// CloudKit field names.
    enum Field {
        /// The exact bytes that were signed (JSON).
        static let payload = "payload"
        /// Raw P-256 ECDSA signature over `payload`.
        static let signature = "sig"
        /// HMAC over `payload` (pairing replies only).
        static let mac = "mac"
        /// Push text of a request. Unsigned copies of the signed payload; the
        /// iPhone app shows the signed version once it has checked it.
        static let title = "title"
        static let subtitle = "subtitle"
        static let body = "body"
        static let expires = "expires"
        /// A question's pictures (CKAsset JPEGs), "img0"..."img3". Each is bound to the
        /// signed payload by its SHA-256 (`LinkRequest.imageHashes`).
        static func image(_ n: Int) -> String { "img\(n)" }
    }

    /// At most this many pictures travel with one question.
    static let maxImages = 4

    static func requestName(_ id: UUID) -> String { "req-" + id.uuidString }
    static func responseName(_ id: UUID) -> String { "resp-" + id.uuidString }
    static func pairingName(_ id: UUID) -> String { "pair-" + id.uuidString }
    static func pairingAckName(_ id: UUID) -> String { "pairack-" + id.uuidString }
    /// The one remote-mode record; whoever changes the mode overwrites it.
    static let modeName = "mode"
    /// The one stay-awake record; the Mac overwrites it whenever its state changes.
    static let awakeName = "awake"
    static func commandName(_ id: UUID) -> String { "cmd-" + id.uuidString }

    /// Request id from a record name, nil for other records.
    static func requestID(fromName name: String) -> UUID? {
        name.hasPrefix("req-") ? UUID(uuidString: String(name.dropFirst(4))) : nil
    }
}

// MARK: - Messages

/// One approval request, as the Mac signs it.
struct LinkRequest: Codable, Equatable {
    /// A concealed field the approval releases.
    struct Item: Codable, Equatable {
        var field: UUID
        /// Secret title and field label, for display.
        var secret: String
        var label: String
        /// Public half of the field's protection key (x963). The phone derives
        /// the field key from it with its own field key (Face ID).
        var eph: Data
    }

    var v = Link.version
    var id: UUID
    var macName: String
    var created: Date
    var expires: Date
    /// "run", "inject", "get", "create", "delete", "permission", "reply", "decide" or "code".
    var kind: String
    /// Who asked, e.g. "claude ← zsh".
    var who: String
    /// e.g. "keynod run -- fastlane beta".
    var command: String
    /// Working directory, home shortened to "~".
    var cwd: String
    /// What the approval opens, e.g. "App Store Connect: Private Key, Issuer ID".
    var summary: String
    /// Empty for create, delete, and questions, which release no keys.
    var items: [Item]
    /// One-time key agreement public key (x963). Field keys in the answer are
    /// sealed to it; its private half exists only in the waiting Mac process.
    var reply: Data
    /// Questions only: the text to read on the phone, e.g. Claude's last message.
    var body: String? = nil
    /// "decide" / "reply": the answers the phone offers as buttons.
    var options: [String]? = nil
    /// "text" when the phone may answer in its own words, "code" for a one-time code.
    var input: String? = nil
    /// Questions only: lowercase hex SHA-256 of each attached picture (JPEG), in order.
    var imageHashes: [String]? = nil

    /// Questions wait for an answer in words or a choice; approvals open secrets.
    var isQuestion: Bool { Link.questionKinds.contains(kind) }

    var pushTitle: String { who }
    var pushSubtitle: String { cwd }
    var pushBody: String { "\(command) \u{00B7} \(summary)" }
}

/// A remote command from the iPhone to the Mac ("lock", "sleep", "awake-on", "awake-off").
/// Signed by the phone; the Mac runs each id once and only while it is fresh.
struct LinkCommand: Codable, Equatable {
    var v = Link.version
    var id: UUID
    var action: String
    var at: Date
}

/// The iPhone's answer to one request.
struct LinkResponse: Codable, Equatable {
    /// `answer` replies to a question with a choice or text.
    enum Decision: String, Codable { case approve, deny, answer }

    /// One field key, sealed to the request's one-time key.
    struct Key: Codable, Equatable {
        var field: UUID
        var eph: Data
        var box: Data
    }

    var v = Link.version
    var request: UUID
    /// SHA-256 of the exact request payload the phone checked.
    var requestHash: Data
    var decision: Decision
    var at: Date
    /// Approvals only: one per request item.
    var keys: [Key]
    /// Answers only: the option picked.
    var choice: String? = nil
    /// Answers only: free text or a code, sealed to the request's one-time key
    /// (it may be a secret, and iCloud must not read it).
    var text: LinkCrypto.Protected? = nil
}

/// What the pairing QR code carries (Mac → iPhone, shown on screen).
struct PairOffer: Codable, Equatable {
    var v = Link.version
    var id: UUID
    var macName: String
    /// The Mac's signing public key (x963).
    var macKey: Data
    /// Proves that the reply comes from the device that scanned the code.
    var secret: Data
    var expires: Date

    var qrText: String { Link.pairingPrefix + LinkCoding.base64URL((try? LinkCoding.encode(self)) ?? Data()) }

    init(id: UUID = UUID(), macName: String, macKey: Data, secret: Data, expires: Date) {
        self.id = id
        self.macName = macName
        self.macKey = macKey
        self.secret = secret
        self.expires = expires
    }

    /// Parses the QR text (spaces and line breaks are ignored).
    init(qrText: String) throws {
        let text = qrText.filter { !$0.isWhitespace }
        guard text.hasPrefix(Link.pairingPrefix),
              let data = LinkCoding.fromBase64URL(String(text.dropFirst(Link.pairingPrefix.count))) else {
            throw LinkError.malformed("not a Keynod pairing code")
        }
        self = try LinkCoding.decode(PairOffer.self, from: data)
        guard v == Link.version else { throw LinkError.wrongVersion }
        guard secret.count == 32, macKey.count == 65 else { throw LinkError.malformed("pairing code is damaged") }
    }
}

/// The iPhone's public keys, sent back through iCloud after the scan.
struct PairReply: Codable, Equatable {
    var v = Link.version
    var pairing: UUID
    var phoneName: String
    /// Signs approvals. Secure Enclave, Face ID.
    var approveKey: Data
    /// Derives field keys. Secure Enclave, Face ID.
    var fieldKey: Data
    /// Signs denials. Secure Enclave, no Face ID (quick reject from a notification).
    var denyKey: Data
}

/// The Mac's final word on a pairing, signed with its key from the QR code.
struct PairAck: Codable, Equatable {
    var v = Link.version
    var pairing: UUID
    var accepted: Bool
    /// SHA-256 of the reply payload the Mac accepted. The phone takes an
    /// acceptance only if it matches its own reply, so the Mac can't silently
    /// have paired with a different (swapped) reply that shows the same code.
    var reply: Data?
}

/// What the Mac keeps about its paired iPhone.
struct PairedPhone: Codable, Equatable {
    var name: String
    var approveKey: Data
    var fieldKey: Data
    var denyKey: Data
    var pairedAt: Date

    init(reply: PairReply, pairedAt: Date = Date()) {
        name = reply.phoneName
        approveKey = reply.approveKey
        fieldKey = reply.fieldKey
        denyKey = reply.denyKey
        self.pairedAt = pairedAt
    }
}

/// Remote mode: on, the Mac sends requests only to the iPhone; off, only Touch ID
/// on the Mac asks. Either device may change it; the newest signed change wins.
struct LinkMode: Codable, Equatable {
    var v = Link.version
    var remote: Bool
    var at: Date
    /// "mac" or "phone", for display.
    var by: String
}

/// Whether the Mac is being kept awake overnight, as the Mac reports it to the
/// iPhone. Signed by the Mac only; the phone shows it and trusts it for nothing else.
struct LinkAwake: Codable, Equatable {
    var v = Link.version
    /// When the Mac may sleep again; nil while stay-awake is off.
    var until: Date?
    /// When the Mac wrote this.
    var at: Date

    /// "09:00" style clock time.
    static func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute())
    }

    /// The time the Mac stays awake until; nil when it is off or that time has passed.
    func activeUntil(now: Date = Date()) -> Date? {
        guard let until, until > now else { return nil }
        return until
    }
}

/// What the iPhone keeps about its paired Mac.
struct PairedMac: Codable, Equatable {
    var name: String
    var macKey: Data
    var pairedAt: Date
}

// MARK: - Encoding

enum LinkCoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw LinkError.malformed("unreadable \(type)")
        }
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func fromBase64URL(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

enum LinkError: Error, Equatable, CustomStringConvertible {
    case badSignature
    case expired
    case wrongRequest
    case wrongVersion
    case badKey
    case missingKeys
    case denied
    /// The request names pictures that weren't handed over (fetch them and check again).
    case missingImages
    case malformed(String)

    var description: String {
        switch self {
        case .badSignature: "the signature doesn't match the paired device"
        case .expired: "the request has expired"
        case .wrongRequest: "the answer belongs to another request"
        case .wrongVersion: "the other device runs an incompatible Keynod version"
        case .badKey: "a key could not be read"
        case .missingKeys: "the answer doesn't cover exactly the requested fields"
        case .denied: "denied on iPhone"
        case .missingImages: "the request's pictures are missing"
        case .malformed(let what): what
        }
    }
}

// MARK: - Cleanup

/// Which leftover records to delete. Requests and pairings normally delete
/// their records when they close; these are the ones an interrupted run (quit,
/// crash, shutdown mid-request) left behind.
enum LinkCleanup {
    struct Item {
        var name: String
        /// A request's signed-for expiry (its `expires` field).
        var expires: Date?
        /// When iCloud first stored the record.
        var created: Date?
    }

    /// Slack for clock differences and for answers that are still being picked up.
    static let grace: TimeInterval = 60

    /// Names of records to delete. Never the mode record; never a request that
    /// can still be answered (a waiting request is unexpired by definition) or
    /// an answer to one.
    static func stale(_ items: [Item], now: Date = Date()) -> [String] {
        func requestIsOver(_ item: Item) -> Bool {
            guard let end = item.expires ?? item.created.map({ $0.addingTimeInterval(Link.requestTTL) }) else { return false }
            return end.addingTimeInterval(grace) < now
        }
        let requests = Dictionary(items.filter { $0.name.hasPrefix("req-") }.map { ($0.name, $0) },
                                  uniquingKeysWith: { first, _ in first })
        return items.compactMap { item in
            let name = item.name
            if name.hasPrefix("req-") {
                return requestIsOver(item) ? name : nil
            }
            if name.hasPrefix("resp-") {
                if let request = requests["req-" + name.dropFirst(5)], !requestIsOver(request) { return nil }
                guard let created = item.created else { return name }
                return created.addingTimeInterval(grace) < now ? name : nil
            }
            if name.hasPrefix("cmd-") {
                guard let created = item.created else { return nil }
                return created.addingTimeInterval(Link.commandTTL + grace) < now ? name : nil
            }
            if name.hasPrefix("pair-") || name.hasPrefix("pairack-") {
                guard let created = item.created else { return nil }
                return created.addingTimeInterval(Link.pairingTTL + grace) < now ? name : nil
            }
            return nil
        }
    }
}
