import Darwin
import XCTest

/// In the test runner "this program" is the xctest tool, so a socket pair
/// inside this process passes, and a different program (nc) does not.
final class PeerIdentityTests: XCTestCase {
    func testThisProgramPasses() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { fds.forEach { close($0) } }
        switch PeerIdentity.verify(fds[0]) {
        case .success(let peer):
            XCTAssertEqual(peer.pid, getpid())
            XCTAssertEqual(peer.uid, getuid())
            XCTAssertTrue(PeerIdentity.isAlive(peer), "the audit token still names this running process")
        case .failure(let failure):
            XCTFail("own process refused: \(failure)")
        }
    }

    func testAnotherProgramIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("peer-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("s.sock").path

        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(server) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        XCTAssertLessThan(bytes.count, MemoryLayout.size(ofValue: addr.sun_path))
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes); $0[bytes.count] = 0 }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(server, 1), 0)

        let nc = Process()
        nc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        nc.arguments = ["-U", path]
        nc.standardInput = Pipe()
        nc.standardOutput = FileHandle.nullDevice
        nc.standardError = FileHandle.nullDevice
        try nc.run()
        defer { nc.terminate() }

        let client = Darwin.accept(server, nil, nil)
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { close(client) }
        switch PeerIdentity.verify(client) {
        case .success: XCTFail("nc must not pass as this program")
        case .failure(let failure): XCTAssertFalse(failure.otherUser)
        }
    }
}
