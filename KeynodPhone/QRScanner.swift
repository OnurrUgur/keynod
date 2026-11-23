import SwiftUI
import VisionKit

struct QRScanner: UIViewControllerRepresentable {
    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    static var cameraBlocked: Bool {
        DataScannerViewController.isSupported && !DataScannerViewController.isAvailable
    }

    var onCode: (String) -> Void
    var onUnavailable: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode, onUnavailable: onUnavailable)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .accurate,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
        context.coordinator.onUnavailable = onUnavailable
        if !scanner.isScanning {
            do {
                try scanner.startScanning()
            } catch {
                phoneLog("couldn't start the camera scanner: \(error.localizedDescription)")
                let unavailable = context.coordinator.onUnavailable
                Task { @MainActor in unavailable() }
            }
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void
        var onUnavailable: () -> Void
        private var delivered = false

        init(onCode: @escaping (String) -> Void, onUnavailable: @escaping () -> Void) {
            self.onCode = onCode
            self.onUnavailable = onUnavailable
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            consider(addedItems, in: dataScanner)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            consider(updatedItems, in: dataScanner)
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            phoneLog("camera scanner became unavailable: \(error)")
            onUnavailable()
        }

        private func consider(_ items: [RecognizedItem], in scanner: DataScannerViewController) {
            guard !delivered else { return }
            for case .barcode(let barcode) in items {
                guard let text = barcode.payloadStringValue, text.hasPrefix(Link.pairingPrefix) else { continue }
                delivered = true
                scanner.stopScanning()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onCode(text)
                return
            }
        }
    }
}
