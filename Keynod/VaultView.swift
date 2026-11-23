import SwiftUI

/// API keys, logins, and key files: searchable list on the left, editor on the right.
struct VaultView: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var app = AppModel.shared
    @FocusState private var listFocused: Bool

    private var visibleSecrets: [Secret] { Secret.filter(store.secrets, query: app.vaultQuery) }

    var body: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(width: 310)
            Rectangle().fill(Theme.border).frame(width: 1)
            Group {
                if let id = app.selection, store.secret(id) != nil {
                    SecretEditorView(id: id).id(id)
                } else {
                    emptyEditor
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDisappear { app.dropBlankSelection() }
    }

    private var listColumn: some View {
        let secrets = visibleSecrets
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(section: .vault)
                Spacer()
                NewSecretMenu()
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .padding(.top, 8)

            if !store.secrets.isEmpty {
                VaultSearchField(query: $app.vaultQuery, focusToken: app.vaultSearchToken) {
                    guard let first = visibleSecrets.first else { return }
                    app.selection = first.id
                    listFocused = true
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(secrets) { secret in
                        SecretRow(secret: secret, selected: app.selection == secret.id) {
                            app.selection = secret.id
                            listFocused = true
                        }
                    }
                    if secrets.isEmpty && !store.secrets.isEmpty {
                        Text("No secrets matching \u{201C}\(app.vaultQuery.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .lineSpacing(3)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                    } else if secrets.isEmpty {
                        Text("Store API keys, logins, and .p8 / private key files here — or drag an AuthKey_*.p8 file straight onto this window.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .lineSpacing(3)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.upArrow) { move(-1) }
            .onKeyPress(.downArrow) { move(1) }
            .onKeyPress(.return) {
                guard app.selection != nil else { return .ignored }
                app.editorFocusToken += 1
                return .handled
            }
        }
        .padding(.horizontal, 10)
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        let list = visibleSecrets
        guard !list.isEmpty else { return .ignored }
        let current = list.firstIndex { $0.id == app.selection } ?? (delta > 0 ? -1 : list.count)
        let next = min(max(current + delta, 0), list.count - 1)
        app.selection = list[next].id
        return .handled
    }

    private var emptyEditor: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 28))
                .foregroundStyle(Theme.textTertiary)
            Text("No secret selected")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text("\u{2318}N for a new secret")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

private struct VaultSearchField: View {
    @Binding var query: String
    let focusToken: Int
    var onPickFirst: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            TextField(text: $query, prompt: Text("Search vault").foregroundStyle(Theme.textTertiary)) {
                Text("Search vault")
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.text)
            .focused($focused)
            .onSubmit(onPickFirst)
            .onExitCommand {
                query = ""
                focused = false
            }
            .onKeyPress(.downArrow) {
                onPickFirst()
                return .handled
            }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border))
        .padding(.horizontal, 4)
        .help("Search vault (\u{2318}F)")
        .onChange(of: focusToken) { _, _ in focused = true }
    }
}

private struct NewSecretMenu: View {
    @State private var hovering = false

    var body: some View {
        Menu {
            ForEach(SecretTemplate.allCases) { template in
                Button { AppModel.shared.newSecret(template) } label: {
                    Label(template.menuLabel, systemImage: template.symbol)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? Theme.text : Theme.textSecondary)
                .frame(width: 20, height: 20)
                .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(hovering ? Theme.text : Theme.textSecondary)
        .onHover { hovering = $0 }
        .help("New secret (\u{2318}N)")
    }
}

private struct SecretRow: View {
    let secret: Secret
    let selected: Bool
    var onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "key.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 13, height: 13)
                .padding(3)

            VStack(alignment: .leading, spacing: 2) {
                Text(secret.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(!secret.preview.isEmpty ? secret.preview
                    : !secret.tags.isEmpty ? secret.tags.map { "#" + $0 }.joined(separator: " ")
                    : "\(secret.fields.count) field\(secret.fields.count == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .padding(.top, 2)
            Spacer(minLength: 6)
            Text(shortDate(secret.createdAt))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 3)
        }
        .padding(.leading, 5)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(
            selected ? Theme.selected : (hovering ? Theme.hover : .clear),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("Delete", role: .destructive) { AppModel.shared.delete(secret.id) }
        }
    }
}
