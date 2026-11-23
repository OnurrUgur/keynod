import AppKit
import CloudKit
import CryptoKit
import Foundation
import IOKit.pwr_mgt
import LocalAuthentication
import Security

/// What one CLI request wants approved. Built by CLIServer.
struct ApprovalAsk {
    /// "run", "inject", "get", "create" or "delete".
    var kind: String
    /// The Touch ID dialog text.
    var reason: String
    /// e.g. "claude ← zsh".
    var who: String
    /// e.g. "keynod run -- fastlane beta".
    var command: String
    /// Working directory, home shortened to "~".
    var cwd: String
    /// e.g. "App Store Connect: Private Key, Issuer ID".
    var summary: String
    /// Concealed fields the approval releases; empty for create/delete.
    var fields: [(id: UUID, secret: String, label: String)]
    /// The command and summary uncut, for the iPhone's copy (redacted, then shortened).
    var fullCommand: CommandText
    var fullSummary: String
}

/// A request that is waiting on the iPhone. `close()` withdraws it.
final class PhoneAsk {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var current: UUID?
    private var closed = false

    fileprivate init() {}

    fileprivate func attach(_ task: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        if closed { task.cancel() } else { self.task = task }
    }

    fileprivate func track(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        current = id
        return true
    }

    func close() {
        lock.lock()
        closed = true
        let task = self.task, id = current
        self.task = nil
        lock.unlock()
        task?.cancel()
        if let id { Task.detached { await LinkCloud.shared.delete([Link.requestName(id), Link.responseName(id)]) } }
    }
}

private enum LinkKeychain {
    private static func query(_ service: String, _ account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    static func save(_ data: Data, service: String, account: String) throws {
        var item = query(service, account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query(service, account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw Vault.Failure(status: status) }
    }

    static func load(service: String, account: String) throws -> Data? {
        var item = query(service, account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Vault.Failure(status: status) }
        return data
    }

    static func exists(service: String, account: String) -> Bool {
        SecItemCopyMatching(query(service, account) as CFDictionary, nil) == errSecSuccess
    }

    static func delete(service: String, account: String) {
        let status = SecItemDelete(query(service, account) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            NSLog("%@", "Keynod iPhone: could not delete a keychain item (\(status))")
        }
    }

    static func deleteAll(service: String) {
        var item = query(service)
        item[kSecReturnAttributes as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        if SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let rows = result as? [[String: Any]] {
            for row in rows {
                if let account = row[kSecAttrAccount as String] as? String { delete(service: service, account: account) }
            }
        }
        SecItemDelete(query(service) as CFDictionary)
    }
}

/// The Mac's side of the iPhone link: pairing, protected copies of concealed
/// values, remote mode sync, and asking the phone.
final class PhoneLink {
    static let shared = PhoneLink()

    /// Digest of the pairing reply this Mac accepted, per offer, for the ack.
    private let pairingLock = NSLock()
    private var acceptedReplies: [UUID: Data] = [:]

    static let didChange = Notification.Name("KeynodPhoneLinkDidChange")

    private enum Service {
        private static let prefix = AppIdentity.bundleID
        static let link = prefix + ".link"
        static let remote = prefix + ".remote"
    }

    private enum Account {
        static let macKey = "mac-key"
        static let phone = "phone"
        static let mode = "mode"
    }

    static let macName = Host.current().localizedName ?? "Mac"

    private let lock = NSLock()
    private var cachedPhone: PairedPhone?
    private var phoneLoaded = false
    private var asleep = false
    private var sleeps = 0
    private var preparing = 0
    private var touched: Set<UUID> = []

    private let signerLock = NSLock()
    private var cachedSigner: LinkSigner?

    private var cachedMode: LinkMode?
    private var modeLoaded = false

    private var awakeUntil: Date?
    private var awakeDirty = false
    private var awakeFlushing = false

    private var ranCommands: Set<UUID> = []

    private let awakeLock = NSLock()
    private var awakeAssertion = IOPMAssertionID(kIOPMNullAssertionID)

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.sleepChanged(to: true)
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.sleepChanged(to: false)
        }
        if LinkCloud.shared.isConfigured {
            Task.detached { [weak self] in await self?.syncModeForever() }
            Task.detached(priority: .utility) { [weak self] in await self?.cleanUpForever() }
        }
    }

    private func sleepChanged(to asleep: Bool) {
        lock.withLock {
            self.asleep = asleep
            if asleep { sleeps += 1 }
        }
    }

    private func sleepCount() -> Int { lock.withLock { sleeps } }

    private func notifyChange() {
        refreshKeepAwake()
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }

    // MARK: Mac signing key

    func macSigner() throws -> LinkSigner {
        try signerLock.withLock {
            if let cachedSigner { return cachedSigner }
            let signer: LinkSigner
            if let blob = try LinkKeychain.load(service: Service.link, account: Account.macKey) {
                if let loaded = Self.signer(from: blob) {
                    signer = loaded
                } else {
                    NSLog("Keynod iPhone: saved signing key unusable; creating a new one")
                    signer = try Self.makeSigner()
                }
            } else {
                signer = try Self.makeSigner()
            }
            cachedSigner = signer
            return signer
        }
    }

    private static func signer(from blob: Data) -> LinkSigner? {
        guard let tag = blob.first else { return nil }
        let body = Data(blob.dropFirst())
        switch tag {
        case 0x01: return try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: body)
        case 0x02: return try? P256.Signing.PrivateKey(rawRepresentation: body)
        default: return nil
        }
    }

    private static func makeSigner() throws -> LinkSigner {
        var blob = Data(), signer: LinkSigner?
        if SecureEnclave.isAvailable {
            do {
                var error: Unmanaged<CFError>?
                guard let access = SecAccessControlCreateWithFlags(
                    nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error
                ) else { throw error!.takeRetainedValue() }
                let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
                blob = Data([0x01]) + key.dataRepresentation
                signer = key
            } catch {
                NSLog("%@", "Keynod iPhone: no Secure Enclave key (\(error)); using a software key")
            }
        }
        if signer == nil {
            let key = P256.Signing.PrivateKey()
            blob = Data([0x02]) + key.rawRepresentation
            signer = key
        }
        try LinkKeychain.save(blob, service: Service.link, account: Account.macKey)
        return signer!
    }

    // MARK: Pairing state

    var phone: PairedPhone? { lock.withLock { loadedPhone() } }
    var isPaired: Bool { phone != nil }

    private func loadedPhone() -> PairedPhone? {
        if phoneLoaded { return cachedPhone }
        do {
            if let data = try LinkKeychain.load(service: Service.link, account: Account.phone) {
                cachedPhone = try LinkCoding.decode(PairedPhone.self, from: data)
            }
            phoneLoaded = true
        } catch is LinkError {
            NSLog("Keynod iPhone: saved pairing is unreadable; treating Mac as unpaired")
            phoneLoaded = true
        } catch {
            NSLog("%@", "Keynod iPhone: could not read pairing: \(error)")
        }
        return cachedPhone
    }

    private func savePhone(_ phone: PairedPhone) throws {
        try lock.withLock {
            try LinkKeychain.save(try LinkCoding.encode(phone), service: Service.link, account: Account.phone)
            cachedPhone = phone
            phoneLoaded = true
        }
    }

    func unpair() {
        lock.withLock {
            LinkKeychain.delete(service: Service.link, account: Account.phone)
            LinkKeychain.deleteAll(service: Service.remote)
            LinkKeychain.delete(service: Service.link, account: Account.mode)
            cachedPhone = nil
            phoneLoaded = true
            cachedMode = nil
            modeLoaded = true
        }
        notifyChange()
    }

    // MARK: Remote mode

    var isRemote: Bool { isPaired && (mode?.remote ?? false) }
    var mode: LinkMode? { lock.withLock { loadedMode() } }

    private func loadedMode() -> LinkMode? {
        if modeLoaded { return cachedMode }
        if let data = try? LinkKeychain.load(service: Service.link, account: Account.mode) {
            cachedMode = try? LinkCoding.decode(LinkMode.self, from: data)
            modeLoaded = true
        }
        return cachedMode
    }

    @discardableResult
    private func apply(_ mode: LinkMode) -> Bool {
        let applied: Bool = lock.withLock {
            if let current = loadedMode(), current.at >= mode.at { return false }
            guard (try? LinkKeychain.save(try LinkCoding.encode(mode), service: Service.link, account: Account.mode)) != nil else {
                return false
            }
            cachedMode = mode
            modeLoaded = true
            return true
        }
        if applied { notifyChange() }
        return applied
    }

    func setRemote(_ on: Bool) {
        let mode = LinkMode(remote: on, at: Date(), by: "mac")
        guard isPaired, apply(mode) else { return }
        Task.detached {
            do {
                let signed = try LinkFlow.makeMode(remote: mode.remote, by: mode.by, now: mode.at, signer: try self.macSigner())
                let record = LinkCloud.shared.newRecord(Link.RecordType.mode, Link.modeName)
                record[Link.Field.payload] = signed.payload
                record[Link.Field.signature] = signed.signature
                try await LinkCloud.shared.put(record)
            } catch {
                NSLog("%@", "Keynod iPhone: could not send remote mode to iCloud: \(error)")
            }
        }
    }

    // MARK: Stay awake

    func publishAwake(until: Date?) {
        lock.withLock {
            awakeUntil = until
            awakeDirty = true
        }
        guard LinkCloud.shared.isConfigured else { return }
        Task.detached { [self] in await flushAwake() }
    }

    func finishPublishingAwake(timeout: TimeInterval = 2) {
        guard LinkCloud.shared.isConfigured else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, lock.withLock({ (awakeDirty && loadedPhone() != nil) || awakeFlushing }) {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func flushAwake() async {
        while true {
            var until: Date?
            let claimed: Bool = lock.withLock {
                guard awakeDirty, !awakeFlushing, loadedPhone() != nil else { return false }
                awakeDirty = false
                awakeFlushing = true
                until = awakeUntil
                return true
            }
            guard claimed else { return }
            var failed = false
            do {
                let signed = try LinkFlow.makeAwake(until: until, signer: try macSigner())
                let record = LinkCloud.shared.newRecord(Link.RecordType.awake, Link.awakeName)
                record[Link.Field.payload] = signed.payload
                record[Link.Field.signature] = signed.signature
                try await LinkCloud.shared.put(record)
            } catch {
                failed = true
                NSLog("%@", "Keynod iPhone: could not send stay-awake state to iCloud: \(error)")
            }
            let again: Bool = lock.withLock {
                awakeFlushing = false
                if failed { awakeDirty = true; return false }
                return awakeDirty
            }
            if !again { return }
        }
    }

    private func syncMode(from records: [CKRecord], phone: PairedPhone, mac: LinkSigner) {
        guard let record = records.first(where: { $0.recordID.recordName == Link.modeName }),
              let payload = record.data(Link.Field.payload), let signature = record.data(Link.Field.signature) else { return }
        let keys = [phone.denyKey, phone.approveKey, mac.signingPublicKey.x963Representation]
        do {
            apply(try LinkFlow.checkMode(payload: payload, signature: signature, keys: keys))
        } catch {
            NSLog("%@", "Keynod iPhone: ignoring remote mode record that didn't verify: \(error)")
        }
    }

    private func syncModeForever() async {
        while true {
            refreshKeepAwake()
            await flushAwake()
            if let phone, let mac = try? macSigner(), let records = try? await listZone() {
                syncMode(from: records, phone: phone, mac: mac)
                await runCommands(in: records, phone: phone)
            }
            try? await Task.sleep(for: .seconds(10))
        }
    }

    private func listZone() async throws -> [CKRecord] {
        guard let db = LinkCloud.shared.database else { return [] }
        let keys = [Link.Field.payload, Link.Field.signature]
        var records: [CKRecord] = []
        var token: CKServerChangeToken?
        while true {
            let changes: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>],
                          deletions: [CKDatabase.RecordZoneChange.Deletion],
                          changeToken: CKServerChangeToken, moreComing: Bool)
            do {
                changes = try await db.recordZoneChanges(inZoneWith: LinkCloud.shared.zoneID, since: token, desiredKeys: keys)
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                return []
            }
            for result in changes.modificationResultsByID.values {
                if case .success(let modification) = result { records.append(modification.record) }
            }
            token = changes.changeToken
            if !changes.moreComing { return records }
        }
    }

    // MARK: Keep awake

    func refreshKeepAwake() {
        awakeLock.withLock {
            let want = isRemote
            let holding = awakeAssertion != IOPMAssertionID(kIOPMNullAssertionID)
            if want && !holding {
                var id = IOPMAssertionID(kIOPMNullAssertionID)
                let status = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                         IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                         "Keynod remote mode" as CFString, &id)
                if status == kIOReturnSuccess {
                    awakeAssertion = id
                } else {
                    NSLog("%@", "Keynod iPhone: could not keep Mac awake (\(status))")
                }
            } else if !want && holding {
                IOPMAssertionRelease(awakeAssertion)
                awakeAssertion = IOPMAssertionID(kIOPMNullAssertionID)
            }
        }
    }

    // MARK: Commands from the iPhone

    private func runCommands(in records: [CKRecord], phone: PairedPhone) async {
        for record in records where record.recordType == Link.RecordType.command {
            var command: LinkCommand?
            if let payload = record.data(Link.Field.payload), let signature = record.data(Link.Field.signature) {
                do {
                    command = try LinkFlow.checkCommand(payload: payload, signature: signature, phone: phone)
                } catch {
                    NSLog("%@", "Keynod iPhone: dropped command that didn't verify: \(error)")
                }
            }
            await LinkCloud.shared.delete([record.recordID.recordName])
            guard let command, lock.withLock({ ranCommands.insert(command.id).inserted }) else { continue }
            perform(command.action)
        }
    }

    private func perform(_ action: String) {
        switch action {
        case "lock":
            if !Self.lockScreen() { Self.runTool("/usr/bin/pmset", ["displaysleepnow"]) }
        case "sleep":
            Self.runTool("/usr/bin/pmset", ["sleepnow"])
        case "awake-on":
            Task { @MainActor in StayAwake.shared.turnOn() }
        case "awake-off":
            Task { @MainActor in StayAwake.shared.turnOff() }
        default:
            NSLog("%@", "Keynod iPhone: ignored unknown command (\(action.prefix(24)))")
        }
    }

    private static func lockScreen() -> Bool {
        guard let library = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY) else {
            return false
        }
        defer { dlclose(library) }
        guard let symbol = dlsym(library, "SACLockScreenImmediate") else { return false }
        typealias LockScreen = @convention(c) () -> Int32
        return unsafeBitCast(symbol, to: LockScreen.self)() == 0
    }

    private static func runTool(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { NSLog("%@", "Keynod iPhone: could not run \(path): \(error)") }
    }

    // MARK: Cleanup

    @discardableResult
    func cleanUp() async -> Int {
        guard await LinkCloud.shared.isAvailable(), let records = try? await LinkCloud.shared.all() else { return 0 }
        let items = records.map {
            LinkCleanup.Item(name: $0.recordID.recordName, expires: $0.date(Link.Field.expires), created: $0.creationDate)
        }
        let stale = LinkCleanup.stale(items)
        if !stale.isEmpty {
            await LinkCloud.shared.delete(stale)
            NSLog("%@", "Keynod iPhone: removed \(stale.count) leftover iCloud record(s)")
        }
        return stale.count
    }

    static func cleanUpIfRequested() {
        guard ProcessInfo.processInfo.environment["KEYNOD_LINK_CLEANUP"] != nil else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let records = (try? await LinkCloud.shared.all()) ?? []
            for record in records.sorted(by: { $0.recordID.recordName < $1.recordID.recordName }) {
                let created = record.creationDate.map { ISO8601DateFormatter().string(from: $0) } ?? "?"
                print("\(record.recordID.recordName)  \(record.recordType)  created \(created)")
            }
            print("removed \(await shared.cleanUp()) of \(records.count) record(s)")
            done.signal()
        }
        done.wait()
        exit(0)
    }

    private func cleanUpForever() async {
        try? await Task.sleep(for: .seconds(20))
        while true {
            await cleanUp()
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    // MARK: Protected copies

    func didStore(_ value: Data, field: UUID) {
        lock.withLock {
            if preparing > 0 { touched.insert(field) }
            if let phone = loadedPhone() { _ = writeCopy(value, field: field, phone: phone) }
        }
    }

    func didDelete(field: UUID) {
        lock.withLock {
            if preparing > 0 { touched.insert(field) }
            LinkKeychain.delete(service: Service.remote, account: field.uuidString)
        }
    }

    func copy(of field: UUID) -> LinkCrypto.Protected? {
        guard let data = try? LinkKeychain.load(service: Service.remote, account: field.uuidString) else { return nil }
        return try? LinkCoding.decode(LinkCrypto.Protected.self, from: data)
    }

    func open(field: UUID, key: SymmetricKey) throws -> Data {
        guard let protected = copy(of: field) else { throw LinkError.badKey }
        return try LinkCrypto.open(protected, field: field, key: key)
    }

    func removeAllCopies() {
        lock.withLock { LinkKeychain.deleteAll(service: Service.remote) }
    }

    private func writeCopy(_ value: Data, field: UUID, phone: PairedPhone) -> Bool {
        do {
            let protected = try LinkCrypto.protect(value, field: field, for: try LinkCrypto.agreementKey(phone.fieldKey))
            try LinkKeychain.save(try LinkCoding.encode(protected), service: Service.remote, account: field.uuidString)
            return true
        } catch {
            LinkKeychain.delete(service: Service.remote, account: field.uuidString)
            NSLog("%@", "Keynod iPhone: could not prepare a field for iPhone approval: \(error)")
            return false
        }
    }

    func prepareCopies(context: LAContext) async -> (prepared: Int, skipped: Int) {
        let ids = await MainActor.run {
            Store.shared.secrets.flatMap { $0.fields.filter(\.concealed).map(\.id) }
        }
        lock.withLock {
            if preparing == 0 { touched.removeAll() }
            preparing += 1
        }
        defer {
            lock.withLock {
                preparing -= 1
                if preparing == 0 { touched.removeAll() }
            }
        }

        var prepared = 0, skipped = 0
        for (index, id) in ids.enumerated() {
            if Task.isCancelled { skipped += ids.count - index; break }
            let value: Data
            do {
                value = try Vault.get(id, reason: "prepare secrets for iPhone approval", context: context)
            } catch {
                skipped += 1
                if let failure = error as? Vault.Failure, failure.status == errSecItemNotFound { continue }
                NSLog("%@", "Keynod iPhone: could not read a field to prepare it: \(error)")
                if Self.isAuthFailure(error) { skipped += ids.count - index - 1; break }
                continue
            }
            if storePrepared(value, field: id) { prepared += 1 } else { skipped += 1 }
        }
        return (prepared, skipped)
    }

    private func storePrepared(_ value: Data, field: UUID) -> Bool {
        lock.withLock {
            if touched.contains(field) { return LinkKeychain.exists(service: Service.remote, account: field.uuidString) }
            guard let phone = loadedPhone() else { return false }
            return writeCopy(value, field: field, phone: phone)
        }
    }

    private static func isAuthFailure(_ error: Error) -> Bool {
        if error is LAError { return true }
        guard let failure = error as? Vault.Failure else { return false }
        return [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed].contains(failure.status)
    }

    // MARK: Pairing

    func makeOffer() throws -> PairOffer {
        PairOffer(macName: Self.macName, macKey: try macSigner().signingPublicKey.x963Representation,
                  secret: LinkCrypto.randomBytes(32), expires: Date().addingTimeInterval(Link.pairingTTL))
    }

    func waitForReply(to offer: PairOffer) async throws -> (reply: PairReply, code: String) {
        try await LinkCloud.shared.ensureZone()
        while true {
            try Task.checkCancellation()
            guard Date() < offer.expires else { throw LinkError.expired }
            do {
                if let record = try await LinkCloud.shared.fetch(Link.pairingName(offer.id)),
                   let payload = record.data(Link.Field.payload), let mac = record.data(Link.Field.mac) {
                    let checked = try LinkFlow.checkPairReply(payload: payload, mac: mac, offer: offer)
                    // The ack names this exact reply, so the phone can tell if it was swapped.
                    pairingLock.withLock { acceptedReplies[offer.id] = LinkFlow.pairReplyDigest(payload) }
                    return checked
                }
            } catch let error as CKError where Self.isTransient(error) {
            }
            try await Self.pause(Link.pollInterval)
        }
    }

    func completePairing(offer: PairOffer, reply: PairReply,
                         context: LAContext) async throws -> (prepared: Int, skipped: Int) {
        try savePhone(PairedPhone(reply: reply))
        do {
            removeAllCopies()
            let result = await prepareCopies(context: context)
            try Task.checkCancellation()
            try await Task.detached { try await self.sendAck(for: offer, accepted: true) }.value
            notifyChange()
            return result
        } catch {
            unpair()
            throw error
        }
    }

    func rejectPairing(_ offer: PairOffer) async {
        do { try await sendAck(for: offer, accepted: false) } catch { NSLog("%@", "Keynod iPhone: could not send rejection: \(error)") }
    }

    private func sendAck(for offer: PairOffer, accepted: Bool) async throws {
        let reply = pairingLock.withLock { acceptedReplies.removeValue(forKey: offer.id) }
        guard reply != nil || !accepted else { throw LinkError.wrongRequest }
        let payload = try LinkCoding.encode(PairAck(pairing: offer.id, accepted: accepted, reply: reply))
        let record = LinkCloud.shared.newRecord(Link.RecordType.pairingAck, Link.pairingAckName(offer.id))
        record[Link.Field.payload] = payload
        record[Link.Field.signature] = try macSigner().sign(payload)
        try await LinkCloud.shared.create(record)
    }

    // MARK: Asking the phone

    func ask(_ ask: ApprovalAsk, race: ApprovalRace<CLIApproval>) -> PhoneAsk? {
        guard LinkCloud.shared.isConfigured, let phone = self.phone else { return nil }
        var seen = Set<UUID>()
        var ask = ask
        ask.fields = ask.fields.filter { seen.insert($0.id).inserted }
        guard ask.fields.allSatisfy({ LinkKeychain.exists(service: Service.remote, account: $0.id.uuidString) }) else {
            return nil
        }
        let handle = PhoneAsk()
        handle.attach(Task.detached(priority: .userInitiated) { [self] in
            await run(ask, phone: phone, race: race, handle: handle)
        })
        return handle
    }

    private func run(_ ask: ApprovalAsk, phone: PairedPhone, race: ApprovalRace<CLIApproval>, handle: PhoneAsk) async {
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Waiting for an iPhone approval")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        asking: while !Task.isCancelled, !race.isDecided {
            guard let slept = await awaitWake(race) else { return }

            let waiting: LinkWaiting
            do { waiting = try makeWaiting(for: ask) } catch { fail(error, race); return }
            let id = waiting.request.id
            let names = [Link.requestName(id), Link.responseName(id)]
            guard handle.track(id) else { return }
            do {
                try await write(waiting, giveUp: { Task.isCancelled || race.isDecided })
            } catch {
                await withdraw(names)
                fail(error, race)
                return
            }

            while true {
                try? await Self.pause(Link.pollInterval)
                if Task.isCancelled || race.isDecided {
                    await withdraw(names)
                    return
                }
                if sleepCount() != slept {
                    await withdraw(names)
                    continue asking
                }
                guard self.phone == phone else {
                    await withdraw(names)
                    race.stepAside(.phone, because: LinkError.malformed("the iPhone was unpaired"))
                    return
                }
                guard Date() < waiting.request.expires else {
                    await withdraw(names)
                    race.stepAside(.phone, because: LinkError.expired)
                    return
                }
                let record: CKRecord?
                do { record = try await LinkCloud.shared.fetch(Link.responseName(id)) } catch { continue }
                guard let record, let payload = record.data(Link.Field.payload),
                      let signature = record.data(Link.Field.signature) else { continue }
                if sleepCount() != slept {
                    await withdraw(names)
                    continue asking
                }
                do {
                    switch try LinkFlow.checkResponse(payload: payload, signature: signature, for: waiting, phone: phone) {
                    case .approved(let keys): race.approve(.phone(keys), by: .phone)
                    case .denied: race.deny(LinkError.denied, by: .phone)
                    case .answered: throw LinkError.wrongRequest
                    }
                    await withdraw(names)
                    return
                } catch {
                    NSLog("%@", "Keynod iPhone: ignored an answer that didn't verify: \(error)")
                    await withdraw([Link.responseName(id)])
                }
            }
        }
    }

    private func fail(_ error: Error, _ race: ApprovalRace<CLIApproval>) {
        NSLog("%@", "Keynod iPhone: iPhone request failed: \(error)")
        race.stepAside(.phone, because: error is CKError ? LinkError.malformed(Self.cliMessage(for: error)) : error)
    }

    private func awaitWake(_ race: ApprovalRace<CLIApproval>) async -> Int? {
        while !Task.isCancelled, !race.isDecided {
            if let count = lock.withLock({ asleep ? nil : sleeps }) { return count }
            try? await Self.pause(1)
        }
        return nil
    }

    private func makeWaiting(for ask: ApprovalAsk) throws -> LinkWaiting {
        var items: [LinkRequest.Item] = []
        for field in ask.fields {
            guard let copy = copy(of: field.id) else { throw LinkError.badKey }
            items.append(LinkRequest.Item(field: field.id, secret: field.secret, label: field.label, eph: copy.eph))
        }
        // This copy goes to iCloud and a push notification. Built from the uncut texts:
        // sanitized, then secrets replaced, then shortened, so none can straddle a cut
        // (the Touch ID text on the Mac keeps the command as it is).
        return try LinkFlow.makeRequest(macName: Self.macName, kind: ask.kind, who: ask.who,
                                        command: ApprovalText.phoneCommand(ask.fullCommand, redact: { CLIServer.redacted($0) }),
                                        cwd: ask.cwd,
                                        summary: ApprovalText.phoneSummary(ask.fullSummary, redact: KeyCatcher.redact),
                                        items: items, signer: try macSigner())
    }

    func write(_ waiting: LinkWaiting, images: [Data] = [], giveUp: () -> Bool) async throws {
        let request = waiting.request
        var tempFiles: [URL] = []
        defer { tempFiles.forEach { try? FileManager.default.removeItem(at: $0) } }
        let record = LinkCloud.shared.newRecord(Link.RecordType.request, Link.requestName(request.id))
        record[Link.Field.payload] = waiting.payload
        record[Link.Field.signature] = waiting.signature
        record[Link.Field.title] = request.pushTitle
        record[Link.Field.subtitle] = request.pushSubtitle
        record[Link.Field.body] = request.pushBody
        record[Link.Field.expires] = request.expires
        for (n, data) in images.prefix(Link.maxImages).enumerated() {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("keynod-img-\(UUID().uuidString).jpg")
            guard (try? data.write(to: url, options: [.atomic, .completeFileProtection])) != nil else {
                throw LinkError.malformed("could not prepare a picture")
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            tempFiles.append(url)
            record[Link.Field.image(n)] = CKAsset(fileURL: url)
        }
        var attempt = 0
        while true {
            do {
                try await LinkCloud.shared.create(record)
                return
            } catch let error as CKError where error.code == .serverRecordChanged && attempt > 0 {
                return
            } catch where attempt < 3 && Self.isTransient(error) && !giveUp() {
                attempt += 1
                try await Self.pause(3)
            }
        }
    }

    func withdraw(_ names: [String]) async {
        await Task.detached { await LinkCloud.shared.delete(names) }.value
    }

    static func pause(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static func isTransient(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return false }
        switch error.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited,
             .zoneBusy, .serverResponseLost, .accountTemporarilyUnavailable:
            return true
        default:
            return false
        }
    }

    static func message(for error: Error) -> String { cliMessage(for: error) }

    static func cliMessage(for error: Error) -> String {
        if let error = error as? LinkError { return error.description }
        if let error = error as? CKError {
            switch error.code {
            case .notAuthenticated: return "Sign in to iCloud in System Settings, then try again."
            case .networkUnavailable, .networkFailure: return "iCloud can't be reached. Check your internet connection."
            case .missingEntitlement, .badContainer, .permissionFailure: return "Keynod isn't allowed to use its iCloud container."
            default: break
            }
        }
        return error.localizedDescription
    }
}
