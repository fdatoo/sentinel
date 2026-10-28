import Foundation
import Testing
@testable import SentinelKit

@Suite struct HubSettingsTests {
    func freshDefaults() -> UserDefaults {
        let name = "sentinel.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func roundTripsThroughUserDefaults() {
        let defaults = freshDefaults()
        let empty = HubSettings.load(from: defaults, defaultDeviceName: "Studio")
        #expect(empty == HubSettings(hubURL: "", deviceName: "Studio", devNode: ""))

        HubSettings(hubURL: "https://hub.ts.net", deviceName: "Desk", devNode: "mac-1").save(to: defaults)
        let loaded = HubSettings.load(from: defaults, defaultDeviceName: "Studio")
        #expect(loaded == HubSettings(hubURL: "https://hub.ts.net", deviceName: "Desk", devNode: "mac-1"))
    }

    @Test func devHeadersFollowTheNodeId() {
        var settings = HubSettings(hubURL: "http://127.0.0.1:7878", deviceName: "Desk")
        #expect(settings.endpoint(devHost: "Desk")?.devNode == nil)
        #expect(settings.endpoint(devHost: "Desk")?.devHost == nil)

        settings.devNode = " mac-1 "
        let endpoint = settings.endpoint(devHost: "Desk")
        #expect(endpoint?.devNode == "mac-1")
        #expect(endpoint?.devHost == "Desk")

        settings.hubURL = ""
        #expect(settings.endpoint(devHost: nil) == nil)
    }
}
