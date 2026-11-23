import CryptoKit
import Foundation

/// Keeps secret metadata in memory and mirrors it to
/// ~/Library/Application Support/Keynod/vault.json.
/// Concealed values never touch disk here — they live in the Keychain via `Vault`.
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var items: [Secret] = []
    /// False when `vault.json` has no valid seal (see `VaultSeal`): the command
    /// line then releases nothing until the user confirms the vault in the app.
    @Published private(set) var trusted = true
    /// Why the seal key is unavailable, if it is.
    private(set) var sealProblem: String?

    let fileURL: URL
    private var pendingSave: DispatchWorkItem?
    private let sealKey: SymmetricKey?

    /// `KEYNOD_DATA_DIR` (Debug builds only, or test builds compiled with
    /// KEYNOD_ALLOW_DATA_DIR) points the app and the command at a throwaway folder.
    /// A Release build ignores it, so a second copy can't be started on a
    /// prepared folder.
    static var dataDirOverride: String? {
        #if DEBUG || KEYNOD_ALLOW_DATA_DIR
        return ProcessInfo.processInfo.environment["KEYNOD_DATA_DIR"]
        #else
        return nil
        #endif
    }

    /// Shared with the CLI, which must not create or load the store. Built from
    /// the account's home folder, not `HOME` or `CFFIXED_USER_HOME`.
    static var dataDir: URL {
        if let override = dataDirOverride { return URL(fileURLWithPath: override) }
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Keynod", isDirectory: true)
    }

    private init() {
        Self.makeDataDir()
        fileURL = Self.dataDir.appendingPathComponent("vault.json")
        // A file written by an older build may still be world-readable.
        if FileManager.default.fileExists(atPath: fileURL.path) { chmod(fileURL.path, 0o600) }
        do {
            sealKey = try VaultSealKey.key.loadOrCreate().key
        } catch {
            sealKey = nil
            sealProblem = "\(error)"
            NSLog("%@", "Keynod: no vault seal key: \(error)")
        }
        load()
    }

    /// The user confirmed (with Touch ID, in the app) that the secrets listed are theirs.
    func trustCurrentVault() {
        trusted = true
        saveNow()
    }

    /// Creates the data folder readable by this user only (0700). A folder
    /// that already exists is left as it is here; the CLI server tightens it.
    static func makeDataDir() {
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    // MARK: Queries

    func secret(_ id: UUID) -> Secret? { items.first { $0.id == id } }

    /// All secrets, sorted alphabetically by title.
    var secrets: [Secret] {
        items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Another secret with the same website host and username as this one.
    func duplicateLogin(of id: UUID) -> Secret? {
        guard let me = secret(id)?.loginIdentity else { return nil }
        return secrets.first { $0.id != id && $0.loginIdentity.map { $0 == me } == true }
    }

    // MARK: Mutations

    func update(_ id: UUID, text: String) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].text != text else { return }
        items[i].text = text
        items[i].updatedAt = Date()
        scheduleSave()
    }

    func delete(_ id: UUID) {
        if let item = secret(id) {
            for field in item.fields where field.concealed { try? Vault.delete(field.id) }
        }
        items.removeAll { $0.id == id }
        scheduleSave()
    }

    /// Concealed `values` (keyed by field id) go to the Vault first; if any
    /// write fails nothing is added.
    @discardableResult
    func addSecret(title: String, fields: [SecretField], values: [UUID: Data] = [:]) throws -> Secret {
        try insertSecret(Secret(title: title, fields: fields), values: values)
    }

    /// Adds an existing secret (backup import) with its concealed values.
    @discardableResult
    func insertSecret(_ secret: Secret, values: [UUID: Data]) throws -> Secret {
        var secret = secret
        var written: [UUID] = []
        do {
            for (fieldID, data) in values where secret.fields.contains(where: { $0.id == fieldID && $0.concealed }) {
                try Vault.set(data, for: fieldID)
                written.append(fieldID)
            }
            for id in written { if let j = secret.fields.firstIndex(where: { $0.id == id }) { secret.fields[j].hasValue = true } }
        } catch {
            written.forEach { try? Vault.delete($0) }
            throw error
        }
        items.append(secret)
        scheduleSave()
        return secret
    }

    func addField(_ field: SecretField, value: Data? = nil, to id: UUID) throws {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var field = field
        if field.concealed, let value { try Vault.set(value, for: field.id); field.hasValue = true }
        items[i].fields.append(field)
        touch(i)
    }

    /// Plain metadata only: label, and the value of a non-concealed field.
    func updateField(_ fieldID: UUID, in id: UUID, label: String? = nil, plainValue: String? = nil) {
        guard let i = items.firstIndex(where: { $0.id == id }),
              let j = items[i].fields.firstIndex(where: { $0.id == fieldID }) else { return }
        if let label { items[i].fields[j].label = label }
        if let plainValue, !items[i].fields[j].concealed { items[i].fields[j].value = plainValue }
        touch(i)
    }

    /// Writes a concealed value straight to the Vault; it never touches `vault.json`.
    func setConcealedValue(_ data: Data, fieldID: UUID, in id: UUID, filename: String? = nil) throws {
        guard let i = items.firstIndex(where: { $0.id == id }),
              let j = items[i].fields.firstIndex(where: { $0.id == fieldID && $0.concealed }) else { return }
        try Vault.set(data, for: fieldID)
        items[i].fields[j].hasValue = true
        if let filename { items[i].fields[j].filename = filename }
        touch(i)
    }

    func removeField(_ fieldID: UUID, from id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }),
              let j = items[i].fields.firstIndex(where: { $0.id == fieldID }) else { return }
        if items[i].fields[j].concealed { try? Vault.delete(fieldID) }
        items[i].fields.remove(at: j)
        touch(i)
    }

    private func touch(_ i: Int) {
        items[i].updatedAt = Date()
        scheduleSave()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let opened = VaultSeal.open(data, key: sealKey)
        if let decoded = try? decoder.decode([Secret].self, from: opened.list) {
            items = decoded
            trusted = VaultSeal.trusted(sealed: opened.sealed, secretCount: decoded.count)
            if !trusted { NSLog("%@", "Keynod: vault.json has no valid seal; the command line releases nothing until it is confirmed") }
        } else {
            // Never overwrite a file we couldn't read; keep a copy aside.
            let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            chmod(backup.path, 0o600)
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let list = try? encoder.encode(items) else { return }
        // Sealed only while trusted: an unconfirmed vault stays unconfirmed on disk too.
        let data = trusted ? sealKey.map { VaultSeal.seal(list, key: $0) } ?? list : list
        // Titles, usernames and Key IDs: readable by this user only.
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else { return }
        chmod(fileURL.path, 0o600)
    }
}
