import CryptoKit
import Darwin
import XCTest

/// The channel over a socket pair: the server side runs on a background queue,
/// the client side on the test thread.
final class SecureChannelTests: XCTestCase {
    private var fds: [Int32] = [-1, -1]
    private var serverClosed = false
    private let key = SymmetricKey(size: .bits256)

    override func setUp() {
        super.setUp()
        fds = [-1, -1]
        serverClosed = false
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        var one: Int32 = 1
        fds.forEach { setsockopt($0, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) }
    }

    override func tearDown() {
        close(fds[0])
        if !serverClosed { close(fds[1]) }
        super.tearDown()
    }

    private var client: Int32 { fds[0] }
    private var server: Int32 { fds[1] }

    /// Runs `body` as the server (which closes its end afterwards, like the app)
    /// and returns what it received (or the error), after the client part is done.
    private func serve(key serverKey: SymmetricKey? = nil, _ body: @escaping (SecureChannel.Session) throws -> Data)
        -> () -> Result<Data, Error> {
        let done = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(SecureChannel.Failure("not run"))
        let fd = server, k = serverKey ?? key
        serverClosed = true
        DispatchQueue.global().async {
            result = Result { try body(try SecureChannel.server(fd: fd, key: k)) }
            close(fd)
            done.signal()
        }
        return {
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
            return result
        }
    }

    func testRoundTrip() throws {
        let finish = serve { session in
            let request = try session.receive()
            try session.send(Data("reply to ".utf8) + request)
            return request
        }
        let session = try SecureChannel.client(fd: client, key: key)
        try session.send(Data(#"{"op":"list"}"#.utf8))
        XCTAssertEqual(String(decoding: try session.receive(), as: UTF8.self), #"reply to {"op":"list"}"#)
        XCTAssertEqual(String(decoding: try finish().get(), as: UTF8.self), #"{"op":"list"}"#)
    }

    func testWrongKeyIsRefused() throws {
        let finish = serve(key: SymmetricKey(size: .bits256)) { try $0.receive() }
        let session = try SecureChannel.client(fd: client, key: key)
        try session.send(Data(#"{"op":"list"}"#.utf8))
        XCTAssertThrowsError(try finish().get(), "a request sealed with another key must not open")
    }

    func testTamperedFrameIsRefused() throws {
        let finish = serve { try $0.receive() }
        // A client by hand: proper hello, then a sealed frame with one byte changed.
        let reader = LineReader(client)
        let nonce = SecureChannel.randomNonce()
        XCTAssertTrue(LineReader.writeLine(client, SecureChannel.hello(nonce)))
        let theirs = try XCTUnwrap(reader.readLine(limit: 1024).flatMap(SecureChannel.parseHello))
        let keys = SecureChannel.deriveKeys(key, clientNonce: nonce, serverNonce: theirs)
        var raw = try XCTUnwrap(Data(base64Encoded: try SecureChannel.seal(Data("{}".utf8), key: keys.toServer, counter: 0)))
        raw[raw.count - 1] ^= 0x01
        XCTAssertTrue(LineReader.writeLine(client, raw.base64EncodedData()))
        XCTAssertThrowsError(try finish().get())
    }

    func testReplayedFramesAreRefused() throws {
        // Within one connection: the same frame twice.
        let keys = SecureChannel.deriveKeys(key, clientNonce: Data(repeating: 1, count: 32), serverNonce: Data(repeating: 2, count: 32))
        let frame = try SecureChannel.seal(Data("{}".utf8), key: keys.toServer, counter: 0)
        XCTAssertEqual(try SecureChannel.open(frame, key: keys.toServer, counter: 0), Data("{}".utf8))
        XCTAssertThrowsError(try SecureChannel.open(frame, key: keys.toServer, counter: 1), "a repeated frame must not open")

        // Across connections: a frame recorded from an earlier one.
        let finish = serve { try $0.receive() }
        let reader = LineReader(client)
        let nonce = SecureChannel.randomNonce()
        XCTAssertTrue(LineReader.writeLine(client, SecureChannel.hello(nonce)))
        XCTAssertNotNil(reader.readLine(limit: 1024).flatMap(SecureChannel.parseHello))
        XCTAssertTrue(LineReader.writeLine(client, frame))
        XCTAssertThrowsError(try finish().get(), "a frame from another connection must not open")
    }

    func testPlainTextRequestIsRefused() throws {
        // Without a hello at all (the old protocol, or a script).
        var finish = serve { try $0.receive() }
        XCTAssertTrue(LineReader.writeLine(client, Data(#"{"op":"list"}"#.utf8)))
        XCTAssertThrowsError(try finish().get())
        XCTAssertNil(LineReader(client).readLine(limit: 1024), "the server sends nothing back")

        // After a proper hello.
        tearDown(); setUp()
        finish = serve { try $0.receive() }
        let reader = LineReader(client)
        XCTAssertTrue(LineReader.writeLine(client, SecureChannel.hello(SecureChannel.randomNonce())))
        XCTAssertNotNil(reader.readLine(limit: 1024).flatMap(SecureChannel.parseHello))
        XCTAssertTrue(LineReader.writeLine(client, Data(#"{"op":"list"}"#.utf8)))
        XCTAssertThrowsError(try finish().get())
    }

    func testClientRefusesAnUnauthenticatedAnswer() throws {
        // A stand-in that answers with a plain-text "allowed" instead of a hello.
        let fd = server
        DispatchQueue.global().async {
            _ = LineReader(fd).readLine(limit: 1024)
            _ = LineReader.writeLine(fd, Data(#"{"ok":true,"outcome":"allowed"}"#.utf8))
        }
        XCTAssertThrowsError(try SecureChannel.client(fd: client, key: key))
    }

    func testLineReaderNeverReturnsALineLongerThanItsLimit() {
        // A 60 KB line, newline included, is refused at a 1 KB limit. Written from another
        // thread: the socket buffer is smaller than the line.
        let written = DispatchSemaphore(value: 0)
        let fd = server
        DispatchQueue.global().async { _ = LineReader.writeLine(fd, Data(repeating: 0x41, count: 60_000)); written.signal() }
        XCTAssertNil(LineReader(client).readLine(limit: 1024))
        // Drain the rest so the writer finishes before the next pair exists.
        _ = fcntl(client, F_SETFL, O_NONBLOCK)
        var sink = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(5)
        while written.wait(timeout: .now() + 0.01) != .success, Date() < deadline { _ = read(client, &sink, sink.count) }

        // Exactly at the limit is fine, and what follows stays for the next line.
        tearDown(); setUp()
        let fd2 = server
        DispatchQueue.global().async {
            _ = LineReader.writeLine(fd2, Data(repeating: 0x42, count: 1024) + Data("\nnext".utf8)); written.signal()
        }
        let reader = LineReader(client)
        XCTAssertEqual(reader.readLine(limit: 1024)?.count, 1024)
        XCTAssertEqual(reader.readLine(limit: 1024), Data("next".utf8))
        XCTAssertEqual(written.wait(timeout: .now() + 5), .success)
    }

    func testHelloMustBeExact() {
        XCTAssertNotNil(SecureChannel.parseHello(SecureChannel.hello(Data(repeating: 7, count: 32))))
        XCTAssertNil(SecureChannel.parseHello(SecureChannel.hello(Data(repeating: 7, count: 16))))
        XCTAssertNil(SecureChannel.parseHello(Data(#"{"channel":"keynod/0","nonce":"AAAA"}"#.utf8)))
        XCTAssertNil(SecureChannel.parseHello(Data(#"{"op":"list"}"#.utf8)))
    }
}
