import Foundation

/// One request, two ways to answer it: Touch ID on the Mac and Face ID on the
/// iPhone. The first decision wins and later ones are ignored. A side that
/// can no longer decide (no paired phone, screen locked, request expired)
/// steps aside; once both have, the request fails with the last reason.
final class ApprovalRace<Grant> {
    enum Side: Hashable { case mac, phone }

    enum Outcome {
        case approved(Grant, by: Side)
        case failed(Error, by: Side)
    }

    private let lock = NSLock()
    private let decided = DispatchSemaphore(value: 0)
    private var outcome: Outcome?
    private var outOfRace: [Side: Error] = [:]

    var isDecided: Bool { lock.withLock { outcome != nil } }

    /// Why `side` stepped aside, or nil while it can still answer (or never joined).
    func reason(_ side: Side) -> Error? { lock.withLock { outOfRace[side] } }

    func approve(_ grant: Grant, by side: Side) { settle(.approved(grant, by: side)) }

    /// An explicit "no": Cancel on the Mac, Reject on the iPhone.
    func deny(_ error: Error, by side: Side) { settle(.failed(error, by: side)) }

    /// This side can't decide any more; the other one still can.
    func stepAside(_ side: Side, because error: Error) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outOfRace[side] = error
        let over = outOfRace.count == 2
        if over { outcome = .failed(error, by: side) }
        lock.unlock()
        if over { decided.signal() }
    }

    /// Blocks until decided.
    func wait() -> Outcome {
        decided.wait()
        decided.signal()   // later waiters return at once
        return lock.withLock { outcome! }
    }

    /// Blocks at most `timeout`; nil while undecided.
    func wait(timeout: TimeInterval) -> Outcome? {
        guard decided.wait(timeout: .now() + timeout) == .success else { return nil }
        decided.signal()
        return lock.withLock { outcome }
    }

    private func settle(_ result: Outcome) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        lock.unlock()
        decided.signal()
    }
}
