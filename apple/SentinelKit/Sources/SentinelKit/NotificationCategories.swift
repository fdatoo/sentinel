import Foundation
import UserNotifications

/// The notification category table from api.md. Both apps register every row up
/// front; the hub names the category in the APNs payload and the Mac picks it
/// with `category(for:)`.
public enum NotificationCategories {
    public static let authorizeTwo = "sentinel.authorize.2"
    public static let authorizeHook = "sentinel.authorize.hook"
    public static let actionTwo = "sentinel.action.2"
    public static let open = "sentinel.open"

    private struct Layout {
        var category: String
        var kind: RequestKind
        var allowText: Bool
        var options: [(id: String, label: String)]
    }

    private static let layouts: [Layout] = [
        Layout(
            category: authorizeTwo, kind: .authorize, allowText: false,
            options: [("approve", "Approve"), ("deny", "Deny")]
        ),
        Layout(
            category: authorizeHook, kind: .authorize, allowText: true,
            options: [("allow", "Allow"), ("always", "Always allow"), ("deny", "Deny")]
        ),
        Layout(
            category: actionTwo, kind: .action, allowText: false,
            options: [("done", "Done"), ("cant", "Can't")]
        ),
    ]

    /// The category identifier the hub would pick for this request. A row matches
    /// only when kind, option ids and labels (in order) and `allow_text` all agree;
    /// sensitive requests always get `sentinel.open`.
    public static func category(for request: Request) -> String {
        if request.sensitive { return open }
        for layout in layouts where matches(request, layout) {
            return layout.category
        }
        return open
    }

    private static func matches(_ request: Request, _ layout: Layout) -> Bool {
        guard request.kind == layout.kind,
              request.allowText == layout.allowText,
              request.options.count == layout.options.count
        else { return false }
        for (option, expected) in zip(request.options, layout.options) {
            if option.id != expected.id || option.label != expected.label { return false }
        }
        return true
    }

    /// Every category, built fresh. Exposed separately from `register` so tests
    /// can inspect actions without a notification center.
    public static func makeCategories() -> Set<UNNotificationCategory> {
        var categories = Set<UNNotificationCategory>()

        categories.insert(UNNotificationCategory(
            identifier: authorizeTwo,
            actions: [
                UNNotificationAction(identifier: "approve", title: "Approve", options: [.authenticationRequired]),
                UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive]),
            ],
            intentIdentifiers: []
        ))
        categories.insert(UNNotificationCategory(
            identifier: authorizeHook,
            actions: [
                UNNotificationAction(identifier: "allow", title: "Allow", options: [.authenticationRequired]),
                UNNotificationAction(identifier: "always", title: "Always allow", options: [.authenticationRequired]),
                UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive]),
            ],
            intentIdentifiers: []
        ))
        categories.insert(UNNotificationCategory(
            identifier: actionTwo,
            actions: [
                UNNotificationAction(identifier: "done", title: "Done", options: []),
                UNNotificationAction(identifier: "cant", title: "Can't", options: []),
            ],
            intentIdentifiers: []
        ))
        categories.insert(UNNotificationCategory(identifier: open, actions: [], intentIdentifiers: []))

        return categories
    }

    public static func register(on center: UNUserNotificationCenter) {
        center.setNotificationCategories(makeCategories())
    }
}
