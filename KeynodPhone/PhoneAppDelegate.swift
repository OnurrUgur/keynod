import UIKit
import UserNotifications

enum KeynodNotification {
    static let category = "KEYNOD_REQUEST"
    static let approve = "approve"
    static let deny = "deny"
}

@MainActor
final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let approve = UNNotificationAction(identifier: KeynodNotification.approve, title: "Approve",
                                           options: [.foreground, .authenticationRequired])
        let deny = UNNotificationAction(identifier: KeynodNotification.deny, title: "Deny",
                                        options: [.destructive, .authenticationRequired])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: KeynodNotification.category, actions: [approve, deny],
                                   intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: "Your Mac asks for approval",
                                   options: [])
        ])
        if PhoneModel.shared.pairedMac != nil {
            application.registerForRemoteNotifications()
            Task { await PhoneModel.shared.ensureSubscriptions() }
        }
        return true
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        phoneLog("couldn't register for remote notifications: \(error.localizedDescription)")
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task {
            await PhoneModel.shared.refresh()
            completionHandler(.newData)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
        Task { @MainActor in await PhoneModel.shared.refresh() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = PhoneModel.requestID(from: response.notification.request.content.userInfo)
        let action = response.actionIdentifier
        Task { @MainActor in
            let model = PhoneModel.shared
            switch action {
            case KeynodNotification.approve:
                completionHandler()
                guard let id else { return }
                model.focus(id)
                await model.refresh()
                if model.startsFaceID(for: id) { await model.approve(id) }
            case KeynodNotification.deny:
                if let id { await Self.withBackgroundTime { await model.deny(id) } }
                completionHandler()
            case UNNotificationDefaultActionIdentifier:
                if let id { model.focus(id) }
                completionHandler()
                await model.refresh()
            default:
                completionHandler()
            }
        }
    }

    private static func withBackgroundTime(_ work: () async -> Void) async {
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "keynod-deny") {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        await work()
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
    }
}
