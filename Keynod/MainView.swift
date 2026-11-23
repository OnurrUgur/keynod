import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

enum MainSection: String, CaseIterable, Identifiable {
    case vault, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vault: "Vault"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .vault: "lock.shield"
        case .settings: "gearshape"
        }
    }
}

enum MainWindow {
    static let defaultSize = CGSize(width: 880, height: 660)
    static let minSize = CGSize(width: 720, height: 480)
    static let topBarHeight: CGFloat = 34
    static let trafficLights: CGFloat = 78
}

final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var section: MainSection = .vault
    @Published var selection: UUID?
    @Published var editorFocusToken = 0
    @Published var vaultQuery = ""
    @Published var vaultSearchToken = 0
    @Published var focusField: UUID?
    var focusTitle = false
    weak var window: NSWindow?
    private var keyMonitor: Any?

    private init() {}

    func delete(_ id: UUID) {
        let store = Store.shared
        guard let secret = store.secret(id), confirmDeleteSecret(secret) else { return }
        if selection == id {
            let order = store.secrets.map(\.id)
            if let i = order.firstIndex(of: id) {
                selection = order.indices.contains(i + 1) ? order[i + 1] : (i > 0 ? order[i - 1] : nil)
            }
        }
        store.delete(id)
    }

    private func confirmDeleteSecret(_ secret: Secret) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete \u{201C}\(secret.title)\u{201D}?"
        alert.informativeText = "Concealed values will be permanently removed from the Keychain."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    var visibleSelection: UUID? {
        guard section == .vault, let id = selection, Store.shared.secret(id) != nil else { return nil }
        return id
    }

    func dropBlankSelection() {
        guard let id = selection, let secret = Store.shared.secret(id), secret.isBlank else { return }
        selection = nil
        Store.shared.delete(id)
    }

    func newSecret(_ template: SecretTemplate = .apiKey) {
        guard let secret = try? Store.shared.addSecret(title: template.title, fields: template.makeFields()) else { return }
        section = .vault
        focusTitle = true
        selection = secret.id
        editorFocusToken += 1
    }

    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === window, !(window?.firstResponder is NSTextView) else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if Int(event.keyCode) == kVK_Escape, modifiers.isEmpty, section == .settings {
                section = .vault
                return nil
            }
            return event
        }
    }
}

struct SectionTitle: View {
    let section: MainSection

    var body: some View {
        Text(section.title)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.text)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @ObservedObject var app = AppModel.shared
    @State private var remote = PhoneLink.shared.isRemote
    @State private var paired = PhoneLink.shared.isPaired

    var body: some View {
        HStack(spacing: 6) {
            if app.section == .settings {
                BackButton { app.section = .vault }
            }
            Spacer(minLength: 8)
            if paired {
                RemotePillButton(isOn: remote) { PhoneLink.shared.setRemote(!remote) }
            }
            StayAwakeTopBarButton()
            TopBarButton(section: .settings, active: app.section == .settings) {
                app.section = app.section == .settings ? .vault : .settings
            }
        }
        .padding(.leading, MainWindow.trafficLights)
        .padding(.trailing, 14)
        .frame(height: MainWindow.topBarHeight)
        .onReceive(NotificationCenter.default.publisher(for: PhoneLink.didChange)) { _ in
            paired = PhoneLink.shared.isPaired
            remote = PhoneLink.shared.isRemote
        }
    }
}

private struct RemotePillButton: View {
    let isOn: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "iphone.radiowaves.left.and.right" : "iphone")
                    .font(.system(size: 11.5))
                Text(isOn ? "Remote On" : "Remote Off")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(isOn ? Theme.accent : (hovering ? Theme.text : Theme.textSecondary))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(isOn ? Theme.accent.opacity(0.12) : (hovering ? Theme.hover : .clear),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isOn ? "Remote mode on: requests go to your iPhone" : "Remote mode off: requests use Touch ID on this Mac")
    }
}

private struct BackButton: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                Text("Vault")
                    .font(.system(size: 13))
            }
            .foregroundStyle(hovering ? Theme.text : Theme.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Back to Vault (Esc)")
    }
}

private struct TopBarButton: View {
    let section: MainSection
    let active: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: section.symbol)
                .font(.system(size: 13))
                .foregroundStyle(active ? Theme.accent : (hovering ? Theme.text : Theme.textSecondary))
                .frame(width: 26, height: 24)
                .background(hovering || active ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(section.title)
        .accessibilityLabel(section.title)
    }
}

private struct StayAwakeTopBarButton: View {
    @ObservedObject private var awake = StayAwake.shared
    @State private var hovering = false

    private var isOn: Bool { awake.until != nil }

    private var text: String? {
        if let notice = awake.notice { return notice }
        if awake.needsSetup { return "Setup needed" }
        return awake.untilText.map { "Until \($0)" }
    }

    var body: some View {
        Button { awake.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "moon.fill" : "moon")
                    .font(.system(size: 13))
                if let text {
                    Text(text)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isOn || text != nil ? Theme.accent : (hovering ? Theme.text : Theme.textSecondary))
            .padding(.horizontal, text == nil ? 0 : 7)
            .frame(width: text == nil ? 26 : nil, height: 24)
            .fixedSize()
            .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isOn ? "Staying awake overnight — click to turn off" : "Keep Mac awake until 09:00 for unattended agent runs")
        .accessibilityLabel("Stay awake overnight")
    }
}

// MARK: - Window content

struct MainView: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var app = AppModel.shared
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Rectangle().fill(Theme.border).frame(height: 1)
            Group {
                switch app.section {
                case .vault: VaultView()
                case .settings: SettingsSectionView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
        .ignoresSafeArea()
        .frame(minWidth: MainWindow.minSize.width, minHeight: MainWindow.minSize.height)
        .onAppear { app.installKeyMonitor() }
        .onChange(of: app.selection) { old, _ in
            if let old, store.secret(old)?.isBlank == true { store.delete(old) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { app.handleDrop($0) }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }
}
