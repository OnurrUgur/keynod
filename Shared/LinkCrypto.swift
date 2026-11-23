import CryptoKit
import Foundation

/// Signs with a P-256 private key that may live in the Secure Enclave.
protocol LinkSigner {
    var signingPublicKey: P256.Signing.PublicKey { get }
    /// Raw (r ‖ s) ECDSA signature.
    func sign(_ data: Data) throws -> Data
}

/// P-256 key agreement with a private key that may live in the Secure Enclave.
protocol LinkAgreer {
    var agreementPublicKey: P256.KeyAgreement.PublicKey { get }
    func agree(with other: P256.KeyAgreement.PublicKey) throws -> SharedSecret
}

extension P256.Signing.PrivateKey: LinkSigner {
    var signingPublicKey: P256.Signing.PublicKey { publicKey }
    func sign(_ data: Data) throws -> Data { try signature(for: data).rawRepresentation }
}

extension SecureEnclave.P256.Signing.PrivateKey: LinkSigner {
    var signingPublicKey: P256.Signing.PublicKey { publicKey }
    func sign(_ data: Data) throws -> Data { try signature(for: data).rawRepresentation }
}

extension P256.KeyAgreement.PrivateKey: LinkAgreer {
    var agreementPublicKey: P256.KeyAgreement.PublicKey { publicKey }
    func agree(with other: P256.KeyAgreement.PublicKey) throws -> SharedSecret {
        try sharedSecretFromKeyAgreement(with: other)
    }
}

extension SecureEnclave.P256.KeyAgreement.PrivateKey: LinkAgreer {
    var agreementPublicKey: P256.KeyAgreement.PublicKey { publicKey }
    func agree(with other: P256.KeyAgreement.PublicKey) throws -> SharedSecret {
        try sharedSecretFromKeyAgreement(with: other)
    }
}

/// The building blocks. Everything is P-256 ECDH + HKDF-SHA256 + AES-GCM, with
/// the request or field id bound in as associated data.
enum LinkCrypto {
    /// A concealed value encrypted on the Mac so that only the paired iPhone
    /// can derive its key. The Mac keeps it; it never leaves the Mac.
    struct Protected: Codable, Equatable {
        /// Public half of a throwaway key; with the phone's field key it gives the field key.
        var eph: Data
        /// AES-GCM (nonce ‖ ciphertext ‖ tag) of the value.
        var box: Data
    }

    static func signingKey(_ x963: Data) throws -> P256.Signing.PublicKey {
        do { return try P256.Signing.PublicKey(x963Representation: x963) } catch { throw LinkError.badKey }
    }

    static func agreementKey(_ x963: Data) throws -> P256.KeyAgreement.PublicKey {
        do { return try P256.KeyAgreement.PublicKey(x963Representation: x963) } catch { throw LinkError.badKey }
    }

    static func verify(_ signature: Data, of data: Data, by key: P256.Signing.PublicKey) -> Bool {
        guard let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return key.isValidSignature(sig, for: data)
    }

    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    /// Lowercase hex SHA-256, how a request names its pictures.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Eight hex digits naming a public key, for display and logs.
    static func keyID(_ x963: Data) -> String {
        sha256(x963).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    static func randomBytes(_ count: Int) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }

    // MARK: Field copies

    /// Mac: encrypts a value under a key only the phone's field key can derive.
    static func protect(_ value: Data, field: UUID, for phoneFieldKey: P256.KeyAgreement.PublicKey) throws -> Protected {
        let eph = P256.KeyAgreement.PrivateKey()
        let key = fieldKey(try eph.sharedSecretFromKeyAgreement(with: phoneFieldKey),
                           eph: eph.publicKey, recipient: phoneFieldKey, field: field)
        guard let box = try AES.GCM.seal(value, using: key, authenticating: fieldInfo(field)).combined else {
            throw LinkError.badKey
        }
        return Protected(eph: eph.publicKey.x963Representation, box: box)
    }

    /// iPhone: the key of one field. `agreer` is the field key (unlocked by Face ID).
    static func fieldKey(field: UUID, eph: Data, with agreer: LinkAgreer) throws -> SymmetricKey {
        let ephKey = try agreementKey(eph)
        return fieldKey(try agreer.agree(with: ephKey), eph: ephKey, recipient: agreer.agreementPublicKey, field: field)
    }

    /// Mac: decrypts a protected copy with the key the phone released.
    static func open(_ protected: Protected, field: UUID, key: SymmetricKey) throws -> Data {
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: protected.box), using: key, authenticating: fieldInfo(field))
        } catch {
            throw LinkError.badKey
        }
    }

    private static func fieldInfo(_ field: UUID) -> Data { Data("keynod.field.v1|\(field.uuidString)".utf8) }

    private static func fieldKey(_ shared: SharedSecret, eph: P256.KeyAgreement.PublicKey,
                                 recipient: P256.KeyAgreement.PublicKey, field: UUID) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self,
                                       salt: eph.x963Representation + recipient.x963Representation,
                                       sharedInfo: fieldInfo(field), outputByteCount: 32)
    }

    // MARK: Reply keys

    /// iPhone: seals one field key to the request's one-time key.
    static func seal(_ key: SymmetricKey, request: UUID, field: UUID,
                     to reply: P256.KeyAgreement.PublicKey) throws -> LinkResponse.Key {
        let eph = P256.KeyAgreement.PrivateKey()
        let wrap = replyKey(try eph.sharedSecretFromKeyAgreement(with: reply), eph: eph.publicKey,
                            recipient: reply, request: request, field: field)
        let raw = key.withUnsafeBytes { Data($0) }
        guard let box = try AES.GCM.seal(raw, using: wrap, authenticating: replyInfo(request, field)).combined else {
            throw LinkError.badKey
        }
        return LinkResponse.Key(field: field, eph: eph.publicKey.x963Representation, box: box)
    }

    /// Mac: opens one sealed field key with the request's one-time private key.
    static func open(_ sealed: LinkResponse.Key, request: UUID, with reply: P256.KeyAgreement.PrivateKey) throws -> SymmetricKey {
        let ephKey = try agreementKey(sealed.eph)
        let wrap = replyKey(try reply.sharedSecretFromKeyAgreement(with: ephKey), eph: ephKey,
                            recipient: reply.publicKey, request: request, field: sealed.field)
        let raw: Data
        do {
            raw = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed.box), using: wrap,
                                   authenticating: replyInfo(request, sealed.field))
        } catch {
            throw LinkError.badKey
        }
        guard raw.count == 32 else { throw LinkError.badKey }
        return SymmetricKey(data: raw)
    }

    private static func replyInfo(_ request: UUID, _ field: UUID) -> Data {
        Data("keynod.reply.v1|\(request.uuidString)|\(field.uuidString)".utf8)
    }

    private static func replyKey(_ shared: SharedSecret, eph: P256.KeyAgreement.PublicKey,
                                 recipient: P256.KeyAgreement.PublicKey, request: UUID, field: UUID) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self,
                                       salt: eph.x963Representation + recipient.x963Representation,
                                       sharedInfo: replyInfo(request, field), outputByteCount: 32)
    }

    // MARK: Answer text

    /// iPhone: seals answer text (maybe a one-time code) to the request's one-time key.
    static func sealText(_ text: String, request: UUID, to reply: P256.KeyAgreement.PublicKey) throws -> Protected {
        let eph = P256.KeyAgreement.PrivateKey()
        let key = textKey(try eph.sharedSecretFromKeyAgreement(with: reply), eph: eph.publicKey, recipient: reply, request: request)
        guard let box = try AES.GCM.seal(Data(text.utf8), using: key, authenticating: textInfo(request)).combined else {
            throw LinkError.badKey
        }
        return Protected(eph: eph.publicKey.x963Representation, box: box)
    }

    /// Mac: opens answer text with the request's one-time private key.
    static func openText(_ sealed: Protected, request: UUID, with reply: P256.KeyAgreement.PrivateKey) throws -> String {
        let ephKey = try agreementKey(sealed.eph)
        let key = textKey(try reply.sharedSecretFromKeyAgreement(with: ephKey), eph: ephKey, recipient: reply.publicKey, request: request)
        do {
            let data = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed.box), using: key, authenticating: textInfo(request))
            guard let text = String(data: data, encoding: .utf8) else { throw LinkError.badKey }
            return text
        } catch {
            throw LinkError.badKey
        }
    }

    private static func textInfo(_ request: UUID) -> Data { Data("keynod.text.v1|\(request.uuidString)".utf8) }

    private static func textKey(_ shared: SharedSecret, eph: P256.KeyAgreement.PublicKey,
                                recipient: P256.KeyAgreement.PublicKey, request: UUID) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: eph.x963Representation + recipient.x963Representation,
                                       sharedInfo: textInfo(request), outputByteCount: 32)
    }

    // MARK: Pairing

    static func pairingMAC(_ payload: Data, secret: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: secret)))
    }

    static func checkPairingMAC(_ mac: Data, payload: Data, secret: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: payload, using: SymmetricKey(data: secret))
    }

    /// Six digits both screens show, e.g. "482 913".
    static func pairingCode(macKey: Data, reply: Data) -> String {
        let d = Array(SHA256.hash(data: macKey + reply))
        let n = (UInt32(d[0]) << 24 | UInt32(d[1]) << 16 | UInt32(d[2]) << 8 | UInt32(d[3])) % 1_000_000
        let s = String(format: "%06u", n)
        return s.prefix(3) + " " + s.suffix(3)
    }
}

// MARK: - Protocol steps

/// What the Mac keeps in memory while one request waits for the phone.
struct LinkWaiting {
    let request: LinkRequest
    /// The exact signed bytes.
    let payload: Data
    let signature: Data
    /// Never stored, never sent: dropped when the request closes, so an old
    /// answer can't be replayed.
    let replyKey: P256.KeyAgreement.PrivateKey
}

enum LinkVerdict {
    /// Field id → key; empty for create, delete, and permission questions.
    case approved([UUID: SymmetricKey])
    case denied
    /// A question answered with a choice and/or text (decrypted).
    case answered(choice: String?, text: String?)
}

enum LinkFlow {
    // MARK: Mac

    /// A signed request and what to keep while waiting for its answer.
    static func makeRequest(id: UUID = UUID(), macName: String, kind: String, who: String, command: String,
                            cwd: String, summary: String, items: [LinkRequest.Item], now: Date = Date(),
                            ttl: TimeInterval? = nil, body: String? = nil, options: [String]? = nil,
                            input: String? = nil, images: [Data] = [],
                            signer: LinkSigner) throws -> LinkWaiting {
        let replyKey = P256.KeyAgreement.PrivateKey()
        // One key per field: `--env A=X/Key --env B=X/Key` names the same field twice.
        var seen = Set<UUID>()
        let unique = items.filter { seen.insert($0.field).inserted }
        let limit = Link.maxLifetime(kind: kind)
        let cappedImages = Array(images.prefix(Link.maxImages))
        let request = LinkRequest(id: id, macName: macName, created: now,
                                  expires: now.addingTimeInterval(min(ttl ?? Link.requestTTL, limit)),
                                  kind: kind, who: who, command: command, cwd: cwd, summary: summary, items: unique,
                                  reply: replyKey.publicKey.x963Representation, body: body, options: options, input: input,
                                  imageHashes: cappedImages.isEmpty ? nil : cappedImages.map(LinkCrypto.sha256Hex))
        let payload = try LinkCoding.encode(request)
        return LinkWaiting(request: request, payload: payload, signature: try signer.sign(payload), replyKey: replyKey)
    }

    /// Checks the phone's answer to `waiting`. Approvals must be signed with the
    /// approve key (Face ID) and carry exactly the requested fields' keys.
    static func checkResponse(payload: Data, signature: Data, for waiting: LinkWaiting,
                              phone: PairedPhone, now: Date = Date()) throws -> LinkVerdict {
        let response = try LinkCoding.decode(LinkResponse.self, from: payload)
        guard response.v == Link.version else { throw LinkError.wrongVersion }
        guard response.request == waiting.request.id,
              response.requestHash == LinkCrypto.sha256(waiting.payload) else { throw LinkError.wrongRequest }
        guard now < waiting.request.expires else { throw LinkError.expired }
        let approveKey = try LinkCrypto.signingKey(phone.approveKey)
        switch response.decision {
        case .deny:
            let denyKey = try LinkCrypto.signingKey(phone.denyKey)
            guard LinkCrypto.verify(signature, of: payload, by: denyKey)
                || LinkCrypto.verify(signature, of: payload, by: approveKey) else { throw LinkError.badSignature }
            return .denied
        case .answer:
            guard waiting.request.isQuestion else { throw LinkError.wrongRequest }
            let denyKey = try LinkCrypto.signingKey(phone.denyKey)
            guard LinkCrypto.verify(signature, of: payload, by: denyKey)
                || LinkCrypto.verify(signature, of: payload, by: approveKey) else { throw LinkError.badSignature }
            if let choice = response.choice, let options = waiting.request.options, !options.contains(choice) {
                throw LinkError.malformed("the answer picked an option that wasn't offered")
            }
            let text = try response.text.map { try LinkCrypto.openText($0, request: response.request, with: waiting.replyKey) }
            return .answered(choice: response.choice, text: text)
        case .approve:
            guard LinkCrypto.verify(signature, of: payload, by: approveKey) else { throw LinkError.badSignature }
            let wanted = Set(waiting.request.items.map(\.field))
            guard response.keys.count == wanted.count, Set(response.keys.map(\.field)) == wanted else {
                throw LinkError.missingKeys
            }
            var keys: [UUID: SymmetricKey] = [:]
            for sealed in response.keys {
                keys[sealed.field] = try LinkCrypto.open(sealed, request: response.request, with: waiting.replyKey)
            }
            return .approved(keys)
        }
    }

    // MARK: iPhone

    /// Checks the Mac's signature and the time window, then decodes. A request that names
    /// pictures needs them in `images` (the downloaded JPEGs, in order): each must match its
    /// signed hash. Without `images` it throws `.missingImages` (after the signature is
    /// checked, so the hashes can be trusted); a mismatch is `.malformed`.
    static func checkRequest(payload: Data, signature: Data, mac: PairedMac, now: Date = Date(),
                             images: [Data]? = nil) throws -> LinkRequest {
        guard LinkCrypto.verify(signature, of: payload, by: try LinkCrypto.signingKey(mac.macKey)) else {
            throw LinkError.badSignature
        }
        let request = try LinkCoding.decode(LinkRequest.self, from: payload)
        guard request.v == Link.version else { throw LinkError.wrongVersion }
        guard now < request.expires, request.created < now.addingTimeInterval(Link.clockSkew),
              request.expires.timeIntervalSince(request.created) <= Link.maxLifetime(kind: request.kind) + 1
        else { throw LinkError.expired }
        if let hashes = request.imageHashes, !hashes.isEmpty {
            guard hashes.count <= Link.maxImages else { throw LinkError.malformed("too many pictures") }
            guard let images else { throw LinkError.missingImages }
            guard images.count == hashes.count, zip(images, hashes).allSatisfy({ LinkCrypto.sha256Hex($0) == $1 }) else {
                throw LinkError.malformed("a picture doesn't match the signed request")
            }
        }
        return request
    }

    /// An answer to a question: a choice and/or text. The text is sealed to
    /// the request's one-time key. Signed with the deny key (no Face ID), so
    /// it can be sent from a notification; it never opens a secret.
    static func answer(_ request: LinkRequest, payload: Data, choice: String?, text: String?, signer: LinkSigner,
                       now: Date = Date()) throws -> (payload: Data, signature: Data) {
        guard request.isQuestion else { throw LinkError.wrongRequest }
        let sealed = try text.map { try LinkCrypto.sealText($0, request: request.id, to: try LinkCrypto.agreementKey(request.reply)) }
        let response = LinkResponse(request: request.id, requestHash: LinkCrypto.sha256(payload), decision: .answer,
                                    at: now, keys: [], choice: choice, text: sealed)
        let bytes = try LinkCoding.encode(response)
        return (bytes, try signer.sign(bytes))
    }

    /// An approval: derives each requested field's key with `fieldKey`, seals
    /// it to the request's one-time key and signs with `approveKey`. Both keys
    /// must already be unlocked by one Face ID check.
    static func approve(_ request: LinkRequest, payload: Data, fieldKey: LinkAgreer, approveKey: LinkSigner,
                        now: Date = Date()) throws -> (payload: Data, signature: Data) {
        let reply = try LinkCrypto.agreementKey(request.reply)
        let keys = try request.items.map { item in
            try LinkCrypto.seal(try LinkCrypto.fieldKey(field: item.field, eph: item.eph, with: fieldKey),
                                request: request.id, field: item.field, to: reply)
        }
        let response = LinkResponse(request: request.id, requestHash: LinkCrypto.sha256(payload),
                                    decision: .approve, at: now, keys: keys)
        let bytes = try LinkCoding.encode(response)
        return (bytes, try approveKey.sign(bytes))
    }

    /// A denial, signed with the deny key (no Face ID needed).
    static func deny(_ request: LinkRequest, payload: Data, denyKey: LinkSigner,
                     now: Date = Date()) throws -> (payload: Data, signature: Data) {
        let response = LinkResponse(request: request.id, requestHash: LinkCrypto.sha256(payload),
                                    decision: .deny, at: now, keys: [])
        let bytes = try LinkCoding.encode(response)
        return (bytes, try denyKey.sign(bytes))
    }

    // MARK: Remote mode

    /// Either device: a signed mode change (the Mac signs with its key, the
    /// iPhone with its deny key, so switching needs no Face ID).
    static func makeMode(remote: Bool, by: String, now: Date = Date(),
                         signer: LinkSigner) throws -> (payload: Data, signature: Data) {
        let bytes = try LinkCoding.encode(LinkMode(remote: remote, at: now, by: by))
        return (bytes, try signer.sign(bytes))
    }

    /// Mac: its stay-awake state, signed with the Mac key.
    static func makeAwake(until: Date?, now: Date = Date(),
                          signer: LinkSigner) throws -> (payload: Data, signature: Data) {
        let bytes = try LinkCoding.encode(LinkAwake(until: until, at: now))
        return (bytes, try signer.sign(bytes))
    }

    /// iPhone: accepts a stay-awake state signed by the paired Mac (`macKey`, x963).
    /// Callers keep the newest `at`, so an old record saved again can't undo a newer one.
    static func checkAwake(payload: Data, signature: Data, macKey: Data) throws -> LinkAwake {
        guard LinkCrypto.verify(signature, of: payload, by: try LinkCrypto.signingKey(macKey)) else {
            throw LinkError.badSignature
        }
        let awake = try LinkCoding.decode(LinkAwake.self, from: payload)
        guard awake.v == Link.version else { throw LinkError.wrongVersion }
        return awake
    }

    /// iPhone: a signed command for the Mac ("lock", "sleep", "awake-on", "awake-off"), signed with the deny key.
    static func makeCommand(action: String, id: UUID = UUID(), now: Date = Date(),
                            signer: LinkSigner) throws -> (command: LinkCommand, payload: Data, signature: Data) {
        let command = LinkCommand(id: id, action: action, at: now)
        let bytes = try LinkCoding.encode(command)
        return (command, bytes, try signer.sign(bytes))
    }

    /// Mac: accepts a command signed by the paired phone while it is fresh.
    /// The caller runs each id once.
    static func checkCommand(payload: Data, signature: Data, phone: PairedPhone, now: Date = Date()) throws -> LinkCommand {
        let keys = [try LinkCrypto.signingKey(phone.denyKey), try LinkCrypto.signingKey(phone.approveKey)]
        guard keys.contains(where: { LinkCrypto.verify(signature, of: payload, by: $0) }) else { throw LinkError.badSignature }
        let command = try LinkCoding.decode(LinkCommand.self, from: payload)
        guard command.v == Link.version else { throw LinkError.wrongVersion }
        guard command.at < now.addingTimeInterval(Link.clockSkew),
              now.timeIntervalSince(command.at) < Link.commandTTL else { throw LinkError.expired }
        return command
    }

    /// Accepts a mode change signed by any of `keys` (x963 signing keys of the
    /// paired devices). Callers keep the newest `at` they have applied, so an
    /// old record saved again can't switch the mode back.
    static func checkMode(payload: Data, signature: Data, keys: [Data]) throws -> LinkMode {
        let signers = keys.compactMap { try? LinkCrypto.signingKey($0) }
        guard signers.contains(where: { LinkCrypto.verify(signature, of: payload, by: $0) }) else {
            throw LinkError.badSignature
        }
        let mode = try LinkCoding.decode(LinkMode.self, from: payload)
        guard mode.v == Link.version else { throw LinkError.wrongVersion }
        return mode
    }

    // MARK: Pairing

    /// iPhone: the reply payload and its HMAC (keyed with the QR secret).
    static func makePairReply(_ offer: PairOffer, phoneName: String, approveKey: Data, fieldKey: Data,
                              denyKey: Data) throws -> (payload: Data, mac: Data, code: String) {
        let reply = PairReply(pairing: offer.id, phoneName: phoneName, approveKey: approveKey,
                              fieldKey: fieldKey, denyKey: denyKey)
        let payload = try LinkCoding.encode(reply)
        return (payload, LinkCrypto.pairingMAC(payload, secret: offer.secret),
                LinkCrypto.pairingCode(macKey: offer.macKey, reply: payload))
    }

    /// Mac: checks a reply against the offer it showed; returns the reply and the code to show.
    static func checkPairReply(payload: Data, mac: Data, offer: PairOffer,
                               now: Date = Date()) throws -> (reply: PairReply, code: String) {
        guard now < offer.expires else { throw LinkError.expired }
        guard LinkCrypto.checkPairingMAC(mac, payload: payload, secret: offer.secret) else { throw LinkError.badSignature }
        let reply = try LinkCoding.decode(PairReply.self, from: payload)
        guard reply.v == Link.version else { throw LinkError.wrongVersion }
        guard reply.pairing == offer.id else { throw LinkError.wrongRequest }
        for key in [reply.approveKey, reply.denyKey] { _ = try LinkCrypto.signingKey(key) }
        _ = try LinkCrypto.agreementKey(reply.fieldKey)
        return (reply, LinkCrypto.pairingCode(macKey: offer.macKey, reply: payload))
    }

    /// What a `PairAck` names the accepted reply by.
    static func pairReplyDigest(_ replyPayload: Data) -> Data {
        Data(SHA256.hash(data: replyPayload))
    }

    /// iPhone: checks the Mac's signed answer to a pairing. An acceptance must
    /// name `sentReply` (this phone's own reply payload) by its digest.
    static func checkPairAck(payload: Data, signature: Data, offer: PairOffer, sentReply: Data) throws -> PairAck {
        guard LinkCrypto.verify(signature, of: payload, by: try LinkCrypto.signingKey(offer.macKey)) else {
            throw LinkError.badSignature
        }
        let ack = try LinkCoding.decode(PairAck.self, from: payload)
        guard ack.v == Link.version else { throw LinkError.wrongVersion }
        guard ack.pairing == offer.id else { throw LinkError.wrongRequest }
        if ack.accepted, ack.reply != pairReplyDigest(sentReply) { throw LinkError.wrongRequest }
        return ack
    }
}
