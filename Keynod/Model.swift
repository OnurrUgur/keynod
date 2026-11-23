import Foundation

/// One labelled value inside a secret. Concealed values never live here:
/// they are stored in the Keychain-backed Vault keyed by `id`, and `value` stays nil.
struct SecretField: Identifiable, Codable, Equatable {
    var id = UUID()
    var label: String
    var concealed: Bool
    /// Plain text, only for non-concealed fields (readable by scripts).
    var value: String?
    /// Set when the value is a file (e.g. AuthKey_ABC.p8).
    var filename: String?
    /// Non-secret flag: false while a concealed field has never been given a
    /// value. nil (older files) means it has one.
    var hasValue: Bool?

    /// True when there is something stored for this field.
    var isSet: Bool { hasValue ?? true }

    init(label: String, concealed: Bool = false, value: String? = nil, filename: String? = nil, hasValue: Bool? = nil) {
        self.hasValue = hasValue
        self.label = label
        self.concealed = concealed
        self.value = concealed ? nil : value
        self.filename = filename
    }

    // Encoding drops `value` for concealed fields, so a secret can't leak into
    // vault.json even if one were set by mistake.
    enum CodingKeys: String, CodingKey { case id, label, concealed, value, filename, hasValue }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(concealed, forKey: .concealed)
        if !concealed { try c.encodeIfPresent(value, forKey: .value) }
        try c.encodeIfPresent(filename, forKey: .filename)
        try c.encodeIfPresent(hasValue, forKey: .hasValue)
    }
}

/// A vault entry: title, optional description (with `#tags`), and labelled fields.
struct Secret: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    let createdAt: Date
    var updatedAt: Date
    var fields: [SecretField] = []

    init(title: String, fields: [SecretField] = [], createdAt: Date = Date()) {
        id = UUID()
        self.text = title
        self.createdAt = createdAt
        updatedAt = createdAt
        self.fields = fields
    }

    fileprivate var lines: [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var title: String { lines.first ?? "Untitled" }
    var preview: String { lines.dropFirst().first ?? "" }
    /// Everything after the title line (the secret's description).
    var details: String { lines.dropFirst().joined(separator: "\n") }
    /// `#word` tokens from the text: lowercased, unique, in order. Derived, never stored.
    var tags: [String] { Tags.parse(text) }

    /// True when the secret is still an untouched template with no values entered.
    var isBlank: Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let untouched = fields.allSatisfy { f in f.concealed ? !f.isSet : (f.value ?? "").isEmpty }
        return untouched && (t.isEmpty || SecretTemplate.isDefaultTitle(t))
    }
}

enum Tags {
    private static let regex = try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_])#([\\p{L}\\p{N}_-]+)")

    static func parse(_ text: String) -> [String] {
        let ns = text as NSString
        var seen = Set<String>()
        var result: [String] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range(at: 1)).lowercased()
            if seen.insert(tag).inserted { result.append(tag) }
        }
        return result
    }
}

extension Secret {
    /// Website host (lowercased, no scheme or www) and username of a login
    /// secret, or nil when either is empty.
    var loginIdentity: (host: String, user: String)? {
        func plain(_ label: String) -> String {
            (fields.first { !$0.concealed && $0.label.lowercased() == label }?.value ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var site = plain("website")
        let user = plain("username").lowercased()
        guard !site.isEmpty, !user.isEmpty else { return nil }
        if !site.contains("://") { site = "https://" + site }
        guard var host = URLComponents(string: site)?.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return (host, user)
    }
}

/// Case- and diacritic-insensitive search folding.
enum SearchFold {
    static func fold(_ text: String) -> String {
        text.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: "\u{0131}", with: "i")
    }

    /// True when every word of `query` is somewhere in `text`.
    static func matches(_ text: String, query: String) -> Bool {
        let words = fold(query).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return false }
        let haystack = fold(text)
        return words.allSatisfy { haystack.contains($0) }
    }
}

extension Secret {
    /// What search looks at: the text (title, description and its #tags) and the values of plain fields.
    /// Concealed values live in the Vault; even one that slipped into a field here is left out.
    var searchableText: String {
        ([text] + fields.compactMap { $0.concealed ? nil : $0.value }).joined(separator: "\n")
    }

    /// Every word of `query` is in the searchable text, ignoring case and diacritics.
    func matches(_ query: String) -> Bool {
        SearchFold.matches(searchableText, query: query)
    }

    /// The secrets that match `query`, in order; all of them when it is blank.
    static func filter(_ secrets: [Secret], query: String) -> [Secret] {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? secrets : secrets.filter { $0.matches(query) }
    }
}

func shortDate(_ date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date) { return date.formatted(.dateTime.hour().minute()) }
    if cal.isDateInYesterday(date) { return "Yesterday" }
    if cal.isDate(date, equalTo: Date(), toGranularity: .year) {
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
    return date.formatted(.dateTime.day().month(.abbreviated).year())
}

/// Starting points offered by the "+" in the vault.
enum SecretTemplate: CaseIterable, Identifiable {
    case apiKey, login, blank

    var id: Self { self }

    var menuLabel: String {
        switch self {
        case .apiKey: "API Key"
        case .login: "Login"
        case .blank: "Blank Secret"
        }
    }

    var symbol: String {
        switch self {
        case .apiKey: "key"
        case .login: "person.crop.circle"
        case .blank: "square.dashed"
        }
    }

    var title: String {
        switch self {
        case .apiKey: "New API Key"
        case .login: "New Login"
        case .blank: "New Secret"
        }
    }

    static func isDefaultTitle(_ title: String) -> Bool {
        allCases.contains { $0.title == title }
    }

    func makeFields() -> [SecretField] {
        switch self {
        case .apiKey:
            [SecretField(label: "Key", concealed: true, hasValue: false)]
        case .login:
            [SecretField(label: "Website", value: ""),
             SecretField(label: "Username", value: ""),
             SecretField(label: "Password", concealed: true, hasValue: false)]
        case .blank:
            []
        }
    }
}
