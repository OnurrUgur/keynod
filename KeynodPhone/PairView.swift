import SwiftUI

struct PairView: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var cameraFailed = false
    @State private var cameraCheck = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .frame(maxWidth: 480)
                    .padding(20)
                    .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Pair with your Mac")
        }
        .animation(.default, value: model.pairing)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { cameraCheck += 1 }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.pairing {
        case .idle: start
        case .starting, .done: working
        case .waitingForMac(let code): waiting(code)
        case .failed(let message): failed(message)
        }
    }

    private var start: some View {
        VStack(spacing: 20) {
            Text("On your Mac open Keynod Settings → Pair iPhone…, then scan the QR code.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            let _ = cameraCheck
            if QRScanner.isAvailable && !cameraFailed {
                QRScanner(onCode: { model.pair(qrText: $0) }, onUnavailable: { cameraFailed = true })
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .accessibilityLabel("Camera: point it at the code on your Mac")
            } else if QRScanner.cameraBlocked || cameraFailed {
                cameraOff
            }

            Button {
                model.pair(qrText: UIPasteboard.general.string ?? "")
            } label: {
                Label("Paste Code", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private var cameraOff: some View {
        VStack(spacing: 10) {
            Label("Camera access is off for Keynod, so it can't scan the code.", systemImage: "camera")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") { openSettings() }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .keynodCard()
    }

    private var working: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Contacting your Mac through iCloud…")
                .foregroundStyle(.secondary)
        }
        .padding(.top, 60)
    }

    private func waiting(_ code: String) -> some View {
        VStack(spacing: 20) {
            if let mac = model.pairingMacName {
                Text("Pairing with \(mac.visibleText)")
                    .font(.headline)
            }
            Text(code)
                .font(.system(size: 48, weight: .semibold, design: .monospaced))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                .keynodCard()
                .accessibilityLabel(code.filter(\.isNumber).map(String.init).joined(separator: " "))
            Text("Check that your Mac shows the same code, then click Pair on the Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            ProgressView()
            Button("Cancel", role: .cancel) { model.cancelPairing() }
                .controlSize(.large)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
            Button("Try Again") { model.resetPairing() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(.top, 40)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}
