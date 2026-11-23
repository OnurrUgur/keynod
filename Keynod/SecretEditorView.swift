import AppKit
import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers

/// Editor for a `Secret`: title, description, then one row per field.
/// Concealed values are only read from the Vault on Reveal / Copy.
struct SecretEditorView: View {
    let id: UUID
    @ObservedObject var store = Store.shared
    @ObservedObject var app = AppModel.shared
    @State private var revealed: [UUID: String] = [:]
    @State private var hideTasks: [UUID: Task<Void, Never>] = [:]
    @State private var editing: UUID?
    @State private var draft = ""
    @State private var error: String?
    @FocusState private var titleFocused: Bool
    @FocusState private var focus: UUID?

    private static let autoHide: UInt64 = 30

    var body: some View {
        let secret = store.secret(id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                Text("Secret")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if let secret {
                    Text(shortDate(secret.createdAt))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                iconButton("trash", help: "Delete secret (\u{2325}\u{2318}\u{232B})") { app.delete(id) }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 10)

            Rectangle().fill(Theme.border).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Title", text: titleBinding)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .focused($titleFocused)
                    TextField("Description", text: descriptionBinding,
                              prompt: Text("What is this for? e.g. Production deploy key #prod #api"),
                              axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                    if let tags = secret?.tags, !tags.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(tags, id: \.self) { tag in
                                Text("#" + tag)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Theme.elevated, in: Capsule())
                                    .overlay(Capsule().strokeBorder(Theme.border))
                            }
                        }
                    }
                    if let twin = store.duplicateLogin(of: id) {
                        Button {
                            app.selection = twin.id
                        } label: {
                            Label("Another login has the same website and username: \(twin.title)",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(hex: 0xE2A53B))
                                .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)
                        .help("Open duplicate secret")
                    }
                    Spacer().frame(height: 2)

                    ForEach(secret?.fields ?? []) { fieldRow($0) }

                    addMenu
                    if let error {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(Color(hex: 0xEB5757))
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
        }
        .onAppear {
            if app.focusTitle || secret?.isBlank == true {
                app.focusTitle = false
                Task { try? await Task.sleep(nanoseconds: 100_000_000); titleFocused = true }
            }
            if let target = app.focusField {
                app.focusField = nil
                Task { try? await Task.sleep(nanoseconds: 150_000_000); focus = target }
            }
        }
        .onChange(of: app.editorFocusToken) { _, _ in titleFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: VaultSession.didLock)) { _ in hideAll() }
        .onChange(of: revealed.isEmpty) { _, empty in app.window?.sharingType = empty ? .readOnly : .none }
        .onDisappear { hideAll(); app.window?.sharingType = .readOnly }
    }

    // MARK: Rows

    private func fieldRow(_ f: SecretField) -> some View {
        HStack(spacing: 10) {
            TextField("Label", text: Binding(
                get: { store.secret(id)?.fields.first { $0.id == f.id }?.label ?? "" },
                set: { store.updateField(f.id, in: id, label: $0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 110, alignment: .leading)

            valueView(f)
                .frame(maxWidth: .infinity, alignment: .leading)

            if f.concealed && f.isSet {
                iconButton(revealed[f.id] == nil ? "eye" : "eye.slash", help: "Reveal for 30 seconds") { toggleReveal(f) }
                iconButton("pencil", help: f.filename == nil ? "Change value" : "Replace file") { beginEdit(f) }
            }
            if f.isSet { iconButton("doc.on.doc", help: "Copy") { copy(f) } }
            iconButton("minus.circle", help: "Remove field") { remove(f) }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
    }

    @ViewBuilder
    private func valueView(_ f: SecretField) -> some View {
        if !f.concealed {
            TextField("Value", text: Binding(
                get: { store.secret(id)?.fields.first { $0.id == f.id }?.value ?? "" },
                set: { store.updateField(f.id, in: id, plainValue: $0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Theme.text)
            .focused($focus, equals: f.id)
        } else if editing == f.id {
            SecureField("New value, then press \u{21A9}", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focus, equals: f.id)
                .onSubmit { commitEdit(f) }
                .onExitCommand { editing = nil; draft = "" }
        } else if let text = revealed[f.id] {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .lineLimit(f.filename == nil ? 3 : 8)
        } else if !f.isSet {
            Button { beginEdit(f) } label: {
                Text(f.filename == nil ? "Set value\u{2026}" : "Choose file\u{2026}")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .help(f.filename == nil ? "Enter concealed value" : "Pick a file")
        } else {
            Text(f.filename.map { "\u{2022}\u{2022}\u{2022}\u{2022} \($0)" } ?? "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
    }

    private var addMenu: some View {
        Menu {
            Button("Plain Text") { add(SecretField(label: "Text", value: ""), focus: true) }
            Button("Concealed Secret") { add(SecretField(label: "Secret", concealed: true, hasValue: false), edit: true) }
            Button("File\u{2026}") { pickFile() }
        } label: {
            Label("Add field", systemImage: "plus")
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Theme.textSecondary)
        .padding(.top, 2)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Title

    private var titleBinding: Binding<String> {
        Binding(
            get: { Self.split(store.secret(id)?.text ?? "").title },
            set: { store.update(id, text: Self.join($0, Self.split(store.secret(id)?.text ?? "").rest)) }
        )
    }

    private var descriptionBinding: Binding<String> {
        Binding(
            get: { Self.split(store.secret(id)?.text ?? "").rest },
            set: { store.update(id, text: Self.join(Self.split(store.secret(id)?.text ?? "").title, $0)) }
        )
    }

    private static func split(_ text: String) -> (title: String, rest: String) {
        guard let i = text.firstIndex(where: \.isNewline) else { return (text, "") }
        return (String(text[..<i]), String(text[text.index(after: i)...]))
    }

    private static func join(_ title: String, _ rest: String) -> String {
        rest.isEmpty ? title : title + "\n" + rest
    }

    // MARK: Actions

    private func add(_ field: SecretField, focus wantsFocus: Bool = false, edit: Bool = false) {
        do { try store.addField(field, to: id) } catch { return fail(error) }
        if wantsFocus { Task { try? await Task.sleep(nanoseconds: 100_000_000); focus = field.id } }
        if edit { beginEdit(field) }
    }

    private func pickFile() {
        guard let url = AppModel.pickFile() else { return }
        do { try app.addFile(url, to: id) } catch { fail(error) }
    }

    private func beginEdit(_ f: SecretField) {
        if f.filename != nil {
            guard let url = AppModel.pickFile() else { return }
            do {
                try store.setConcealedValue(try AppModel.readFile(url), fieldID: f.id, in: id, filename: url.lastPathComponent)
                hide(f.id)
            } catch { fail(error) }
            return
        }
        draft = ""
        editing = f.id
        Task { try? await Task.sleep(nanoseconds: 100_000_000); focus = f.id }
    }

    private func commitEdit(_ f: SecretField) {
        defer { editing = nil; draft = "" }
        guard !draft.isEmpty else { return }
        do {
            try store.setConcealedValue(Data(draft.utf8), fieldID: f.id, in: id)
            hide(f.id)
        } catch { fail(error) }
    }

    private func remove(_ f: SecretField) {
        hide(f.id)
        if editing == f.id { editing = nil; draft = "" }
        store.removeField(f.id, from: id)
    }

    private func toggleReveal(_ f: SecretField) {
        if revealed[f.id] != nil { return hide(f.id) }
        Task {
            guard let text = await read(f, reason: "reveal \(f.label)") else { return }
            revealed[f.id] = text
            hideTasks[f.id]?.cancel()
            hideTasks[f.id] = Task {
                try? await Task.sleep(nanoseconds: Self.autoHide * 1_000_000_000)
                if !Task.isCancelled { hide(f.id) }
            }
        }
    }

    private func copy(_ f: SecretField) {
        guard f.concealed else { return Clipboard.copy(f.value ?? "", concealed: false) }
        Task {
            guard let text = await read(f, reason: "copy \(f.label)") else { return }
            Clipboard.copy(text, concealed: true)
        }
    }

    private func read(_ f: SecretField, reason: String) async -> String? {
        error = nil
        do {
            return try await VaultSession.shared.readText(f, reason: reason)
        } catch {
            self.error = VaultSession.message(for: error, field: f)
            return nil
        }
    }

    private func hide(_ fieldID: UUID) {
        hideTasks[fieldID]?.cancel()
        hideTasks[fieldID] = nil
        revealed[fieldID] = nil
    }

    private func hideAll() {
        hideTasks.values.forEach { $0.cancel() }
        hideTasks = [:]
        revealed = [:]
    }

    private func fail(_ error: Error) { self.error = "\(error)" }
}

// MARK: - Files and drops

extension AppModel {
    static let maxFileSize = 1_000_000

    static func pickFile() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func readFile(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard data.count <= maxFileSize else {
            throw Vault.Message("\(url.lastPathComponent) is larger than 1 MB.")
        }
        return data
    }

    func addFile(_ url: URL, to secretID: UUID) throws {
        let data = try Self.readFile(url)
        let field = SecretField(label: "File", concealed: true, filename: url.lastPathComponent)
        try Store.shared.addField(field, value: data, to: secretID)
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { self.ingest(url) }
            }
        }
        return accepted
    }

    private func ingest(_ url: URL) {
        do {
            if let keyID = Self.appStoreKeyID(url.lastPathComponent) {
                guard confirmNotDuplicate(keyID), let info = askAppStoreKeyInfo(keyID: keyID) else { return }
                try createAppStoreKey(url, keyID: keyID, info: info)
            } else if section == .vault, let id = selection, Store.shared.secret(id) != nil {
                try addFile(url, to: id)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not store file"
            alert.informativeText = "\(error)"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private static func appStoreKeyID(_ filename: String) -> String? {
        guard filename.hasPrefix("AuthKey_"), filename.hasSuffix(".p8") else { return nil }
        let id = String(filename.dropFirst(8).dropLast(3))
        return !id.isEmpty && id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? id : nil
    }

    private func confirmNotDuplicate(_ keyID: String) -> Bool {
        guard let existing = Store.shared.secrets.first(where: { secret in
            secret.fields.contains { !$0.concealed && $0.label.lowercased() == "key id"
                && ($0.value ?? "").trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(keyID) == .orderedSame }
        }) else { return true }
        let alert = NSAlert()
        alert.messageText = "This key is already in Keynod: \(existing.title)"
        alert.informativeText = "Key ID \(keyID) is already saved."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Add Anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }

    struct AppStoreKeyInfo { var team: String; var issuer: String; var description: String }

    private func askAppStoreKeyInfo(keyID: String) -> AppStoreKeyInfo? {
        let team = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        team.placeholderString = "Team or account name (required)"
        let issuer = NSTextField(frame: team.frame)
        issuer.placeholderString = "Issuer ID (optional)"
        let desc = NSTextField(frame: team.frame)
        desc.placeholderString = "Description (optional)"
        let stack = NSStackView(views: [team, issuer, desc])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 88)

        var message = "Which team or account does \(keyID) belong to?"
        while true {
            let alert = NSAlert()
            alert.messageText = "New App Store Connect Key"
            alert.informativeText = message
            alert.accessoryView = stack
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = team
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            func clean(_ s: String) -> String {
                s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let name = clean(team.stringValue)
            if name.isEmpty { message = "Please enter a team or account name."; continue }
            return AppStoreKeyInfo(team: name, issuer: clean(issuer.stringValue), description: clean(desc.stringValue))
        }
    }

    private func createAppStoreKey(_ url: URL, keyID: String, info: AppStoreKeyInfo) throws {
        let issuer = SecretField(label: "Issuer ID", value: info.issuer)
        let key = SecretField(label: "Private Key", concealed: true, filename: url.lastPathComponent)
        let fields = [SecretField(label: "Key ID", value: keyID), issuer, key]
        var description = info.description
        if !Tags.parse(description).contains("asc") { description += (description.isEmpty ? "" : " ") + "#asc" }
        let secret = try Store.shared.addSecret(
            title: "App Store Connect \u{2013} \(info.team) \u{2013} \(keyID)\n\(description)",
            fields: fields, values: [key.id: try Self.readFile(url)]
        )
        section = .vault
        if info.issuer.isEmpty { focusField = issuer.id }
        selection = secret.id
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(bounds.width, subviews)
        for (view, origin) in zip(subviews, result.origins) {
            view.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (origins, CGSize(width: maxX, height: y + rowHeight))
    }
}
