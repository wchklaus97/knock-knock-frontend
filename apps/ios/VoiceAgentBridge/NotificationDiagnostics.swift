import UserNotifications

struct NotificationDiagnostics: Equatable {
    let authorization: String
    let alert: String
    let alertStyle: String
    let notificationCenter: String
    let lockScreen: String
    let sound: String
    let scheduledDelivery: String

    var bannerReady: Bool {
        authorization == "authorized" &&
            alert == "enabled" &&
            notificationCenter == "enabled" &&
            alertStyle != "none"
    }

    var bannerStatusText: String {
        bannerReady
            ? "System banner prerequisites look enabled."
            : "System banner needs attention in iPhone Settings."
    }

    init(
        authorization: String,
        alert: String,
        alertStyle: String,
        notificationCenter: String,
        lockScreen: String,
        sound: String,
        scheduledDelivery: String,
    ) {
        self.authorization = authorization
        self.alert = alert
        self.alertStyle = alertStyle
        self.notificationCenter = notificationCenter
        self.lockScreen = lockScreen
        self.sound = sound
        self.scheduledDelivery = scheduledDelivery
    }

    init(settings: UNNotificationSettings) {
        self.init(
            authorization: Self.authorizationLabel(settings.authorizationStatus),
            alert: Self.settingLabel(settings.alertSetting),
            alertStyle: Self.alertStyleLabel(settings.alertStyle),
            notificationCenter: Self.settingLabel(settings.notificationCenterSetting),
            lockScreen: Self.settingLabel(settings.lockScreenSetting),
            sound: Self.settingLabel(settings.soundSetting),
            scheduledDelivery: Self.settingLabel(settings.scheduledDeliverySetting),
        )
    }

    private static func authorizationLabel(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    private static func settingLabel(_ setting: UNNotificationSetting) -> String {
        switch setting {
        case .notSupported: return "notSupported"
        case .disabled: return "disabled"
        case .enabled: return "enabled"
        @unknown default: return "unknown"
        }
    }

    private static func alertStyleLabel(_ style: UNAlertStyle) -> String {
        switch style {
        case .none: return "none"
        case .banner: return "banner"
        case .alert: return "alert"
        @unknown default: return "unknown"
        }
    }
}
