import CryptoKit
import Darwin
import Foundation

/// The authenticated, encrypted channel over `keynod.sock`, on top of the
/// code-signature check in `PeerIdentity`.
///
/// The signature check alone is not enough: the kernel reports the peer's
/// audit token when it is asked, not when the peer connected, so a process
/// can connect, write a request and then exec the real binary in the same pid.
/// Here the request itself is bound to the channel key, which only this
/// program can read (see `ChannelKey`).
///
/// Protocol, one line each:
/// 1. client → `{"channel":"keynod/1","nonce":<32 random bytes, base64>}`
/// 2. server → the same shape with its own nonce
/// 3. client → the request, sealed; 4. server → the response, sealed.
/// Each direction has its own key: HKDF-SHA256 over the channel key, salted
/// with both nonces. Frames are ChaChaPoly with a counter nonce, so a frame
/// from another connection, a repeated frame, or anything in plain text fails
/// to open and is never processed.
enum SecureChannel {
    static let version = "keynod/1"
    static let keySize = 32
    private static let toServerInfo = Data("keynod.channel.v1|client-to-server".utf8)
    private static let toClientInfo = Data("keynod.channel.v1|server-to-client".utf8)
    private static let frameAAD = Data("keynod.channel.v1|frame".utf8)
    static let helloLimit = 1024

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// One side of an open channel.
    final class Session {
        private let fd: Int32
        private let reader: LineReader
        private let sendKey: SymmetricKey
        private let receiveKey: SymmetricKey
        private var sent: UInt64 = 0
        private var received: UInt64 = 0

        fileprivate init(fd: Int32, reader: LineReader, sendKey: SymmetricKey, receiveKey: SymmetricKey) {
            self.fd = fd
            self.reader = reader
            self.sendKey = sendKey
            self.receiveKey = receiveKey
        }

        func send(_ payload: Data) throws {
            let frame = try SecureChannel.seal(payload, key: sendKey, counter: sent)
            sent += 1
            guard LineReader.writeLine(fd, frame) else { throw Failure("the connection closed while sending") }
        }

        func receive(limit: Int = 16 << 20) throws -> Data {
            guard let line = reader.readLine(limit: limit) else { throw Failure("the connection closed without a message") }
            let payload = try SecureChannel.open(line, key: receiveKey, counter: received)
            received += 1
            return payload
        }
    }

    // MARK: Handshake

    /// Client side: says hello, reads the server's hello, derives the keys.
    /// Anything but a well-formed hello back (an old server, a plain-text
    /// refusal) is a failure; its text is never trusted.
    static func client(fd: Int32, key: SymmetricKey) throws -> Session {
        let reader = LineReader(fd)
        let mine = randomNonce()
        guard LineReader.writeLine(fd, hello(mine)) else { throw Failure("the connection closed during the handshake") }
        guard let line = reader.readLine(limit: helloLimit), let theirs = parseHello(line) else {
            throw Failure("the other side did not answer with a channel hello")
        }
        let keys = deriveKeys(key, clientNonce: mine, serverNonce: theirs)
        return Session(fd: fd, reader: reader, sendKey: keys.toServer, receiveKey: keys.toClient)
    }

    /// Server side: reads the client's hello, answers with its own, derives the keys.
    static func server(fd: Int32, key: SymmetricKey) throws -> Session {
        let reader = LineReader(fd)
        guard let line = reader.readLine(limit: helloLimit), let theirs = parseHello(line) else {
            throw Failure("the client did not start with a channel hello")
        }
        let mine = randomNonce()
        guard LineReader.writeLine(fd, hello(mine)) else { throw Failure("the connection closed during the handshake") }
        let keys = deriveKeys(key, clientNonce: theirs, serverNonce: mine)
        return Session(fd: fd, reader: reader, sendKey: keys.toClient, receiveKey: keys.toServer)
    }

    private struct Hello: Codable {
        let channel: String
        let nonce: Data
    }

    static func hello(_ nonce: Data) -> Data {
        (try? JSONEncoder().encode(Hello(channel: version, nonce: nonce))) ?? Data()
    }

    /// The peer's nonce, if `line` is exactly a hello of this version.
    static func parseHello(_ line: Data) -> Data? {
        guard let hello = try? JSONDecoder().decode(Hello.self, from: line),
              hello.channel == version, hello.nonce.count == keySize else { return nil }
        return hello.nonce
    }

    static func randomNonce() -> Data {
        Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
    }

    static func deriveKeys(_ key: SymmetricKey, clientNonce: Data, serverNonce: Data)
        -> (toServer: SymmetricKey, toClient: SymmetricKey) {
        let salt = clientNonce + serverNonce
        let toServer = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt, info: toServerInfo, outputByteCount: keySize)
        let toClient = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt, info: toClientInfo, outputByteCount: keySize)
        return (toServer, toClient)
    }

    // MARK: Frames

    /// One frame: base64 of ChaChaPoly's nonce ‖ ciphertext ‖ tag. The nonce is
    /// the frame's number in its direction.
    static func seal(_ payload: Data, key: SymmetricKey, counter: UInt64) throws -> Data {
        let box = try ChaChaPoly.seal(payload, using: key, nonce: nonce(counter), authenticating: frameAAD)
        return box.combined.base64EncodedData()
    }

    /// Opens a frame. Fails for a wrong key, a changed byte, a frame out of
    /// order or repeated, and anything that isn't a frame (such as plain JSON).
    static func open(_ line: Data, key: SymmetricKey, counter: UInt64) throws -> Data {
        guard let raw = Data(base64Encoded: line), let box = try? ChaChaPoly.SealedBox(combined: raw) else {
            throw Failure("not a sealed frame")
        }
        guard box.nonce.withUnsafeBytes({ Data($0) }) == nonce(counter).withUnsafeBytes({ Data($0) }) else {
            throw Failure("frame out of order or repeated")
        }
        do {
            return try ChaChaPoly.open(box, using: key, authenticating: frameAAD)
        } catch {
            throw Failure("frame failed authentication")
        }
    }

    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }
}

/// Reads newline-terminated lines from a socket without losing bytes that
/// arrive after a newline (they stay for the next line).
final class LineReader {
    private let fd: Int32
    private var buffer = Data()

    init(_ fd: Int32) { self.fd = fd }

    /// The next line without its newline. Nil on EOF, error, or a line longer than `limit`.
    func readLine(limit: Int) -> Data? {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                guard nl - buffer.startIndex <= limit else { return nil }
                let line = Data(buffer[buffer.startIndex..<nl])
                buffer = Data(buffer[(nl + 1)...])
                return line
            }
            if buffer.count > limit { return nil }
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
            // A line longer than `limit` is refused as soon as it is seen, newline or not.
            let end = buffer.firstIndex(of: 0x0A) ?? buffer.endIndex
            if end - buffer.startIndex > limit { return nil }
        }
    }

    static func writeLine(_ fd: Int32, _ payload: Data) -> Bool {
        var out = payload
        out.append(0x0A)
        return out.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }
}
