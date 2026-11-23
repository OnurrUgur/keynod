import AppKit
import CloudKit
import CoreImage.CIFilterBuiltins
import LocalAuthentication
import SwiftUI

/// The "Pair iPhone" window. Closing it cancels the pairing.
@MainActor
final class PairingWindowController: NSObject, NSWindowDelegate {
    static let shared = PairingWindowController()
    private var window: NSWindow?
    private var model: PairingModel?

    func show() {
        if window == nil {
            let model = PairingModel()
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.title = "Pair iPhone"
            w.isReleasedWhenClosed = false
            w.backgroundColor = Theme.nsBackground
            w.contentView = NSHostingView(rootView: PairingView(model: model))
            w.delegate = self
            w.center()
            model.requestClose = { [weak w] in w?.close() }
            window = w
            self.model = model
        } else {
            model?.restartIfFinished()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model?.cancel()
        model = nil
        window = nil
    }
}

@MainActor
final class PairingModel: ObservableObject {
    enum Phase {
        case waiting(PairOffer, NSImage?)
        case confirm(PairOffer, PairReply, code: String)
        case working
        case done(name: String, prepared: Int, skipped: Int)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .working
    @Published private(set) var authenticating = false
    var requestClose: () -> Void = {}

    private var task: Task<Void, Never>?
    private var context: LAContext?

    init() { start() }

    func start() {
        task?.cancel()
        context?.invalidate()
        authenticating = false
        guard LinkCloud.shared.isConfigured else {
            phase = .failed("iCloud isn't configured for this build. Set KEYNOD_TEAM_ID and KEYNOD_ICLOUD_CONTAINER in Local.xcconfig and rebuild.")
            return
        }
        do {
            let offer = try PhoneLink.shared.makeOffer()
            phase = .waiting(offer, QRCode.image(for: offer.qrText, side: 280))
            task = Task { [weak self] in await self?.waitForPhone(offer) }
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    func restartIfFinished() {
        switch phase {
        case .done, .failed: start()
        default: break
        }
    }

    private func waitForPhone(_ offer: PairOffer) async {
        do {
            let (reply, code) = try await PhoneLink.shared.waitForReply(to: offer)
            guard !Task.isCancelled else { return }
            phase = .confirm(offer, reply, code: code)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(Self.message(for: error))
        }
    }

    func pair() {
        guard case .confirm(let offer, let reply, _) = phase, !authenticating else { return }
        guard Date() < offer.expires else {
            phase = .failed(Self.message(for: LinkError.expired))
            return
        }
        task = Task { [weak self] in await self?.pair(offer, reply) }
    }

    private func pair(_ offer: PairOffer, _ reply: PairReply) async {
        let context = LAContext()
        self.context = context
        authenticating = true
        defer { context.invalidate() }
        do {
            _ = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "pair \(Self.shortName(reply.phoneName)) to approve Keynod requests")
        } catch {
            authenticating = false
            guard !Task.isCancelled else { return }
            if let error = error as? LAError, [.userCancel, .appCancel, .systemCancel].contains(error.code) { return }
            phase = .failed(Self.message(for: error))
            return
        }
        authenticating = false
        phase = .working
        do {
            let result = try await PhoneLink.shared.completePairing(offer: offer, reply: reply, context: context)
            phase = .done(name: reply.phoneName, prepared: result.prepared, skipped: result.skipped)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(Self.message(for: error))
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        context?.invalidate()
        if case .confirm(let offer, _, _) = phase {
            Task.detached { await PhoneLink.shared.rejectPairing(offer) }
        }
    }

    private static func message(for error: Error) -> String {
        switch error as? LinkError {
        case .expired?: return "The pairing code expired. Try again."
        case .badSignature?: return "The reply didn't match this code. Try again."
        default: return PhoneLink.message(for: error)
        }
    }

    private static func shortName(_ name: String) -> String {
        let flat = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > 40 ? String(flat.prefix(39)) + "\u{2026}" : flat
    }
}

struct PairingView: View {
    @ObservedObject var model: PairingModel

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            content
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 420, height: 520)
        .background(Theme.bg)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .waiting(let offer, let qr):
            title("Scan this with Keynod on your iPhone")
            if let qr {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Text("Could not render QR code. Use Copy Code instead.")
                    .foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for iPhone\u{2026}").foregroundStyle(Theme.textSecondary)
            }
            CopyCodeButton(code: offer.qrText)
            Text("Expires in \(Int(Link.pairingTTL / 60)) minutes")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)

        case .confirm(_, let reply, let code):
            title("Pair with \(reply.phoneName)?")
            Text(code)
                .font(.system(size: 46, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text)
                .padding(.vertical, 6)
            Text("Check that the same 6-digit code appears on your iPhone.")
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 12) {
                Button("Cancel") { model.requestClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Pair") { model.pair() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
            .disabled(model.authenticating)

        case .working:
            ProgressView()
            Text("Preparing secrets for iPhone approval\u{2026}")
                .foregroundStyle(Theme.textSecondary)

        case .done(let name, let prepared, let skipped):
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(Theme.accent)
            title("Paired with \(name).")
            Text(Self.doneText(prepared: prepared, skipped: skipped))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Done") { model.requestClose() }
                .keyboardShortcut(.defaultAction)

        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.yellow)
            title("Pairing didn't finish")
            Text(message)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Close") { model.requestClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Try Again") { model.start() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Theme.text)
            .multilineTextAlignment(.center)
            .lineLimit(3)
    }

    private static func doneText(prepared: Int, skipped: Int) -> String {
        var text = prepared == 0
            ? "New secrets you save from now on can be approved from your iPhone."
            : "\(prepared) concealed field\(prepared == 1 ? "" : "s") ready for iPhone approval."
        if skipped > 0 { text += " \(skipped) empty field\(skipped == 1 ? "" : "s") skipped." }
        return text
    }
}

private struct CopyCodeButton: View {
    let code: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : "Copy Code") {
            Clipboard.copy(code, concealed: true)
            copied = true
        }
        .controlSize(.small)
    }
}

private enum QRCode {
    static func image(for text: String, side: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let raw = filter.outputImage else { return nil }

        let quiet = 4
        let total = Int(raw.extent.width) + 2 * quiet
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        let pixels = max(1, Int(side * backing) / total)
        let size = total * pixels
        let page = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: total, height: total))
        let image = raw
            .transformed(by: CGAffineTransform(translationX: CGFloat(quiet), y: CGFloat(quiet)))
            .composited(over: page)
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: CGFloat(pixels), y: CGFloat(pixels)))
        guard let cg = CIContext().createCGImage(image, from: CGRect(x: 0, y: 0, width: size, height: size)) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(size) / backing, height: CGFloat(size) / backing))
    }
}
