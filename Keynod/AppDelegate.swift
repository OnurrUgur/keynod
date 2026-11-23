import AppKit
import Combine
import Carbon.HIToolbox
import LocalAuthentication
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var statusBar: StatusBarController!
    private var hotKey: HotKey?
    private var mainWindow: NSWindow?
    private var awakeObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One Keynod at a time, before anything reads the vault.
        guard Self.claimSingleInstance() else {
            NSLog("%@", "Keynod: another copy is already running; quitting")
            exit(0)
        }
        UserDefaults.standard.register(defaults: [
            Prefs.Key.keyCatcherEnabled: true,
        ])
        Vault.selfTestIfRequested()
        Backup.selfTestIfRequested()
        PhoneLink.cleanUpIfRequested()

        CLIServer.shared.start()
        StayAwake.shared.start()
        PasteboardWatcher.shared.start()

        awakeObserver = StayAwake.shared.$until
            .removeDuplicates()
            .sink { PhoneLink.shared.publishAwake(until: $0) }

        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = buildMainMenu()

        let open: (UUID?) -> Void = { [weak self] id in self?.openMain(select: id) }
        let openSection: (MainSection) -> Void = { [weak self] section in self?.openMain(section: section) }
        statusBar = StatusBarController(onOpen: open, onOpenSection: openSection)
        settleDockIcon()

        // Global ⌥⌘K opens the quick vault lookup popover.
        hotKey = HotKey(keyCode: kVK_ANSI_K, modifiers: cmdKey | optionKey) { [weak self] in
            self?.statusBar.toggle()
        }

        if Store.shared.secrets.isEmpty { openMain(select: nil) }
        var notices: [Notice] = []
        if !Store.shared.trusted {
            notices.append(Notice(title: "Check your secrets before the keynod command can use them", text: """
            Keynod's list of secrets (vault.json) was changed outside the app, or has no seal. A changed list \
            could make an approval name a different secret than the one it releases, so the keynod command \
            releases nothing for now.

            Look through the list in the Vault. If every title and field is yours, choose Trust Current Vault \
            (also in the Keynod menu) and confirm with Touch ID.
            """ + (Store.shared.sealProblem.map { "\n\nThe seal key is unavailable: \($0)." } ?? ""), offersTrust: true))
        }
        // Decided by what the keychain answered when the CLI channel key was set up.
        if CLIServer.shared.channelLocation == .file {
            notices.append(Notice(title: "This Keynod build can't store secrets", text: """
            The keychain refused it (error -34018): it was built without an Apple Developer Team ID, so it \
            has no keychain access group, and the Vault refuses every save and read.

            Set KEYNOD_TEAM_ID and KEYNOD_ENTITLEMENTS in Local.xcconfig, then run `make install`.
            """))
        } else if let problem = CLIServer.shared.channelProblem {
            notices.append(Notice(title: "The keynod command is unavailable",
                                  text: "Keynod couldn't set up the key that protects its command line: \(problem)."))
        }
        present(notices)
    }

    // MARK: One copy at a time

    /// Held for the life of the process.
    private static var instanceLock: Int32 = -1

    /// False when another Keynod already runs: one that Launch Services knows by
    /// this bundle id and that started first, or one holding the lock in this
    /// data folder (which also catches a copy started straight from the binary).
    /// A second copy could otherwise load a prepared vault and share the
    /// Keychain items and channel key.
    private static func claimSingleInstance() -> Bool {
        let me = NSRunningApplication.current
        let mine = me.launchDate ?? Date()
        let earlier = NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.bundleID).filter {
            $0.processIdentifier != me.processIdentifier && !$0.isTerminated
                && (($0.launchDate ?? .distantPast) < mine
                    || (($0.launchDate ?? .distantPast) == mine && $0.processIdentifier < me.processIdentifier))
        }
        if let other = earlier.first {
            other.activate()
            return false
        }
        Store.makeDataDir()
        let path = Store.dataDir.appendingPathComponent("keynod.lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        instanceLock = fd
        return true
    }

    // MARK: Notices

    private struct Notice {
        let title: String
        let text: String
        var offersTrust = false
    }

    /// Said once per launch, plainly, one after another. Sheets, not `runModal`:
    /// the CLI server needs the main queue while a notice is up.
    private func present(_ notices: [Notice]) {
        guard let notice = notices.first else { return }
        openMain(select: nil)
        guard let window = mainWindow else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = notice.title
        alert.informativeText = notice.text
        if notice.offersTrust {
            alert.addButton(withTitle: "Trust Current Vault\u{2026}")
            alert.addButton(withTitle: "Later")
        } else {
            alert.addButton(withTitle: "OK")
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            if notice.offersTrust, response == .alertFirstButtonReturn { self?.trustCurrentVault() }
            DispatchQueue.main.async { self?.present(Array(notices.dropFirst())) }
        }
    }

    /// The user's explicit, Touch ID-confirmed word that the secrets listed are theirs.
    @objc private func trustCurrentVault() {
        guard !Store.shared.trusted else { return }
        let count = Store.shared.items.count
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason:
            "confirm that the \(count) secret\(count == 1 ? "" : "s") listed in Keynod are yours, so the keynod command may release them"
        ) { ok, _ in
            DispatchQueue.main.async {
                if ok { Store.shared.trustCurrentVault() }
                context.invalidate()
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(trustCurrentVault) ? !Store.shared.trusted : true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMain(select: nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        StayAwake.shared.stop()
        PhoneLink.shared.finishPublishingAwake()
        Store.shared.saveNow()
    }

    // MARK: Main window

    func openMain(select id: UUID?) {
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: MainWindow.defaultSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Keynod"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = Theme.nsBackground
            window.isReleasedWhenClosed = false
            window.contentMinSize = MainWindow.minSize
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.contentView = NSHostingView(rootView: MainView())
            window.center()
            window.setFrameAutosaveName("KeynodMainWindow")
            window.delegate = self
            mainWindow = window
            AppModel.shared.window = window
        }
        if let id, Store.shared.secret(id) != nil {
            AppModel.shared.section = .vault
            AppModel.shared.selection = id
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func openMain(section: MainSection) {
        AppModel.shared.section = section
        openMain(select: nil)
    }

    private func settleDockIcon(windowOpen: Bool = false) {
        let inMenuBar = statusBar?.isInMenuBar ?? true
        NSApp.setActivationPolicy(windowOpen || !inMenuBar ? .regular : .accessory)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow else { return }
        settleDockIcon()
        VaultSession.shared.lock()
    }

    // MARK: Menu actions

    @objc private func newSecret() {
        openMain(section: .vault)
        AppModel.shared.newSecret()
    }

    @objc private func openSettings() {
        openMain(section: .settings)
    }

    @MainActor @objc private func exportVault() { BackupFlow.export() }
    @MainActor @objc private func importVault() { BackupFlow.importVault() }

    @objc private func focusSearch() {
        openMain(section: .vault)
        AppModel.shared.vaultSearchToken += 1
    }

    @objc private func deleteSecret() {
        guard let id = AppModel.shared.visibleSelection else { return }
        AppModel.shared.delete(id)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("%@", "Keynod: launch at login failed: \(error)")
        }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem()
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            holder.submenu = menu
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector?, _ key: String,
                  _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }

        let login = item("Launch at Login", #selector(toggleLaunchAtLogin(_:)), "", target: self)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        submenu("Keynod", [
            item("Settings\u{2026}", #selector(openSettings), ",", target: self),
            item("Trust Current Vault\u{2026}", #selector(trustCurrentVault), "", target: self),
            login,
            .separator(),
            item("Hide Keynod", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            item("Quit Keynod", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("File", [
            item("New Secret", #selector(newSecret), "n", target: self),
            .separator(),
            item("Export Vault\u{2026}", #selector(exportVault), "", target: self),
            item("Import Vault\u{2026}", #selector(importVault), "", target: self),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Find in Vault", #selector(focusSearch), "f", target: self),
        ])
        submenu("Secret", [
            item("Delete Secret", #selector(deleteSecret), "\u{8}", [.command, .option], target: self),
        ])
        submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        return main
    }
}
