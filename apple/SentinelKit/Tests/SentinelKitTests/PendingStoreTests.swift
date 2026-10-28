import Foundation
import Testing
@testable import SentinelKit

@Suite struct PendingStoreTests {
    func req(_ id: String, at seconds: Double, state: RequestState = .pending) -> Request {
        makeRequest(
            id: id, kind: .decision, options: [("a", "A")],
            state: state, createdAt: Date(timeIntervalSince1970: seconds)
        )
    }

    @Test func deliverAddsNewestFirst() {
        var store = PendingStore()
        #expect(store.apply(.deliver(req("old", at: 1))) == [.delivered(req("old", at: 1))])
        store.apply(.deliver(req("new", at: 2)))
        #expect(store.requests.map(\.id) == ["new", "old"])
        #expect(store.count == 2)
    }

    @Test func redeliverUpdatesInPlace() {
        var store = PendingStore()
        store.apply(.deliver(req("a", at: 1)))
        let changes = store.apply(.deliver(req("a", at: 1)))
        #expect(changes == [.updated(req("a", at: 1))])
        #expect(store.count == 1)
    }

    @Test func retractRemovesAndCarriesTerminalRequest() {
        var store = PendingStore()
        store.apply(.deliver(req("a", at: 1)))
        let terminal = req("a", at: 1, state: .answered)
        #expect(store.apply(.retract(terminal)) == [.retracted(terminal)])
        #expect(store.count == 0)
        #expect(store.apply(.retract(terminal)).isEmpty)
    }

    @Test func syncReplacesTheSet() {
        var store = PendingStore()
        store.apply(.deliver(req("keep", at: 1)))
        store.apply(.deliver(req("drop", at: 2)))
        let changes = store.apply(.sync([req("keep", at: 1), req("fresh", at: 3), req("done", at: 4, state: .answered)]))
        #expect(Set(changes) == [
            .retracted(req("drop", at: 2)),
            .updated(req("keep", at: 1)),
            .delivered(req("fresh", at: 3)),
        ])
        #expect(store.requests.map(\.id) == ["fresh", "keep"])
    }

    @Test func terminalDeliverActsAsRetract() {
        var store = PendingStore()
        store.apply(.deliver(req("a", at: 1)))
        let changes = store.apply(.deliver(req("a", at: 1, state: .expired)))
        #expect(changes == [.retracted(req("a", at: 1, state: .expired))])
        #expect(store.count == 0)
        #expect(store.apply(.deliver(req("never", at: 1, state: .cancelled))).isEmpty)
    }

    @Test func presenceAndUnknownFramesAreIgnored() {
        var store = PendingStore()
        #expect(store.apply(.presence(PresenceFrame(idleSeconds: 1))).isEmpty)
        #expect(store.apply(.unknown(type: "x")).isEmpty)
    }

    @Test func manualRemove() {
        var store = PendingStore()
        store.apply(.deliver(req("a", at: 1)))
        store.remove(requestID: "a")
        #expect(store.count == 0)
    }
}

@Suite struct RequestHelperTests {
    @Test func authenticationRequiredOnlyForNonNegativeAuthorize() {
        var authorize = makeRequest(kind: .authorize, options: [("approve", "Approve"), ("deny", "Deny")])
        authorize.options[1].negative = true
        #expect(authorize.requiresAuthentication(forOptionID: "approve"))
        #expect(!authorize.requiresAuthentication(forOptionID: "deny"))
        #expect(!authorize.requiresAuthentication(forOptionID: nil))
        #expect(!authorize.requiresAuthentication(forOptionID: "missing"))

        let decision = makeRequest(kind: .decision, options: [("a", "A")])
        #expect(!decision.requiresAuthentication(forOptionID: "a"))
        let action = makeRequest(kind: .action, options: [("done", "Done")])
        #expect(!action.requiresAuthentication(forOptionID: "done"))
    }

    @Test func notificationTextFollowsApnsRules() {
        var request = makeRequest(kind: .authorize, options: [])
        #expect(request.notificationTitle == "claude-code on studio")
        #expect(request.notificationBody == "Do the thing")
        request.sensitive = true
        #expect(request.notificationTitle == "claude-code")
        #expect(request.notificationBody == "needs you")
    }

    @Test func resolutionSummaries() {
        var request = makeRequest(kind: .authorize, options: [("approve", "Approve")], state: .answered)
        request.response = Response(optionID: "approve", deviceName: "Sam's iPhone")
        #expect(request.resolutionSummary == "Approve on Sam's iPhone")
        request.state = .expired
        #expect(request.resolutionSummary == "Expired")
        request.state = .cancelled
        #expect(request.resolutionSummary == "Cancelled by the agent")
    }

    @Test func markdownRendersInlineStyles() {
        let text = MarkdownRendering.attributed("run `ls`\nthen **stop**")
        #expect(String(text.characters).contains("run ls"))
        #expect(String(text.characters).contains("\n"))
    }

    @Test func alreadyResolvedDescriptions() {
        #expect(HubError.api(status: 409, code: "already_resolved", message: "expired").alreadyResolvedDescription == "Already resolved: expired")
        #expect(HubError.api(status: 409, code: "already_resolved", message: "").alreadyResolvedDescription == "Already answered elsewhere")
        #expect(HubError.api(status: 404, code: "not_found", message: "x").alreadyResolvedDescription == nil)
    }
}
