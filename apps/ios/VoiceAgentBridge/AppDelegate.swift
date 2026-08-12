import UIKit
import UserNotifications

enum RemoteNotificationWakeHint: String, Equatable {
    case command
    case session

    static let payloadKey = "wake_hint"

    init?(userInfo: [AnyHashable: Any]) {
        if let rawHint = userInfo[Self.payloadKey] {
            guard let hint = rawHint as? String else { return nil }
            self.init(rawValue: hint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            return
        }

        // Opaque identifiers from older alert payloads are accepted only as
        // wake hints. Their values are deliberately not retained or applied.
        if Self.hasOpaqueIdentifier(userInfo["command_id"]) {
            self = .command
        } else if Self.hasOpaqueIdentifier(userInfo["session_id"]) {
            self = .session
        } else {
            return nil
        }
    }

    private static func hasOpaqueIdentifier(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf8.count <= 128
    }
}

final class BackgroundReconciliationRequest {
    let hint: RemoteNotificationWakeHint

    private let lock = NSLock()
    private var isClaimed = false
    private var completionHandler: ((UIBackgroundFetchResult) -> Void)?

    init(
        hint: RemoteNotificationWakeHint,
        completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        self.hint = hint
        self.completionHandler = completionHandler
    }

    /// Claims this request for one REST reconciliation task.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard completionHandler != nil, !isClaimed else { return false }
        isClaimed = true
        return true
    }

    /// Finishes the UIKit background fetch exactly once, including timeout races.
    func complete(_ result: UIBackgroundFetchResult) {
        lock.lock()
        let completion = completionHandler
        completionHandler = nil
        lock.unlock()
        completion?(result)
    }
}

final class BackgroundReconciliationDispatcher {
    static let shared = BackgroundReconciliationDispatcher()

    typealias Handler = (BackgroundReconciliationRequest) -> Void

    private let lock = NSLock()
    private var handler: Handler?
    private var pending: [BackgroundReconciliationRequest] = []

    func submit(_ request: BackgroundReconciliationRequest) {
        lock.lock()
        if let handler {
            lock.unlock()
            handler(request)
        } else {
            pending.append(request)
            lock.unlock()
        }
    }

    /// Installs the process-level consumer and drains requests received during
    /// a pure background launch before any SwiftUI view appears.
    func bind(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        let queued = pending
        pending.removeAll()
        lock.unlock()
        queued.forEach(handler)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var onDeviceToken: ((String) -> Void)?
    var onAuthorizationStatus: ((UNAuthorizationStatus) -> Void)?
    var onNotificationDiagnostics: ((NotificationDiagnostics) -> Void)?
    private var onNotificationTap: ((String) -> Void)?
    private var pendingNotificationSessionId: String?
    private let backgroundReconciliationDispatcher: BackgroundReconciliationDispatcher
    private let backgroundCompletionTimeout: TimeInterval

    override init() {
        backgroundReconciliationDispatcher = .shared
        backgroundCompletionTimeout = 25
        super.init()
    }

    init(
        backgroundReconciliationDispatcher: BackgroundReconciliationDispatcher,
        backgroundCompletionTimeout: TimeInterval = 25
    ) {
        self.backgroundReconciliationDispatcher = backgroundReconciliationDispatcher
        self.backgroundCompletionTimeout = backgroundCompletionTimeout
        super.init()
    }

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

    func handleRemoteNotification(
        _ userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let hint = RemoteNotificationWakeHint(userInfo: userInfo) else {
            completionHandler(.noData)
            return
        }

        let request = BackgroundReconciliationRequest(
            hint: hint,
            completionHandler: completionHandler
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + backgroundCompletionTimeout) {
            request.complete(.failed)
        }

        backgroundReconciliationDispatcher.submit(request)
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

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        handleRemoteNotification(userInfo, fetchCompletionHandler: completionHandler)
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
