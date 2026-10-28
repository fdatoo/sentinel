import SentinelKit
import SwiftUI
@preconcurrency import UserNotifications

@main
struct SentinelPhoneApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView(model: AppModel.shared)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        NotificationCategories.register(on: center)
        Task {
            // Time-sensitive delivery needs the entitlement and the payload's
            // interruption level, not an authorization option.
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            application.registerForRemoteNotifications()
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        AppModel.shared.setAPNsToken(hex)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AppModel.shared.apnsRegistrationFailed(error)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let requestID = userInfo["retract"] as? String else {
            completionHandler(.noData)
            return
        }
        // The hub uses the request id as apns-collapse-id, and iOS uses the
        // collapse id as the notification identifier.
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [requestID])
        Task { @MainActor in
            await AppModel.shared.retracted(requestID: requestID)
            completionHandler(.newData)
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let requestID = userInfo["request_id"] as? String ?? response.notification.request.identifier
        let action = response.actionIdentifier

        switch action {
        case UNNotificationDismissActionIdentifier:
            return
        case UNNotificationDefaultActionIdentifier:
            await AppModel.shared.open(requestID: requestID)
        default:
            await AppModel.shared.answerFromNotification(requestID: requestID, optionID: action)
        }
    }
}
