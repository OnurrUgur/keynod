import Darwin
import Foundation
import Security

/// Who is on the other end of a connected `keynod.sock`, as the kernel reports it.
///
/// Both ends require the other to be this very program: the peer's code must
/// satisfy our own designated requirement. The `keynod` command is the app
/// binary run through a symlink, so the real command and the real app always
/// pass; a same-user script speaking the JSON protocol, another app, or a
/// stand-in listening on the socket path while the app is not running do not.
/// The process is named by its audit token, which (unlike a bare pid) can't be
/// recycled by another process.
///
/// This is the first layer only. The kernel reports the token of whatever
/// process holds the peer's pid when asked, so a process can connect, write,
/// then exec the real binary and pass. `SecureChannel` binds the request
/// itself to a key only this program can read.
enum PeerIdentity {
    struct Peer {
        let pid: pid_t
        let uid: uid_t
        /// Names this very process (pid and pid version), so a later check can
        /// tell whether it has exited or exec'd something else since.
        let token: audit_token_t
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        /// The peer runs as another user. The server drops such connections without an answer.
        var otherUser = false
    }

    /// This process's designated requirement, worked out once. A failure means
    /// this build has no code signature to compare peers against; then every
    /// peer is refused.
    private static let ownRequirement: Result<SecRequirement, Failure> = {
        var me: SecCode?
        var status = SecCodeCopySelf([], &me)
        guard status == errSecSuccess, let me else {
            return .failure(Failure(description: "this build's code signature can't be read (\(status))"))
        }
        var staticCode: SecStaticCode?
        status = SecCodeCopyStaticCode(me, [], &staticCode)
        guard status == errSecSuccess, let staticCode else {
            return .failure(Failure(description: "this build's code signature can't be read (\(status))"))
        }
        var requirement: SecRequirement?
        status = SecCodeCopyDesignatedRequirement(staticCode, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            return .failure(Failure(description: "this build has no designated code requirement (\(status))"))
        }
        return .success(requirement)
    }()

    /// Hardened runtime on and no `get-task-allow`: then a peer must be the same,
    /// or a debuggable build signed by the same team would pass the designated
    /// requirement and could be attached to.
    private static let ownIsStrict: Bool = {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return false }
        return signing(of: me).map { $0.hardened && !$0.debuggable } ?? false
    }()

    private static func signing(of code: SecCode) -> (hardened: Bool, debuggable: Bool)? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        let debuggable = (entitlements["com.apple.security.get-task-allow"] as? Bool) ?? false
        return (flags & SecCodeSignatureFlags.runtime.rawValue != 0, debuggable)
    }

    /// True while the process the token names still runs the same program
    /// image (it has neither exited nor exec'd since it was checked).
    static func isAlive(_ peer: Peer) -> Bool {
        var token = peer.token
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        return SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code) == errSecSuccess
            && code != nil
    }

    /// Checks the peer of a connected Unix socket: same user, and code that
    /// satisfies our own designated requirement.
    static func verify(_ fd: Int32) -> Result<Peer, Failure> {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else {
            return .failure(Failure(description: "the peer's credentials can't be read"))
        }
        guard uid == getuid() else {
            return .failure(Failure(description: "the peer runs as another user", otherUser: true))
        }

        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              Int(length) == MemoryLayout<audit_token_t>.size else {
            return .failure(Failure(description: "the peer's audit token can't be read"))
        }
        let pid = audit_token_to_pid(token)
        guard pid > 0, audit_token_to_euid(token) == getuid() else {
            return .failure(Failure(description: "the peer's audit token doesn't match its credentials"))
        }

        let requirement: SecRequirement
        switch ownRequirement {
        case .success(let r): requirement = r
        case .failure(let f): return .failure(f)
        }

        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        var status = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code)
        guard status == errSecSuccess, let code else {
            return .failure(Failure(description: "process \(pid) can't be identified (\(status))"))
        }
        status = SecCodeCheckValidity(code, [], requirement)
        guard status == errSecSuccess else {
            return .failure(Failure(description: "process \(pid) is not this Keynod build (\(status))"))
        }
        if ownIsStrict {
            guard let peer = signing(of: code), peer.hardened, !peer.debuggable else {
                return .failure(Failure(description: "process \(pid) is a debuggable or unhardened build"))
            }
        }
        return .success(Peer(pid: pid, uid: uid, token: token))
    }
}
