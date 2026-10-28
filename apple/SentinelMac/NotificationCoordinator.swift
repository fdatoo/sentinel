import Foundation
import SentinelKit
@preconcurrency import UserNotifications

/// What the user did with a notification, reduced to Sendable values.
struct NotificationEvent: Sendable {
    let requestID: String
    /// An option id, or `UNNotificationDefaultActionIdentifier` for a plain click.
    let actionID: String
}

/// Owns the notification center delegate. It holds no mutable state, so it is
/// safe to call from the center's own queues.
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private let onEvent: @Sendable (NotificationEvent) async -> Void

    init(onEvent: @escaping @Sendable (NotificationEvent) async -> Void) {
        self.onEvent = onEvent
        super.init()
    }

    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        NotificationCategories.register(on: center)
    }

    func requestAuthorization() async {
        // Time-sensitive delivery comes from the entitlement and the
        // interruption level; it has no authorization option of its own.
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    func post(_ request: Request) async {
        let content = UNMutableNotificationContent()
        content.title = request.notificationTitle
        content.body = request.notificationBody
        content.categoryIdentifier = NotificationCategories.category(for: request)
        content.userInfo = ["request_id": request.id]
        content.threadIdentifier = "sentinel"
        if request.urgency == .low {
            content.interruptionLevel = .passive
        } else {
            content.interruptionLevel = .timeSensitive
            content.sound = .default
        }
        // Reusing the request id replaces an earlier notification for it.
        let notification = UNNotificationRequest(identifier: request.id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(notification)
    }

    func remove(requestID: String) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [requestID])
        center.removePendingNotificationRequests(withIdentifiers: [requestID])
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let requestID = response.notification.request.content.userInfo["request_id"] as? String
            ?? response.notification.request.identifier
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else { return }
        await onEvent(NotificationEvent(requestID: requestID, actionID: response.actionIdentifier))
    }
}
