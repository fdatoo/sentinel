import Testing
import UserNotifications
@testable import SentinelKit

@Suite struct NotificationCategoryTests {
    @Test func authorizeTwo() {
        let request = makeRequest(kind: .authorize, options: [("approve", "Approve"), ("deny", "Deny")])
        #expect(NotificationCategories.category(for: request) == "sentinel.authorize.2")
    }

    @Test func authorizeHook() {
        let request = makeRequest(
            kind: .authorize,
            options: [("allow", "Allow"), ("always", "Always allow"), ("deny", "Deny")],
            allowText: true
        )
        #expect(NotificationCategories.category(for: request) == "sentinel.authorize.hook")
    }

    @Test func actionTwo() {
        let request = makeRequest(kind: .action, options: [("done", "Done"), ("cant", "Can't")])
        #expect(NotificationCategories.category(for: request) == "sentinel.action.2")
    }

    @Test func fallThroughCases() {
        let approveDeny = [("approve", "Approve"), ("deny", "Deny")]
        let hook = [("allow", "Allow"), ("always", "Always allow"), ("deny", "Deny")]
        let doneCant = [("done", "Done"), ("cant", "Can't")]

        let cases: [(String, Request)] = [
            ("sensitive authorize.2", makeRequest(kind: .authorize, options: approveDeny, sensitive: true)),
            ("sensitive hook", makeRequest(kind: .authorize, options: hook, allowText: true, sensitive: true)),
            ("sensitive action", makeRequest(kind: .action, options: doneCant, sensitive: true)),
            ("authorize.2 with text", makeRequest(kind: .authorize, options: approveDeny, allowText: true)),
            ("hook without text", makeRequest(kind: .authorize, options: hook)),
            ("action with text", makeRequest(kind: .action, options: doneCant, allowText: true)),
            ("decision with approve/deny", makeRequest(kind: .decision, options: approveDeny)),
            ("decision with done/cant", makeRequest(kind: .decision, options: doneCant)),
            ("action with approve/deny", makeRequest(kind: .action, options: approveDeny)),
            ("authorize with done/cant", makeRequest(kind: .authorize, options: doneCant)),
            ("relabelled approve", makeRequest(kind: .authorize, options: [("approve", "Yes"), ("deny", "Deny")])),
            ("relabelled cant", makeRequest(kind: .action, options: [("done", "Done"), ("cant", "Cannot")])),
            ("case differs", makeRequest(kind: .authorize, options: [("approve", "approve"), ("deny", "Deny")])),
            ("reordered", makeRequest(kind: .authorize, options: [("deny", "Deny"), ("approve", "Approve")])),
            ("extra option", makeRequest(kind: .authorize, options: approveDeny + [("later", "Later")])),
            ("missing option", makeRequest(kind: .authorize, options: [("approve", "Approve")])),
            ("no options", makeRequest(kind: .authorize, options: [])),
            ("decision with text only", makeRequest(kind: .decision, options: [], allowText: true)),
            ("unknown kind", makeRequest(kind: RequestKind(rawValue: "quiz"), options: approveDeny)),
        ]
        for (name, request) in cases {
            #expect(NotificationCategories.category(for: request) == "sentinel.open", "\(name)")
        }
    }

    @Test func registersEveryRowWithRightActions() throws {
        let categories = Dictionary(
            uniqueKeysWithValues: NotificationCategories.makeCategories().map { ($0.identifier, $0) }
        )
        #expect(Set(categories.keys) == [
            "sentinel.authorize.2", "sentinel.authorize.hook", "sentinel.action.2", "sentinel.open",
        ])

        let two = try #require(categories["sentinel.authorize.2"]).actions
        #expect(two.map(\.identifier) == ["approve", "deny"])
        #expect(two.map(\.title) == ["Approve", "Deny"])
        #expect(two[0].options == [.authenticationRequired])
        #expect(two[1].options == [.destructive])

        let hook = try #require(categories["sentinel.authorize.hook"]).actions
        #expect(hook.map(\.identifier) == ["allow", "always", "deny"])
        #expect(hook.map(\.title) == ["Allow", "Always allow", "Deny"])
        #expect(hook[0].options == [.authenticationRequired])
        #expect(hook[1].options == [.authenticationRequired])
        #expect(hook[2].options == [.destructive])

        let action = try #require(categories["sentinel.action.2"]).actions
        #expect(action.map(\.identifier) == ["done", "cant"])
        #expect(action.map(\.title) == ["Done", "Can't"])
        #expect(action.allSatisfy { $0.options.isEmpty })

        #expect(try #require(categories["sentinel.open"]).actions.isEmpty)
    }

    @Test func registeredActionsAnswerWithTheirOptionIDs() throws {
        // Each action identifier must be an option id of the layout it belongs to.
        let layouts: [(String, Request)] = [
            ("sentinel.authorize.2", makeRequest(kind: .authorize, options: [("approve", "Approve"), ("deny", "Deny")])),
            ("sentinel.authorize.hook", makeRequest(kind: .authorize, options: [("allow", "Allow"), ("always", "Always allow"), ("deny", "Deny")], allowText: true)),
            ("sentinel.action.2", makeRequest(kind: .action, options: [("done", "Done"), ("cant", "Can't")])),
        ]
        let categories = Dictionary(uniqueKeysWithValues: NotificationCategories.makeCategories().map { ($0.identifier, $0) })
        for (identifier, request) in layouts {
            let category = try #require(categories[identifier])
            #expect(category.actions.map(\.identifier) == request.options.map(\.id))
            #expect(category.actions.map(\.title) == request.options.map(\.label))
        }
    }
}
