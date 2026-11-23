import AppKit
import Combine
import LocalAuthentication
import Security

/// One Touch ID approval unlocks the Vault for a grace window. Reads inside
/// the window reuse the approved LAContext; it is dropped on timeout, screen
/// lock and sleep. Nothing here blocks the main thread.
@MainActor
final class VaultSession: ObservableObject {
    static let shared = VaultSession()
    static let grace: TimeInterval = 5 * 60

    /// Posted whenever the session locks, so views can hide revealed values.
    nonisolated static let didLock = Notification.Name("KeynodVaultSessionDidLock")

    /// True while the system Touch ID / password dialog is up. It steals key
    /// focus, so the popover uses this to stay open meanwhile.
    @Published private(set) var isAuthenticating = false
    private var uiAuthenticating = false { didSet { isAuthenticating = uiAuthenticating || cliAuthenticating > 0 } }
    private var cliAuthenticating = 0 { didSet { isAuthenticating = uiAuthenticating || cliAuthenticating > 0 } }

    private var context: LAContext?
    private var pending: Task<LAContext, Error>?
    private var expiry: DispatchWorkItem?

    private init() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.lock() } }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.lock() } }
    }

    /// The CLI server shows its own Touch ID dialog; keep the popover open meanwhile.
    nonisolated static func setCLIAuthenticating(_ on: Bool) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { shared.cliAuthenticating += on ? 1 : -1 }
        }
    }

    var isUnlocked: Bool { context != nil }

    /// Prompts once (Touch ID or password); later calls reuse the approval.
    func unlock(reason: String) async throws -> LAContext {
        if let context { return context }
        if let pending { return try await pending.value }
        let task = Task { () -> LAContext in
            let ctx = LAContext()
            _ = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return ctx
        }
        pending = task
        uiAuthenticating = true
        defer { pending = nil; uiAuthenticating = false }
        let ctx = try await task.value
        context = ctx
        let work = DispatchWorkItem { [weak self] in self?.lock() }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.grace, execute: work)
        return ctx
    }

    /// Reads one concealed value off the main thread.
    func read(_ id: UUID, reason: String) async throws -> Data {
        let ctx = try await unlock(reason: reason)
        return try await Task.detached { try Vault.get(id, reason: reason, context: ctx) }.value
    }

    /// A concealed field as UTF-8 text (PEM for .p8), through the session.
    func readText(_ field: SecretField, reason: String) async throws -> String {
        let data = try await read(field.id, reason: reason)
        guard let text = String(data: data, encoding: .utf8) else {
            throw Vault.Message("\(field.label) is not text and can't be shown or copied.")
        }
        return text
    }

    /// User-facing text for a failed read; nil when the user just cancelled.
    nonisolated static func message(for error: Error, field: SecretField) -> String? {
        if let e = error as? LAError, [.userCancel, .appCancel, .systemCancel].contains(e.code) { return nil }
        if let e = error as? Vault.Failure, e.status == errSecItemNotFound {
            return "\(field.label) has no value yet. Click the pencil icon to enter one."
        }
        return "\(error)"
    }

    func lock() {
        expiry?.cancel()
        expiry = nil
        guard let ctx = context else { return }
        ctx.invalidate()
        context = nil
        NotificationCenter.default.post(name: Self.didLock, object: nil)
    }
}

/// Copying secrets: kept off clipboard managers and other devices, cleared
/// after a delay if nobody copied anything since.
enum Clipboard {
    static func copy(_ string: String, concealed: Bool, clearAfter: TimeInterval = 45) {
        let pb = NSPasteboard.general
        if concealed {
            pb.prepareForNewContents(with: .currentHostOnly)
        } else {
            pb.clearContents()
        }
        pb.setString(string, forType: .string)
        if concealed {
            pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
        PasteboardWatcher.shared.ignore(changeCount: pb.changeCount)
        guard concealed else { return }
        let count = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + clearAfter) {
            if pb.changeCount == count { pb.clearContents() }
        }
    }

    /// Pasteboard flags that mark an item as private or machine-made.
    static let skipTypes = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
    ].map { NSPasteboard.PasteboardType($0) }
}
