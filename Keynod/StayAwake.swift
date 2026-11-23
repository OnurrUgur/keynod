import Foundation
import IOKit.ps

/// Keeps the Mac awake overnight (even with the lid closed and monitors off) using
/// a narrowly scoped sudoers rule for `pmset -a disablesleep 1|0`.
@MainActor
final class StayAwake: ObservableObject {
    static let shared = StayAwake()

    @Published private(set) var until: Date?
    @Published private(set) var needsSetup = false
    @Published private(set) var notice: String?

    var untilText: String? { until.map(LinkAwake.clock) }

    static let setupCommand =
        "echo \"\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0\""
        + " | sudo EDITOR=tee visudo -f /etc/sudoers.d/keynod-pmset"

    private static let defaultsKey = "stayAwakeUntil"

    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var busy = false
    private var noticeToken = 0

    private init() {}

    func start() {
        let saved = UserDefaults.standard.object(forKey: Self.defaultsKey) as? Date
        if let saved, saved > Date(), Self.onACPower {
            engage(until: saved)
            return
        }
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        Task {
            let stuck = await Task.detached { Self.sleepIsDisabled() }.value
            guard stuck else { return }
            let ok = await Task.detached { Self.setSleepDisabled(false) }.value
            if !ok { NSLog("Keynod stay awake: sleep is disabled and could not be re-enabled") }
        }
    }

    func stop() {
        guard until != nil else { return }
        if !Self.setSleepDisabled(false) { NSLog("Keynod stay awake: could not re-enable sleep on quit") }
        finish()
    }

    func toggle() {
        if until == nil { turnOn() } else { turnOff() }
    }

    func turnOn() {
        let morning = Calendar.current.nextDate(
            after: Date(), matching: DateComponents(hour: 9, minute: 0), matchingPolicy: .nextTime
        )
        engage(until: morning ?? Date().addingTimeInterval(8 * 3600))
    }

    func turnOff() {
        guard until != nil, !busy else { return }
        busy = true
        Task {
            let ok = await Task.detached { Self.setSleepDisabled(false) }.value
            busy = false
            if !ok { NSLog("Keynod stay awake: could not re-enable sleep") }
            finish()
        }
    }

    private func engage(until end: Date) {
        guard until == nil, !busy else { return }
        guard Self.onACPower else {
            NSLog("Keynod stay awake: not on AC power, staying off")
            showNotice("Plug in charger")
            return
        }
        busy = true
        Task {
            let ok = await Task.detached { Self.setSleepDisabled(true) }.value
            busy = false
            guard ok else {
                needsSetup = true
                return
            }
            needsSetup = false
            until = end
            UserDefaults.standard.set(end, forKey: Self.defaultsKey)
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Keynod keeps the Mac awake overnight"
            )
        }
    }

    private func finish() {
        until = nil
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        timer?.invalidate()
        timer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func check() {
        guard let until else { return }
        if Date() >= until || !Self.onACPower { turnOff() }
    }

    private func showNotice(_ text: String, for seconds: TimeInterval = 2) {
        noticeToken += 1
        let token = noticeToken
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.noticeToken == token { self?.notice = nil }
        }
    }

    nonisolated static var onACPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPSACPowerValue
    }

    nonisolated private static func setSleepDisabled(_ disabled: Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            NSLog("%@", "Keynod stay awake: could not run sudo: \(error)")
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    nonisolated private static func sleepIsDisabled() -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        return output.split(whereSeparator: \.isNewline).contains { line in
            let words = line.split(whereSeparator: \.isWhitespace)
            return words.count >= 2 && words[0] == "SleepDisabled" && words[1] == "1"
        }
    }
}
