import SwiftUI

/// A secret inside the menu bar popover: one line per field, copy only.
/// Concealed values are never displayed here.
struct QuickSecretView: View {
    let secret: Secret
    let selected: UUID?
    var onBack: () -> Void
    var onOpenKeynod: () -> Void
    var onCopy: (SecretField) -> Void
    var onSelect: (SecretField) -> Void

    var body: some View {
        VStack(spacing: 2) {
            header
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(secret.fields) { field in
                            fieldRow(field).id(field.id)
                        }
                    }
                }
                .frame(maxHeight: 210)
                .onChange(of: selected) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back (Esc)")
            Image(systemName: "key.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
            Text(secret.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Edit", action: onOpenKeynod)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.leading, 2)
        .padding(.trailing, 6)
        .frame(height: 28)
    }

    private func fieldRow(_ field: SecretField) -> some View {
        let isSelected = selected == field.id
        return HStack(spacing: 10) {
            Text(field.label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(width: 88, alignment: .leading)
            value(field)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { onCopy(field) } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Theme.text : Theme.textTertiary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy")
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: 28)
        .background(isSelected ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { onSelect(field) }
    }

    @ViewBuilder
    private func value(_ field: SecretField) -> some View {
        if field.concealed {
            Text(field.filename.map { "\u{2022}\u{2022}\u{2022}\u{2022} \($0)" } ?? "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        } else {
            Text(field.value.flatMap { $0.isEmpty ? nil : $0 } ?? "Empty")
                .font(.system(size: 12.5))
                .foregroundStyle(field.value?.isEmpty == false ? Theme.text : Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
