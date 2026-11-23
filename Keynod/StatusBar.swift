import AppKit
import Combine
import SwiftUI

/// Menu bar icon with a fast vault search & copy popover and Remote Mode toggle.
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let state = QuickVaultState()
    private var authObserver: AnyCancellable?
    private var questionObserver: AnyCancellable?
    private var awakeObserver: AnyCancellable?

    init(onOpen: @escaping (UUID?) -> Void, onOpenSection: @escaping (MainSection) -> Void) {
        super.init()
        if let button = item.button {
            let image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "Keynod")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(toggle)
        }

        questionObserver = PendingQuestions.shared.$pending
            .map(\.count)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in self?.show(waiting: count) }

        awakeObserver = MainActor.assumeIsolated { StayAwake.shared.$until }
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] awake in
                let name = awake ? "moon.fill" : "key.fill"
                let image = NSImage(systemSymbolName: name, accessibilityDescription: "Keynod")
                image?.isTemplate = true
                self?.item.button?.image = image
            }

        popover.behavior = .transient
        popover.delegate = self
        authObserver = MainActor.assumeIsolated { VaultSession.shared.$isAuthenticating }
            .removeDuplicates()
            .sink { [weak self] busy in
                guard let self else { return }
                popover.behavior = busy ? .applicationDefined : .transient
                if !busy, popover.isShown { popover.contentViewController?.view.window?.makeKey() }
            }
        popover.animates = false
        popover.contentSize = NSSize(width: QuickVaultPopover.width, height: 300)
        let host = NSHostingController(rootView: QuickVaultPopover(
            state: state,
            onOpen: { [weak self] id in
                self?.popover.performClose(nil)
                onOpen(id)
            },
            onOpenSection: { [weak self] section in
                self?.popover.performClose(nil)
                onOpenSection(section)
            },
            onClose: { [weak self] in self?.popover.performClose(nil) }
        ))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
    }

    var isInMenuBar: Bool {
        guard item.isVisible else { return false }
        let name = item.autosaveName ?? "Item-0"
        return UserDefaults.standard.object(forKey: "NSStatusItem VisibleCC \(name)") as? Bool ?? true
    }

    private func show(waiting count: Int) {
        guard let button = item.button else { return }
        button.title = count > 0 ? " \(count)" : ""
        button.imagePosition = count > 0 ? .imageLeading : .imageOnly
        item.length = count > 0 ? NSStatusItem.variableLength : NSStatusItem.squareLength
        button.setAccessibilityLabel(count > 0 ? "Keynod, \(count) pending" : "Keynod")
    }

    func popoverDidClose(_ notification: Notification) {
        state.reset()
    }

    @objc func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            state.focusToken += 1
        }
    }
}

final class QuickVaultState: ObservableObject {
    @Published var query = ""
    @Published var openedSecretID: UUID?
    @Published var selectedFieldID: UUID?
    @Published var statusMessage: String?
    @Published var focusToken = 0

    func reset() {
        query = ""
        openedSecretID = nil
        selectedFieldID = nil
        statusMessage = nil
    }
}

struct QuickVaultPopover: View {
    static let width: CGFloat = 340

    @ObservedObject var state: QuickVaultState
    @ObservedObject private var store = Store.shared
    @ObservedObject private var pending = PendingQuestions.shared
    @State private var paired = PhoneLink.shared.isPaired
    @State private var remote = PhoneLink.shared.isRemote
    @FocusState private var searchFocused: Bool

    var onOpen: (UUID?) -> Void
    var onOpenSection: (MainSection) -> Void
    var onClose: () -> Void

    private var filtered: [Secret] {
        Array(Secret.filter(store.secrets, query: state.query).prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let id = state.openedSecretID, let secret = store.secret(id) {
                QuickSecretView(
                    secret: secret,
                    selected: state.selectedFieldID,
                    onBack: { state.openedSecretID = nil; state.selectedFieldID = nil },
                    onOpenKeynod: { onOpen(secret.id) },
                    onCopy: { copy($0) },
                    onSelect: { state.selectedFieldID = $0.id }
                )
            } else {
                searchBar
                if !pending.pending.isEmpty {
                    pendingBanner
                }
                secretList
            }

            if let msg = state.statusMessage {
                Text(msg)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(2)
            }

            Rectangle().fill(Theme.border).frame(height: 1)
            footer
        }
        .padding(12)
        .frame(width: Self.width)
        .background(Theme.bg)
        .onChange(of: state.focusToken) { _, _ in searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: PhoneLink.didChange)) { _ in
            paired = PhoneLink.shared.isPaired
            remote = PhoneLink.shared.isRemote
        }
    }

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            TextField("Search secrets\u{2026}", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .focused($searchFocused)
                .onSubmit {
                    if let first = filtered.first {
                        state.openedSecretID = first.id
                        state.selectedFieldID = first.fields.first?.id
                    }
                }
                .onExitCommand(perform: onClose)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
    }

    private var pendingBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
            Text("\(pending.pending.count) request\(pending.pending.count == 1 ? "" : "s") waiting on iPhone")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.text)
            Spacer()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var secretList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if filtered.isEmpty {
                Text(store.secrets.isEmpty ? "Your vault is empty. Open Keynod to add your first secret." : "No matching secrets.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 4)
            } else {
                ForEach(filtered) { secret in
                    Button {
                        state.openedSecretID = secret.id
                        state.selectedFieldID = secret.fields.first?.id
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textSecondary)
                            Text(secret.title)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Spacer()
                            Text("\(secret.fields.count)")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(Theme.elevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Open Vault") { onOpenSection(.vault) }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

            if paired {
                Button(remote ? "Remote: On" : "Remote: Off") {
                    PhoneLink.shared.setRemote(!remote)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(remote ? Theme.accent : Theme.textSecondary)
            }

            Spacer()

            Button { onOpenSection(.settings) } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }

    private func copy(_ field: SecretField) {
        guard field.concealed else {
            Clipboard.copy(field.value ?? "", concealed: false)
            flash("Copied \(field.label)")
            return
        }
        Task {
            do {
                let text = try await VaultSession.shared.readText(field, reason: "copy \(field.label)")
                Clipboard.copy(text, concealed: true)
                flash("Copied \(field.label) (clears in 45s)")
            } catch {
                if let msg = VaultSession.message(for: error, field: field) { flash(msg) }
            }
        }
    }

    private func flash(_ text: String) {
        state.statusMessage = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if state.statusMessage == text { state.statusMessage = nil }
        }
    }
}
