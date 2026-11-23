import Foundation

/// A question sent to the iPhone that is still open.
struct PendingQuestion: Identifiable, Equatable {
    let id: UUID
    /// permission / reply / decide / code
    let kind: String
    let who: String
    let command: String
    let cwd: String
    let summary: String
    let body: String?
    let options: [String]?
    let input: String?
    let askedAt: Date
    let expires: Date
}

/// A question that has ended. Holds the outcome in a few words, never the answer's text.
struct FinishedQuestion: Identifiable, Equatable {
    let id: UUID
    let kind: String
    let who: String
    let summary: String
    let outcome: String
    let byMac: Bool
    let at: Date
}

/// Tracks questions currently waiting on the iPhone so the Mac menu bar can display
/// a badge and optionally answer them locally too.
final class PendingQuestions: ObservableObject {
    static let shared = PendingQuestions()
    static let finishedLimit = 20

    @Published private(set) var pending: [PendingQuestion] = []
    @Published private(set) var finished: [FinishedQuestion] = []

    private let lock = NSLock()
    private var queue: [PendingQuestion] = []
    private var history: [FinishedQuestion] = []
    private var local: [UUID: QuestionResult] = [:]

    @discardableResult
    func answer(_ id: UUID, with result: QuestionResult) -> Bool {
        lock.withLock {
            guard let question = queue.first(where: { $0.id == id }), local[id] == nil,
                  Self.fits(result, question.kind) else { return false }
            local[id] = result
            return true
        }
    }

    private static func fits(_ result: QuestionResult, _ kind: String) -> Bool {
        switch result {
        case .allowed, .denied:
            return kind == "permission"
        case .answered(let choice, let text):
            func filled(_ value: String?) -> Bool { !(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return kind != "permission" && (filled(choice) || filled(text))
        case .timedOut, .unavailable:
            return false
        }
    }

    func register(_ request: LinkRequest) {
        let q = PendingQuestion(id: request.id, kind: request.kind, who: request.who, command: request.command,
                                cwd: request.cwd, summary: request.summary, body: request.body,
                                options: request.options, input: request.input,
                                askedAt: request.created, expires: request.expires)
        lock.withLock {
            queue.removeAll { $0.id == q.id }
            queue.insert(q, at: queue.firstIndex { $0.askedAt > q.askedAt } ?? queue.endIndex)
        }
        publish()
    }

    func takeLocalAnswer(_ id: UUID) -> QuestionResult? {
        lock.withLock { local.removeValue(forKey: id) }
    }

    func finish(_ id: UUID, result: QuestionResult, byMac: Bool) {
        let ended = lock.withLock { () -> Bool in
            local[id] = nil
            guard let i = queue.firstIndex(where: { $0.id == id }) else { return false }
            let question = queue.remove(at: i)
            history.insert(FinishedQuestion(id: id, kind: question.kind, who: question.who, summary: question.summary,
                                            outcome: Self.outcome(of: result), byMac: byMac, at: Date()), at: 0)
            if history.count > Self.finishedLimit { history.removeLast(history.count - Self.finishedLimit) }
            return true
        }
        if ended { publish() }
    }

    static func outcome(of result: QuestionResult) -> String {
        switch result {
        case .allowed: return "Allowed"
        case .denied: return "Denied"
        case .answered(let choice, _):
            let choice = (choice ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return choice.isEmpty ? "Answered" : "Answered: " + String(choice.prefix(80))
        case .timedOut: return "Timed out"
        case .unavailable: return "Withdrawn"
        }
    }

    private func publish() {
        if Thread.isMainThread {
            copyState()
        } else {
            DispatchQueue.main.async { [self] in copyState() }
        }
    }

    private func copyState() {
        let (open, done) = lock.withLock { (queue, history) }
        if pending != open { pending = open }
        if finished != done { finished = done }
    }
}
