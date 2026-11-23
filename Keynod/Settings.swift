import AppKit
import SwiftUI

enum Prefs {
    enum Key {
        static let keyCatcherEnabled = "keyCatcherEnabled"
    }

    static var keyCatcherEnabled: Bool {
        UserDefaults.standard.object(forKey: Key.keyCatcherEnabled) as? Bool ?? true
    }
}

final class HooksControl: ObservableObject {
    @Published private(set) var state = ClaudeHooks.state()
    @Published private(set) var error: String?

    var text: String {
        switch state {
        case .installed: "Installed"
        case .partial: "Partially installed"
        case .notInstalled: "Not installed"
        case .unreadable: "Settings unreadable"
        }
    }

    var buttonTitle: String { state == .installed ? "Uninstall" : "Install" }

    func refresh() { state = ClaudeHooks.state() }

    func toggle() {
        do {
            if state == .installed { try ClaudeHooks.uninstall() } else { try ClaudeHooks.install() }
            error = nil
        } catch {
            self.error = "\(error)"
        }
        state = ClaudeHooks.state()
        if case .unreadable(let why) = state, error == nil { error = why }
    }
}

struct SettingsSectionView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(section: .settings)
                .padding(.horizontal, 20)
                .frame(height: 26)
                .padding(.top, 10)
            SettingsView()
                .frame(maxWidth: 640)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SettingsView: View {
    @AppStorage(Prefs.Key.keyCatcherEnabled) private var keyCatcherEnabled = true
    @State private var phoneName = PhoneLink.shared.phone?.name
    @State private var confirmingUnpair = false
    @State private var remote = PhoneLink.shared.isRemote
    @StateObject private var hooks = HooksControl()

    var body: some View {
        Form {
            Section("iPhone Approvals") {
                if !LinkCloud.shared.isConfigured {
                    Text("iCloud CloudKit isn't configured in this build. Set KEYNOD_TEAM_ID and KEYNOD_ICLOUD_CONTAINER in Local.xcconfig to enable iPhone Face ID approvals.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let phoneName {
                    LabeledContent("Paired iPhone", value: phoneName)
                    Toggle("Remote mode", isOn: Binding(get: { remote }, set: { PhoneLink.shared.setRemote($0) }))
                    Text(remote
                         ? "Requests go only to \(phoneName) for Face ID approval. Touch ID on this Mac stays quiet, and Keynod prevents idle sleep."
                         : "Requests ask for Touch ID on this Mac. Turn on Remote Mode when stepping away — you can also flip it from your iPhone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Re-pair\u{2026}") { PairingWindowController.shared.show() }
                        Button("Unpair\u{2026}", role: .destructive) { confirmingUnpair = true }
                            .confirmationDialog("Unpair \(phoneName)?", isPresented: $confirmingUnpair, titleVisibility: .visible) {
                                Button("Unpair", role: .destructive) { PhoneLink.shared.unpair() }
                            } message: {
                                Text("Touch ID keeps working. This iPhone will no longer be able to approve Keynod requests.")
                            }
                    }
                } else {
                    Text("Approve CLI secret requests and Claude Code prompts with Face ID on your iPhone over private iCloud (no server).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Pair iPhone\u{2026}") { PairingWindowController.shared.show() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: PhoneLink.didChange)) { _ in
                phoneName = PhoneLink.shared.phone?.name
                remote = PhoneLink.shared.isRemote
            }

            Section("Claude Code Hooks") {
                LabeledContent("Status") {
                    HStack {
                        Text(hooks.text).foregroundStyle(.secondary)
                        Button(hooks.buttonTitle, action: hooks.toggle)
                    }
                }
                if let hooksError = hooks.error {
                    Text(hooksError).font(.caption).foregroundStyle(.red)
                }
                Text("Installs PermissionRequest, Stop, and PreToolUse hooks into ~/.claude/settings.json (with an automatic backup). Only active while Remote Mode is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear { hooks.refresh() }

            Section("Key Catcher") {
                Toggle("Detect copied API keys and private keys", isOn: $keyCatcherEnabled)
                    .onChange(of: keyCatcherEnabled) { _, _ in
                        PasteboardWatcher.shared.applyPreferences()
                    }
                Text("Watches for copied API keys (Anthropic, OpenAI, fal.ai, GitHub, AWS, Stripe, PEM keys, JWTs, and more) and offers a floating Save to Vault card. No clipboard history is ever stored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Encrypted Backup") {
                HStack {
                    Button("Export Vault\u{2026}") { BackupFlow.export() }
                    Button("Import Vault\u{2026}") { BackupFlow.importVault() }
                }
                Text("Exports all secrets and concealed fields into an AES-256-GCM file sealed with PBKDF2-HMAC-SHA256 (600,000 iterations).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
