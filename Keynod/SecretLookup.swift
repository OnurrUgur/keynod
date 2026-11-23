import Foundation

/// Finds the secret a destructive command names. Stricter than `CLIRef.findSecret`:
/// only the full id or the whole title counts, never a part of a title.
enum SecretLookup {
    struct Failure: Error, Equatable {
        let message: String
    }

    /// Dashes unified, whitespace collapsed, lowercased.
    static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .lowercased()
    }

    static func exact(_ query: String, in secrets: [Secret]) -> Result<Secret, Failure> {
        let q = normalize(query)
        guard !q.isEmpty else { return .failure(Failure(message: "empty secret name")) }
        if let hit = secrets.first(where: { $0.id.uuidString.lowercased() == q }) { return .success(hit) }
        let hits = secrets.filter { normalize($0.title) == q }
        if hits.count == 1 { return .success(hits[0]) }
        if hits.count > 1 {
            let ids = hits.map { "  \($0.title) [\($0.id.uuidString)]" }.joined(separator: "\n")
            return .failure(Failure(message: "\(hits.count) secrets are titled \"\(query)\"; use the id:\n\(ids)"))
        }
        let near = secrets.filter { normalize($0.title).contains(q) }.prefix(5)
        var message = "no secret has the id or the full title \"\(query)\""
        if !near.isEmpty {
            message += "; did you mean:\n" + near.map { "  \($0.title) [\($0.id.uuidString)]" }.joined(separator: "\n")
        }
        return .failure(Failure(message: message))
    }
}
