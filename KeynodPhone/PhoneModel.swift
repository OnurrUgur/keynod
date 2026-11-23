import CloudKit
import LocalAuthentication
import SwiftUI
import UserNotifications

func phoneLog(_ message: String) { NSLog("Keynod: %@", message) }

extension String {
    var visibleText: String {
        String(unicodeScalars.compactMap { scalar -> Character? in
            switch scalar.value {
            case 0x09, 0x0A, 0x0D: return " "
            case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return nil
            default: return scalar.properties.generalCategory == .control ? nil : Character(scalar)
            }
        })
    }
}

@MainActor
final class PhoneModel: ObservableObject {
    static let shared = PhoneModel()

    struct PendingRequest: Identifiable, Equatable {
        let request: LinkRequest
        let payload: Data
        let recordName: String
        var images: [Data] = []
        var id: UUID { request.id }

        static func == (a: PendingRequest, b: PendingRequest) -> Bool {
            a.request == b.request && a.payload == b.payload && a.recordName == b.recordName
                && a.images.count == b.images.count
        }
    }

    private var imageCache: [UUID: [Data]] = [:]
    private var badImages: Set<UUID> = []

    enum PairingState: Equatable {
        case idle
        case starting
        case waitingForMac(code: String)
        case failed(String)
        case done
    }

    @Published private(set) var pairedMac: PairedMac?
    @Published private(set) var requests: [PendingRequest] = []
    @Published private(set) var pairing: PairingState = .idle
    @Published private(set) var pairingMacName: String?
    @Published private(set) var notificationsAllowed = true
    @Published private(set) var busy: Set<UUID> = []
    @Published var banner: String?
    @Published private(set) var notificationProblem: String?
    @Published private(set) var syncProblem: String?
    @Published var focusedRequest: UUID?
    @Published private(set) var mode: LinkMode?
    @Published private(set) var modeChanging = false
    @Published private(set) var awake: LinkAwake?
    @Published private(set) var commandSending = false

    private static let requestsSubscription = "keynod-requests"
    private static let closedSubscription = "keynod-requests-closed"
    private static let schemaKey = "KeynodRequestSchemaCreated.v1"
    private static let refreshInterval: Duration = .seconds(3)

    private var pollTask: Task<Void, Never>?
    private var pairingTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private var refreshRunning = false
    private var refreshAgain = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var refreshFailures = 0
    private var subscribing = false
    private var answered: Set<UUID> = []
    private var rejectedModeSignature: Data?
    private var rejectedAwakeSignature: Data?

    private init() {
        pairedMac = Self.storedMac()
    }

    private static func storedMac() -> PairedMac? {
        do {
            return try PhoneKeys.loadMac()
        } catch {
            phoneLog("couldn't read the pairing from the keychain: \(error)")
            return nil
        }
    }

    // MARK: Lifecycle

    func didBecomeActive() {
        if pairedMac == nil, pairing == .idle { pairedMac = Self.storedMac() }
        startPolling()
        guard pairedMac != nil else { return }
        Task {
            await requestNotificationPermission()
            if notificationProblem != nil { await ensureSubscriptions() }
        }
    }

    func didResignActive() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    // MARK: Reading iCloud

    func refresh() async {
        if refreshRunning {
            refreshAgain = true
            await withCheckedContinuation { refreshWaiters.append($0) }
            return
        }
        refreshRunning = true
        repeat {
            refreshAgain = false
            await Task { await self.readRequests() }.value
        } while refreshAgain
        refreshRunning = false
        let waiters = refreshWaiters
        refreshWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func readRequests() async {
        guard let mac = pairedMac else {
            if !requests.isEmpty { requests = [] }
            return
        }
        let startedAt = Date()
        let records: [CKRecord]
        do {
            records = try await Self.readZone()
        } catch {
            noteReadFailure(error)
            return
        }
        guard pairedMac == mac else { return }
        refreshFailures = 0
        syncProblem = nil

        adoptMode(from: records, mac: mac)
        adoptAwake(from: records, mac: mac)

        let now = Date()
        let responses = Set(records.filter { $0.recordType == Link.RecordType.response }.map(\.recordID.recordName))
        var open: [PendingRequest] = []
        var present: Set<UUID> = []
        for record in records where record.recordType == Link.RecordType.request {
            let name = record.recordID.recordName
            guard let id = Link.requestID(fromName: name) else { continue }
            present.insert(id)
            guard !answered.contains(id),
                  !responses.contains(Link.responseName(id)),
                  let payload = record.data(Link.Field.payload),
                  let signature = record.data(Link.Field.signature),
                  !badImages.contains(id) else { continue }
            let request: LinkRequest
            var images: [Data] = []
            do {
                request = try LinkFlow.checkRequest(payload: payload, signature: signature, mac: mac, now: now,
                                                    images: imageCache[id])
                images = imageCache[id] ?? []
            } catch LinkError.missingImages {
                guard let fetched = await Self.loadImages(name) else { continue }
                do {
                    request = try LinkFlow.checkRequest(payload: payload, signature: signature, mac: mac, now: now,
                                                        images: fetched)
                } catch {
                    badImages.insert(id)
                    phoneLog("dropped a request whose pictures didn't verify")
                    continue
                }
                imageCache[id] = fetched
                images = fetched
            } catch {
                continue
            }
            guard request.id == id else { continue }
            open.append(PendingRequest(request: request, payload: payload, recordName: name, images: images))
        }
        answered.formIntersection(present)
        imageCache = imageCache.filter { present.contains($0.key) }
        badImages.formIntersection(present)
        open.sort { ($0.request.created, $0.id.uuidString) > ($1.request.created, $1.id.uuidString) }
        if open != requests { requests = open }
        await removeStaleNotifications(open: Set(open.map(\.id)), deliveredBefore: startedAt)
    }

    private static func loadImages(_ recordName: String) async -> [Data]? {
        guard let record = try? await LinkCloud.shared.fetch(recordName) else { return nil }
        var images: [Data] = []
        for n in 0..<Link.maxImages {
            guard let url = (record[Link.Field.image(n)] as? CKAsset)?.fileURL else { break }
            guard let data = try? Data(contentsOf: url) else { return nil }
            images.append(data)
        }
        return images
    }

    private static func readZone() async throws -> [CKRecord] {
        guard let db = LinkCloud.shared.database else {
            throw LinkError.malformed("iCloud isn't configured in this build.")
        }
        var records: [CKRecord] = []
        var token: CKServerChangeToken?
        do {
            while true {
                let changes = try await db.recordZoneChanges(
                    inZoneWith: LinkCloud.shared.zoneID, since: token, desiredKeys: [Link.Field.payload, Link.Field.signature])
                for result in changes.modificationResultsByID.values {
                    if case .success(let modification) = result { records.append(modification.record) }
                }
                token = changes.changeToken
                if !changes.moreComing { return records }
            }
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            return []
        }
    }

    private func adoptMode(from records: [CKRecord], mac: PairedMac) {
        guard let record = records.first(where: { $0.recordType == Link.RecordType.mode }),
              let payload = record.data(Link.Field.payload),
              let signature = record.data(Link.Field.signature) else { return }
        var keys = [mac.macKey]
        if let own = try? PhoneKeys.denyKey().signingPublicKey.x963Representation { keys.append(own) }
        do {
            let incoming = try LinkFlow.checkMode(payload: payload, signature: signature, keys: keys)
            rejectedModeSignature = nil
            if let current = mode, incoming.at <= current.at { return }
            mode = incoming
        } catch {
            if rejectedModeSignature != signature {
                rejectedModeSignature = signature
                phoneLog("ignored a remote mode record that didn't verify: \(error)")
            }
        }
    }

    private func adoptAwake(from records: [CKRecord], mac: PairedMac) {
        guard let record = records.first(where: { $0.recordType == Link.RecordType.awake }),
              let payload = record.data(Link.Field.payload),
              let signature = record.data(Link.Field.signature) else { return }
        do {
            let incoming = try LinkFlow.checkAwake(payload: payload, signature: signature, macKey: mac.macKey)
            rejectedAwakeSignature = nil
            if let current = awake, incoming.at <= current.at { return }
            awake = incoming
        } catch {
            if rejectedAwakeSignature != signature {
                rejectedAwakeSignature = signature
                phoneLog("ignored a stay-awake record that didn't verify: \(error)")
            }
        }
    }

    private func noteReadFailure(_ error: Error) {
        if error is CancellationError { return }
        refreshFailures += 1
        if refreshFailures == 1 { phoneLog("couldn't read iCloud: \(error.localizedDescription)") }
        if refreshFailures >= 2 { syncProblem = Self.describe(error) }
    }

    private func removeStaleNotifications(open: Set<UUID>, deliveredBefore cutoff: Date) async {
        let center = UNUserNotificationCenter.current()
        let stale = await center.deliveredNotifications().compactMap { note -> String? in
            guard note.date < cutoff,
                  let id = Self.requestID(from: note.request.content.userInfo),
                  !open.contains(id) else { return nil }
            return note.request.identifier
        }
        if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
    }

    private func removeNotifications(for ids: Set<UUID>) {
        Task {
            let center = UNUserNotificationCenter.current()
            let matching = await center.deliveredNotifications().compactMap { note -> String? in
                guard let id = Self.requestID(from: note.request.content.userInfo), ids.contains(id) else { return nil }
                return note.request.identifier
            }
            if !matching.isEmpty { center.removeDeliveredNotifications(withIdentifiers: matching) }
        }
    }

    nonisolated static func requestID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard let note = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              let name = note.recordID?.recordName else { return nil }
        return Link.requestID(fromName: name)
    }

    // MARK: Approving, denying, and answering

    func approve(_ id: UUID) async { await respond(id, .approve) }
    func deny(_ id: UUID) async { await respond(id, .deny) }

    func answer(_ id: UUID, choice: String?, text: String?) async {
        let words = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (words?.isEmpty ?? true) ? nil : words
        guard choice != nil || text != nil else { return }
        await respond(id, .answer(choice: choice, text: text))
    }

    func startsFaceID(for id: UUID) -> Bool {
        requests.first { $0.id == id }?.request.needsFaceID ?? true
    }

    private enum Reply {
        case approve
        case deny
        case answer(choice: String?, text: String?)
    }

    private struct Verified {
        let request: LinkRequest
        let payload: Data
    }

    private enum AnswerError: Error {
        case notOpen, alreadyAnswered, changed, notActive
    }

    private func respond(_ id: UUID, _ reply: Reply) async {
        guard let mac = pairedMac, !busy.contains(id) else { return }
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            if case .approve = reply, !(await waitUntilActive()) { throw AnswerError.notActive }
            let open = try await fetchOpen(id, mac: mac)
            if let shown = requests.first(where: { $0.id == id }), shown.payload != open.payload {
                throw AnswerError.changed
            }
            let signed: (payload: Data, signature: Data)
            switch reply {
            case .approve:
                guard open.request.needsFaceID else { focus(id); return }
                signed = try await approval(for: open)
            case .deny:
                signed = try signedWithDenyKey { try LinkFlow.deny(open.request, payload: open.payload, denyKey: $0) }
            case .answer(let choice, let text):
                if let choice, let options = open.request.options, !options.contains(choice) {
                    throw LinkError.malformed("That answer isn't one of the options.")
                }
                signed = try signedWithDenyKey {
                    try LinkFlow.answer(open.request, payload: open.payload, choice: choice, text: text, signer: $0)
                }
            }
            let record = LinkCloud.shared.newRecord(Link.RecordType.response, Link.responseName(id))
            record[Link.Field.payload] = signed.payload
            record[Link.Field.signature] = signed.signature
            try await LinkCloud.shared.create(record)
            retire(id, answered: true)
            if case .deny = reply {} else { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            show(Self.doneText(reply, request: open.request))
        } catch {
            fail(error, id: id, reply: reply)
        }
    }

    private func fetchOpen(_ id: UUID, mac: PairedMac) async throws -> Verified {
        let cloud = LinkCloud.shared
        async let requestRecord = cloud.fetch(Link.requestName(id))
        async let responseRecord = cloud.fetch(Link.responseName(id))
        guard let record = try await requestRecord else { throw AnswerError.notOpen }
        if try await responseRecord != nil { throw AnswerError.alreadyAnswered }
        guard let payload = record.data(Link.Field.payload), let signature = record.data(Link.Field.signature) else {
            throw LinkError.malformed("The request is incomplete.")
        }
        let request = try LinkFlow.checkRequest(payload: payload, signature: signature, mac: mac, images: imageCache[id])
        guard request.id == id else { throw LinkError.wrongRequest }
        return Verified(request: request, payload: payload)
    }

    private func approval(for open: Verified) async throws -> (payload: Data, signature: Data) {
        let command = String(open.request.command.visibleText.prefix(120))
        let reason: String
        if open.request.kind == "permission" {
            let tool = command.hasPrefix("Permission: ") ? String(command.dropFirst("Permission: ".count)) : command
            reason = tool.isEmpty ? "Allow Claude tool" : "Allow Claude: \(tool)"
        } else {
            reason = command.isEmpty ? "Approve this request" : "Approve \(command)"
        }
        let context = LAContext()
        context.localizedFallbackTitle = ""
        defer { context.invalidate() }
        _ = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        guard Date() < open.request.expires else { throw LinkError.expired }
        let request = open.request
        let payload = open.payload
        return try await Task.detached {
            let fieldKey: LinkAgreer
            let approveKey: LinkSigner
            do {
                fieldKey = try PhoneKeys.fieldKey(context: context)
                approveKey = try PhoneKeys.approveKey(context: context)
            } catch let error as PhoneKeys.Failure {
                throw error
            } catch {
                throw PhoneKeys.Failure.unusableKeys
            }
            do {
                return try LinkFlow.approve(request, payload: payload, fieldKey: fieldKey, approveKey: approveKey)
            } catch let error as LinkError {
                throw error
            } catch {
                throw PhoneKeys.Failure.unusableKeys
            }
        }.value
    }

    private func signedWithDenyKey(
        _ make: (LinkSigner) throws -> (payload: Data, signature: Data)
    ) throws -> (payload: Data, signature: Data) {
        do {
            return try make(try PhoneKeys.denyKey())
        } catch let error as PhoneKeys.Failure {
            throw error
        } catch let error as LinkError {
            throw error
        } catch {
            throw PhoneKeys.Failure.unusableKeys
        }
    }

    private static func doneText(_ reply: Reply, request: LinkRequest) -> String {
        switch reply {
        case .approve:
            return request.kind == "permission" ? "Allowed — Claude continues" : "Approved — your Mac continues"
        case .deny:
            return request.kind == "reply" ? "Session stopped" : "Denied"
        case .answer(let choice, _):
            if request.kind == "reply" {
                return choice == "Stop" ? "Sent — session stopping" : "Sent — session continuing"
            }
            return "Sent"
        }
    }

    private func fail(_ error: Error, id: UUID, reply: Reply) {
        switch error {
        case AnswerError.notOpen:
            retire(id, answered: false)
            show("This request is no longer open")
        case AnswerError.alreadyAnswered:
            retire(id, answered: true)
            show("Already answered")
        case let error as CKError where error.code == .serverRecordChanged:
            retire(id, answered: true)
            show("Already answered")
        case AnswerError.changed:
            show("This request changed. Review it again.")
            Task { await refresh() }
        case AnswerError.notActive:
            show("Open Keynod to approve")
        case let error as LAError where [.userCancel, .systemCancel, .appCancel].contains(error.code):
            break
        case LinkError.expired:
            retire(id, answered: false)
            show("This request has expired")
        default:
            let verb: String
            switch reply {
            case .approve: verb = "approve"
            case .deny: verb = "deny"
            case .answer: verb = "answer"
            }
            phoneLog("couldn't \(verb) a request: \(error)")
            show("Couldn't \(verb): \(Self.describe(error))")
        }
    }

    private func retire(_ id: UUID, answered wasAnswered: Bool) {
        if wasAnswered { answered.insert(id) }
        requests.removeAll { $0.id == id }
        removeNotifications(for: [id])
    }

    private func waitUntilActive(timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while UIApplication.shared.applicationState != .active {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    func show(_ text: String) {
        banner = text
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    func focus(_ id: UUID) { focusedRequest = id }

    // MARK: Remote mode

    func setRemote(_ on: Bool) async {
        guard let mac = pairedMac, !modeChanging else { return }
        let previous = mode
        var applied: LinkMode?
        modeChanging = true
        defer { modeChanging = false }
        do {
            let key = try PhoneKeys.denyKey()
            let signed = try LinkFlow.makeMode(remote: on, by: "phone", signer: key)
            let change = try LinkFlow.checkMode(payload: signed.payload, signature: signed.signature,
                                                keys: [key.signingPublicKey.x963Representation])
            applied = change
            mode = change
            let record = LinkCloud.shared.newRecord(Link.RecordType.mode, Link.modeName)
            record[Link.Field.payload] = signed.payload
            record[Link.Field.signature] = signed.signature
            try await LinkCloud.shared.put(record)
            guard pairedMac == mac else { return }
            show(on ? "Remote mode on — your Mac will ask here" : "Remote mode off — your Mac will use Touch ID")
        } catch {
            phoneLog("couldn't change remote mode: \(error)")
            if let applied, mode == applied { mode = previous }
            show("Couldn't change remote mode: \(Self.describe(error))")
        }
    }

    // MARK: Mac commands

    var awakeUntil: Date? { awake?.activeUntil() }

    func sendCommand(_ action: String) async {
        guard pairedMac != nil, !commandSending else { return }
        commandSending = true
        defer { commandSending = false }
        do {
            let id = UUID()
            let signed = try signedWithDenyKey { signer in
                let made = try LinkFlow.makeCommand(action: action, id: id, signer: signer)
                return (made.payload, made.signature)
            }
            let record = LinkCloud.shared.newRecord(Link.RecordType.command, Link.commandName(id))
            record[Link.Field.payload] = signed.payload
            record[Link.Field.signature] = signed.signature
            try await LinkCloud.shared.create(record)
            switch action {
            case "lock": show("Locking your Mac")
            case "sleep": show("Putting your Mac to sleep")
            case "awake-on": show("Mac will stay awake overnight")
            case "awake-off": show("Mac can sleep again")
            default: show("Command sent")
            }
        } catch {
            phoneLog("couldn't send command to Mac: \(error)")
            show("Couldn't send command: \(Self.describe(error))")
        }
    }

    // MARK: Pairing

    private enum PairingFailure: Error { case declined, timedOut }

    func pair(qrText: String) {
        guard pairedMac == nil, pairingTask == nil else { return }
        pairingTask = Task { [weak self] in
            await self?.runPairing(qrText: qrText)
            self?.pairingTask = nil
        }
    }

    func cancelPairing() { pairingTask?.cancel() }

    func resetPairing() {
        guard pairingTask == nil else { return }
        pairing = .idle
        pairingMacName = nil
    }

    private func runPairing(qrText: String) async {
        pairing = .starting
        pairingMacName = nil
        var offer: PairOffer?
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        do {
            let parsed: PairOffer
            do {
                parsed = try PairOffer(qrText: qrText)
            } catch {
                throw Message("That isn't a Keynod pairing code. On your Mac open Keynod Settings → Pair iPhone….")
            }
            offer = parsed
            guard parsed.expires > Date() else {
                throw Message("This pairing code has expired. Show a new one on your Mac.")
            }
            guard parsed.expires.timeIntervalSinceNow <= Link.pairingTTL + Link.clockSkew else {
                throw Message("This pairing code isn't valid.")
            }
            if let problem = Self.biometryProblem() { throw Message(problem) }
            if let problem = await Self.iCloudProblem() { throw Message(problem) }
            pairingMacName = parsed.macName

            let keys = try PhoneKeys.createKeys()
            let reply = try LinkFlow.makePairReply(parsed, phoneName: UIDevice.current.name, approveKey: keys.approve,
                                                   fieldKey: keys.field, denyKey: keys.deny)
            let cloud = LinkCloud.shared
            try await cloud.ensureZone()
            await cloud.delete([Link.pairingName(parsed.id)])
            let record = cloud.newRecord(Link.RecordType.pairing, Link.pairingName(parsed.id))
            record[Link.Field.payload] = reply.payload
            record[Link.Field.mac] = reply.mac
            try await cloud.create(record)

            pairing = .waitingForMac(code: reply.code)
            UIApplication.shared.isIdleTimerDisabled = true
            let ack = try await waitForAck(parsed, sentReply: reply.payload)
            UIApplication.shared.isIdleTimerDisabled = false
            guard ack.accepted else { throw PairingFailure.declined }

            let mac = PairedMac(name: parsed.macName, macKey: parsed.macKey, pairedAt: Date())
            try PhoneKeys.saveMac(mac)
            await cloud.delete([Link.pairingName(parsed.id), Link.pairingAckName(parsed.id)])
            pairedMac = mac
            pairing = .done
            await finishSetup()
        } catch {
            if let offer { await LinkCloud.shared.delete([Link.pairingName(offer.id), Link.pairingAckName(offer.id)]) }
            PhoneKeys.deleteAll()
            if error is CancellationError || Task.isCancelled {
                pairing = .idle
                pairingMacName = nil
            } else {
                phoneLog("pairing failed: \(error)")
                pairing = .failed(Self.pairingText(error))
            }
        }
    }

    private func waitForAck(_ offer: PairOffer, sentReply: Data) async throws -> PairAck {
        var failures = 0
        while Date() < offer.expires {
            try Task.checkCancellation()
            do {
                if let record = try await LinkCloud.shared.fetch(Link.pairingAckName(offer.id)) {
                    guard let payload = record.data(Link.Field.payload),
                          let signature = record.data(Link.Field.signature) else {
                        throw LinkError.malformed("The Mac's answer is incomplete.")
                    }
                    return try LinkFlow.checkPairAck(payload: payload, signature: signature, offer: offer, sentReply: sentReply)
                }
                failures = 0
            } catch let error as LinkError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures += 1
                if failures >= 15 { throw error }
            }
            try await Task.sleep(for: .seconds(Link.pollInterval))
        }
        throw PairingFailure.timedOut
    }

    private func finishSetup() async {
        UIApplication.shared.registerForRemoteNotifications()
        async let subscribed: Void = ensureSubscriptions()
        await requestNotificationPermission()
        await subscribed
    }

    private static func iCloudProblem() async -> String? {
        guard let container = LinkCloud.shared.container else {
            return "iCloud isn't configured in this build."
        }
        switch try? await container.accountStatus() {
        case .available: return nil
        case .noAccount: return "Sign in to iCloud in Settings to pair with your Mac."
        case .restricted: return "iCloud is restricted on this iPhone."
        default: return "iCloud isn't available right now. Try again in a moment."
        }
    }

    private static func pairingText(_ error: Error) -> String {
        switch error {
        case PairingFailure.declined:
            return "Your Mac didn't accept the pairing. Try again from Keynod Settings."
        case PairingFailure.timedOut:
            return "Pairing timed out. Show a new code on your Mac and try again."
        case LinkError.badSignature:
            return "The answer from your Mac couldn't be verified. Try again with a new code."
        default:
            return describe(error)
        }
    }

    private static func biometryProblem() -> String? {
        let context = LAContext()
        var error: NSError?
        guard !context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return nil }
        let name = biometryName
        switch (error as? LAError)?.code {
        case .passcodeNotSet:
            return "Set a passcode and \(name) in Settings first. Keynod needs them to approve requests."
        case .biometryNotEnrolled:
            #if targetEnvironment(simulator)
            return "\(name) isn't set up. In the Simulator choose Features → Face ID → Enrolled."
            #else
            return "Set up \(name) in Settings first. Keynod needs it to approve requests."
            #endif
        case .biometryLockout:
            return "\(name) is locked. Unlock your iPhone with its passcode, then try again."
        default:
            return "\(name) isn't available on this iPhone."
        }
    }

    nonisolated static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Face ID"
        }
    }

    // MARK: Notifications

    func requestNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        await refreshNotificationStatus()
    }

    func refreshNotificationStatus() async {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .denied: notificationsAllowed = false
        default: notificationsAllowed = true
        }
    }

    func ensureSubscriptions() async {
        guard pairedMac != nil, !subscribing else { return }
        subscribing = true
        defer { subscribing = false }
        do {
            try await Self.installSubscriptions()
            notificationProblem = nil
        } catch {
            phoneLog("couldn't set up notifications: \(error)")
            UserDefaults.standard.removeObject(forKey: Self.schemaKey)
            notificationProblem = "Couldn't set up notifications: \(Self.describe(error))"
        }
    }

    private static func installSubscriptions() async throws {
        let cloud = LinkCloud.shared
        guard let db = cloud.database else { return }
        try await cloud.ensureZone()

        if !UserDefaults.standard.bool(forKey: schemaKey) {
            let existing = try await db.allSubscriptions()
            if !existing.contains(where: { $0.subscriptionID == requestsSubscription }) {
                try await createRequestSchema()
            }
            UserDefaults.standard.set(true, forKey: schemaKey)
        }

        let created = CKQuerySubscription(recordType: Link.RecordType.request, predicate: NSPredicate(value: true),
                                          subscriptionID: requestsSubscription, options: [.firesOnRecordCreation])
        created.zoneID = cloud.zoneID
        let alert = CKSubscription.NotificationInfo()
        alert.titleLocalizationKey = "KEYNOD_TITLE"
        alert.titleLocalizationArgs = [Link.Field.title]
        alert.subtitleLocalizationKey = "KEYNOD_SUBTITLE"
        alert.subtitleLocalizationArgs = [Link.Field.subtitle]
        alert.alertLocalizationKey = "KEYNOD_BODY"
        alert.alertLocalizationArgs = [Link.Field.body]
        alert.soundName = "default"
        alert.category = KeynodNotification.category
        created.notificationInfo = alert

        let closed = CKQuerySubscription(recordType: Link.RecordType.request, predicate: NSPredicate(value: true),
                                         subscriptionID: closedSubscription, options: [.firesOnRecordDeletion])
        closed.zoneID = cloud.zoneID
        let silent = CKSubscription.NotificationInfo()
        silent.shouldSendContentAvailable = true
        closed.notificationInfo = silent

        let result = try await db.modifySubscriptions(saving: [created, closed], deleting: [])
        for outcome in result.saveResults.values {
            if case .failure(let error) = outcome { throw error }
        }
    }

    private static func createRequestSchema() async throws {
        let cloud = LinkCloud.shared
        let name = "req-schema"
        let record = cloud.newRecord(Link.RecordType.request, name)
        record[Link.Field.payload] = Data([0])
        record[Link.Field.signature] = Data([0])
        record[Link.Field.title] = ""
        record[Link.Field.subtitle] = ""
        record[Link.Field.body] = ""
        record[Link.Field.expires] = Date()
        let blank = FileManager.default.temporaryDirectory.appendingPathComponent("keynod-schema-\(UUID().uuidString).jpg")
        if (try? Data([0]).write(to: blank)) != nil {
            for n in 0..<Link.maxImages { record[Link.Field.image(n)] = CKAsset(fileURL: blank) }
        }
        defer { try? FileManager.default.removeItem(at: blank) }
        do {
            try await cloud.create(record)
        } catch let error as CKError where error.code == .serverRecordChanged {
        }
        await cloud.delete([name])
    }

    // MARK: Unpairing

    func unpair() async {
        pairingTask?.cancel()
        PhoneKeys.deleteAll()
        pairedMac = nil
        requests = []
        busy = []
        answered = []
        mode = nil
        rejectedModeSignature = nil
        awake = nil
        rejectedAwakeSignature = nil
        pairing = .idle
        pairingMacName = nil
        notificationProblem = nil
        syncProblem = nil
        focusedRequest = nil
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UIApplication.shared.unregisterForRemoteNotifications()
        let ids = [Self.requestsSubscription, Self.closedSubscription]
        _ = try? await LinkCloud.shared.database?.modifySubscriptions(saving: [], deleting: ids)
    }

    // MARK: Messages

    private struct Message: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case let error as Message:
            return error.description
        case let error as PhoneKeys.Failure:
            return error.description
        case let error as LinkError:
            switch error {
            case .expired: return "This request has expired."
            case .badSignature: return "The signature doesn't match your paired Mac."
            case .wrongVersion: return "Keynod on this iPhone and on your Mac are different versions. Update both."
            default: return error.description
            }
        case let error as LAError:
            let name = biometryName
            switch error.code {
            case .biometryNotEnrolled: return "\(name) isn't set up on this iPhone."
            case .biometryLockout: return "\(name) is locked. Unlock your iPhone with its passcode, then try again."
            case .biometryNotAvailable: return "\(name) isn't available right now."
            case .authenticationFailed: return "\(name) didn't recognize you."
            case .passcodeNotSet: return "Set a passcode on this iPhone first."
            default: return error.localizedDescription
            }
        case let error as CKError:
            switch error.code {
            case .notAuthenticated: return "Sign in to iCloud in Settings to use Keynod."
            case .networkUnavailable, .networkFailure: return "Can't reach iCloud. Check your connection."
            case .quotaExceeded: return "Your iCloud storage is full."
            case .requestRateLimited, .zoneBusy, .serviceUnavailable: return "iCloud is busy. Try again in a moment."
            case .permissionFailure: return "Keynod isn't allowed to use iCloud. Check Settings → iCloud."
            default: return error.localizedDescription
            }
        default:
            return error.localizedDescription
        }
    }
}
