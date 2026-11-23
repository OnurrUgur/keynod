import Darwin
import Foundation

/// The app's bundle identifier, also when this binary runs as the `keynod`
/// command through a symlink outside the app (`~/.local/bin/keynod`). Then
/// `Bundle.main` is not the app bundle and has no identifier, so the bundle is
/// found from the real executable path instead. The app and the command must
/// agree on it: it names the keychain items they share.
enum AppIdentity {
    static let fallback = "dev.keynod.app"

    static let bundleID: String = {
        if let id = Bundle.main.bundleIdentifier, !id.isEmpty { return id }
        if let app = appBundleURL(), let id = Bundle(url: app)?.bundleIdentifier, !id.isEmpty { return id }
        return fallback
    }()

    /// `Keynod.app` that contains the real executable (symlinks resolved), if any.
    static func appBundleURL() -> URL? {
        guard let exe = realExecutablePath() else { return nil }
        let app = URL(fileURLWithPath: exe)
            .deletingLastPathComponent() // MacOS
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // Keynod.app
        return app.pathExtension == "app" ? app : nil
    }

    static func realExecutablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var raw = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&raw, &size) == 0 else { return nil }
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard realpath(raw, &resolved) != nil else { return nil }
        return String(cString: resolved)
    }
}
