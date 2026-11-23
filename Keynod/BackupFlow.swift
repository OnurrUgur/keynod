import AppKit
import UniformTypeIdentifiers

/// File > Export Vault… / Import Vault…: prompts and save/open panels around `Backup`.
@MainActor
enum BackupFlow {
    private static let type = UTType(filenameExtension: "keynodvault") ?? .data

    static func export() {
        let secrets = Store.shared.secrets
        guard !secrets.isEmpty else { return alert("Nothing to export", "Your vault has no secrets yet.") }
        guard let passphrase = askPassphrase(
            confirm: true,
            message: "Choose a passphrase (at least 12 characters). Without it, the backup file cannot be decrypted."
        ) else { return }
        Task {
            do {
                var items: [Backup.Item] = []
                for secret in secrets {
                    var values: [String: Data] = [:]
                    for field in secret.fields where field.concealed {
                        do { values[field.id.uuidString] = try await VaultSession.shared.read(field.id, reason: "export your Keynod vault") }
                        catch let e as Vault.Failure where e.status == errSecItemNotFound { continue }
                    }
                    items.append(Backup.Item(secret: secret, values: values))
                }
                let data = try Backup.encrypt(items, passphrase: passphrase)
                let panel = NSSavePanel()
                panel.allowedContentTypes = [Self.type]
                panel.nameFieldStringValue = "Keynod.keynodvault"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                alert("Vault exported", "\(items.count) secret\(items.count == 1 ? "" : "s") saved to \(url.lastPathComponent).")
            } catch {
                alert("Export failed", "\(error)")
            }
        }
    }

    static func importVault() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.type]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url,
              let passphrase = askPassphrase(confirm: false, message: "Passphrase for \(url.lastPathComponent)") else { return }
        do {
            let items = try Backup.decrypt(try Data(contentsOf: url), passphrase: passphrase)
            var added = 0, skipped = 0, clashed = 0, failed = 0
            // A Keychain item is keyed by its field id: an imported field with an id that is
            // already in use would replace (and on failure delete) another secret's value.
            var usedFieldIDs = Set(Store.shared.items.flatMap { $0.fields.map(\.id) })
            for item in items {
                if Store.shared.secret(item.secret.id) != nil { skipped += 1; continue }
                let fieldIDs = item.secret.fields.map(\.id)
                if fieldIDs.contains(where: usedFieldIDs.contains) || Set(fieldIDs).count != fieldIDs.count {
                    clashed += 1; continue
                }
                var values: [UUID: Data] = [:]
                for (key, data) in item.values { if let id = UUID(uuidString: key) { values[id] = data } }
                do {
                    try Store.shared.insertSecret(item.secret, values: values)
                    usedFieldIDs.formUnion(fieldIDs)
                    added += 1
                } catch { failed += 1 }
            }
            AppModel.shared.section = .vault
            var summary = "\(added) added, \(skipped) already existed"
            if clashed > 0 { summary += ", \(clashed) skipped because their fields' ids are already in use" }
            if failed > 0 { summary += ", \(failed) failed" }
            alert("Vault imported", summary + ".")
        } catch {
            alert("Import failed", "\(error)")
        }
    }

    // MARK: Prompts

    private static func askPassphrase(confirm: Bool, message: String) -> String? {
        var message = message
        while true {
            let first = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            first.placeholderString = "Passphrase"
            let second = NSSecureTextField(frame: first.frame)
            second.placeholderString = "Repeat passphrase"
            let stack = NSStackView(views: confirm ? [first, second] : [first])
            stack.orientation = .vertical
            stack.spacing = 8
            stack.frame = NSRect(x: 0, y: 0, width: 260, height: confirm ? 56 : 24)

            let a = NSAlert()
            a.messageText = confirm ? "Export Vault" : "Import Vault"
            a.informativeText = message
            a.accessoryView = stack
            a.addButton(withTitle: confirm ? "Export" : "Import")
            a.addButton(withTitle: "Cancel")
            a.window.initialFirstResponder = first
            guard a.runModal() == .alertFirstButtonReturn else { return nil }
            if !confirm { return first.stringValue }
            if first.stringValue.count < 12 { message = "Too short: use at least 12 characters." }
            else if first.stringValue != second.stringValue { message = "Passphrases do not match." }
            else { return first.stringValue }
        }
    }

    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
