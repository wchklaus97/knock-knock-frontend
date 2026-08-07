import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var onDeviceToken: ((String) -> Void)?
    var onAuthorizationStatus: ((UNAuthorizationStatus) -> Void)?
    var onNotificationDiagnostics: ((NotificationDiagnostics) -> Void)?
    private var onNotificationTap: ((String) -> Void)?
    private var pendingNotificationSessionId: String?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        let open = UNNotificationAction(
            identifier: "KNOCK_OPEN",
            title: "Review decision",
            options: [.foreground]
        )
        let dismiss = UNNotificationAction(
            identifier: "KNOCK_DISMISS",
            title: "Not now",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: "KNOCK_DECISION",
            actions: [open, dismiss],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
        refreshAuthorizationStatus()
        return true
    }

    func requestPushAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                print("[push] auth error: \(error.localizedDescription)")
            }
            print("[push] authorization granted=\(granted)")
            self.refreshAuthorizationStatus()
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func refreshAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.onAuthorizationStatus?(settings.authorizationStatus)
                self.onNotificationDiagnostics?(NotificationDiagnostics(settings: settings))
            }
        }
    }

    func bindNotificationTap(_ handler: @escaping (String) -> Void) {
        onNotificationTap = handler
        guard let sessionId = pendingNotificationSessionId else { return }
        pendingNotificationSessionId = nil
        DispatchQueue.main.async {
            handler(sessionId)
        }
    }

    private func routeNotificationTap(_ notification: UNNotification) {
        guard let sessionId = notification.request.content.userInfo["session_id"] as? String,
              !sessionId.isEmpty
        else { return }
        if let handler = onNotificationTap {
            DispatchQueue.main.async {
                handler(sessionId)
            }
        } else {
            pendingNotificationSessionId = sessionId
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[push] device token \(token.prefix(12))… (\(token.count) chars)")
        onDeviceToken?(token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[push] register failed: \(error.localizedDescription)")
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner even while Knock Knock is in the foreground.
        completionHandler([.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier ||
            response.actionIdentifier == "KNOCK_OPEN" {
            routeNotificationTap(response.notification)
        }
        completionHandler()
    }
}
