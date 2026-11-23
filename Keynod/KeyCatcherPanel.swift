import AppKit
import SwiftUI

/// Lightweight pasteboard watcher solely for `KeyCatcher`.
/// Never records or persists clipboard history — only inspects newly copied plain text
/// for API keys/tokens and offers to save them into the Vault.
final class PasteboardWatcher {
    static let shared = PasteboardWatcher()

    private var timer: Timer?
    private var lastCount: Int = NSPasteboard.general.changeCount
    private var ignoredCount: Int?

    private init() {}

    func start() {
        applyPreferences()
    }

    func applyPreferences() {
        timer?.invalidate()
        timer = nil
        guard Prefs.keyCatcherEnabled else { return }
        lastCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func ignore(changeCount: Int) {
        ignoredCount = changeCount
    }

    private func tick() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastCount else { return }
        lastCount = count
        if ignoredCount == count { return }

        // Respect password managers and transient copies.
        if let types = pb.types, types.contains(where: { Clipboard.skipTypes.contains($0) }) { return }
        guard let text = pb.string(forType: .string), !text.isEmpty, text.count <= 64_000 else { return }
        guard let finding = KeyCatcher.detect(text) else { return }
        KeyCatcherPanel.shared.show(finding, changeCount: count)
    }
}

/// The small floating card that appears after copying an API key or private key.
/// Takes no focus so the user keeps typing, and dismisses itself automatically.
final class KeyCatcherPanel {
    static let shared = KeyCatcherPanel()

    private var panel: NSPanel?
    private var timer: Timer?

    func show(_ finding: KeyCatcher.Finding, changeCount: Int) {
        dismiss()
        let view = KeyCatcherView(
            kind: finding.kind,
            onSave: { [weak self] in
                Self.save(finding)
                self?.dismiss()
            },
            onClear: { [weak self] in
                Self.clear(ifStill: changeCount)
                self?.dismiss()
            },
            onIgnore: { [weak self] in self?.dismiss() }
        )
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)

        let panel = KeyCardPanel(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.maxX - size.width - 16, y: area.maxY - size.height - 12))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in self?.dismiss() }
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private static func save(_ finding: KeyCatcher.Finding) {
        let field = SecretField(label: finding.label, concealed: true)
        do {
            let secret = try Store.shared.addSecret(title: finding.kind, fields: [field],
                                                    values: [field.id: Data(finding.value.utf8)])
            let app = AppModel.shared
            app.section = .vault
            app.focusTitle = true
            (NSApp.delegate as? AppDelegate)?.openMain(select: secret.id)
            app.editorFocusToken += 1
        } catch {
            NSLog("Keynod: could not save the copied key to the Vault")
            NSSound.beep()
        }
    }

    private static func clear(ifStill changeCount: Int) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == changeCount else { return }
        pasteboard.clearContents()
        PasteboardWatcher.shared.ignore(changeCount: pasteboard.changeCount)
    }
}

private final class KeyCardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct KeyCatcherView: View {
    let kind: String
    var onSave: () -> Void
    var onClear: () -> Void
    var onIgnore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.yellow)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(kind) copied")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("Save it to Keynod Vault or clear your clipboard.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            HStack(spacing: 8) {
                button("Save to Vault", prominent: true, action: onSave)
                button("Clear Clipboard", action: onClear)
                button("Ignore", action: onIgnore)
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
    }

    private func button(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: prominent ? .semibold : .regular))
                .foregroundStyle(prominent ? Color.white : Theme.text)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(prominent ? Theme.accent : Theme.selected, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
