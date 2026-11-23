import SwiftUI

@main
struct KeynodPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(PhoneModel.shared)
        }
    }
}

/// Pairing until there is a Mac, then the list of its requests.
struct RootView: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.pairedMac == nil {
                PairView()
            } else {
                RequestsView()
            }
        }
        .animation(.default, value: model.pairedMac == nil)
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                model.didBecomeActive()
            } else {
                model.didResignActive()
            }
        }
    }
}
