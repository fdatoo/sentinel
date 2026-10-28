import Foundation
import Testing
@testable import SentinelKit

/// Runs against a real `sentinel-hub --dev` when SENTINEL_LIVE_HUB is set, for
/// example `SENTINEL_LIVE_HUB=http://127.0.0.1:7878 swift test`. Each run uses
/// fresh node ids so it can share a hub with earlier runs.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SENTINEL_LIVE_HUB"] != nil))
struct LiveHubTests {
    let base = URL(string: ProcessInfo.processInfo.environment["SENTINEL_LIVE_HUB"] ?? "http://127.0.0.1:7878")!
    let run = UUID().uuidString.prefix(8)

    func endpoint(_ role: String) -> HubEndpoint {
        HubEndpoint(baseURL: base, devNode: "live-\(role)-\(run)", devHost: "live-\(role)")
    }

    @Test func macDeliveryAndPhoneAnswer() async throws {
        let mac = HubClient(endpoint: endpoint("mac"))
        let phone = HubClient(endpoint: endpoint("phone"))
        let agent = HubClient(endpoint: endpoint("agent"))
        _ = try await mac.registerDevice(DeviceRegistration(kind: .mac, name: "Live Mac \(run)"))
        // A tokenless iPhone, as the app registers when push permission is refused.
        _ = try await phone.registerDevice(DeviceRegistration(kind: .iphone, name: "Live iPhone \(run)"))

        let socket = HubSocket(endpoint: endpoint("mac"))
        await socket.start()
        defer { Task { await socket.stop() } }
        var frames = socket.frames.makeAsyncIterator()

        guard case .sync = try #require(await frames.next()) else {
            Issue.record("first frame was not sync")
            return
        }
        #expect(await socket.send(PresenceFrame(idleSeconds: 1)))
        try await Task.sleep(for: .milliseconds(200))

        let created = try await agent.createRequest(NewRequest(kind: .authorize, title: "Live \(run)"))
        #expect(created.stage == .mac)
        guard case .deliver(let delivered) = try #require(await frames.next()) else {
            Issue.record("expected deliver")
            return
        }
        #expect(delivered.id == created.id)

        async let resolved = agent.awaitResolution(id: created.id, pollSeconds: 10)
        _ = try await phone.respond(to: created.id, optionID: "approve")

        guard case .retract(let retracted) = try #require(await frames.next()) else {
            Issue.record("expected retract")
            return
        }
        #expect(retracted.id == created.id)
        let final = try await resolved
        #expect(final.state == .answered)
        #expect(final.response?.deviceName == "Live iPhone \(run)")

        do {
            _ = try await mac.respond(to: created.id, optionID: "deny")
            Issue.record("second answer accepted")
        } catch let error as HubError {
            #expect(error.isAlreadyResolved)
        }
    }
}
