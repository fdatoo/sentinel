import Foundation
import Testing
@testable import SentinelKit

@Suite struct ModelTests {
    @Test func decodesRequestExample() throws {
        let request = try Fixtures.decode(Request.self, Fixtures.request)
        #expect(request.id == "01JBV5Q8ZK6V0M7W3T2N4R8C1D")
        #expect(request.agent == AgentInfo(host: "studio", node: "nodeid:abc", label: "claude-code", session: "5f1c..."))
        #expect(request.kind == .authorize)
        #expect(request.body == "Working directory `/Users/sam/app`")
        #expect(request.options.map(\.id) == ["allow", "always", "deny"])
        #expect(request.options[2].style == .destructive)
        #expect(request.options[2].negative)
        #expect(request.options[0].negative == false)
        #expect(request.allowText)
        #expect(request.urgency == .normal)
        #expect(request.graceSeconds == 10)
        #expect(request.createdAt == Date(timeIntervalSince1970: 1_792_832_400))
        #expect(request.expiresAt == request.createdAt?.addingTimeInterval(86400))
        #expect(request.callbackURL == nil)
        #expect(request.state == .pending)
        #expect(request.stage == .mac)
        #expect(request.routedTo == "01JBV5...device-id")
        #expect(request.response == nil)
        #expect(request.resolvedAt == nil)
    }

    @Test func decodesResponseObject() throws {
        let response = try Fixtures.decode(Response.self, Fixtures.responseObject)
        #expect(response.optionID == "deny")
        #expect(response.text == "use npm ci instead")
        #expect(response.deviceID == "01JBV...")
        #expect(response.deviceName == "Sam's iPhone")
        #expect(response.answeredAt == Date(timeIntervalSince1970: 1_792_832_400 + 72))
    }

    @Test func decodesAnsweredRequestWithNullOptionID() throws {
        let json = Fixtures.request
            .replacingOccurrences(of: "\"state\": \"pending\"", with: "\"state\": \"answered\"")
            .replacingOccurrences(
                of: "\"response\": null",
                with: "\"response\": { \"option_id\": null, \"text\": \"hold on\", \"device_id\": \"d\", \"device_name\": \"Mac\", \"answered_at\": \"2026-10-24T09:01:12.250Z\" }"
            )
            .replacingOccurrences(of: "\"resolved_at\": null", with: "\"resolved_at\": \"2026-10-24T09:01:12Z\"")
        let request = try Fixtures.decode(Request.self, json)
        #expect(request.state == .answered)
        #expect(request.response?.optionID == nil)
        #expect(request.response?.text == "hold on")
        #expect(request.resolvedAt != nil)
        let answered = try #require(request.response?.answeredAt)
        #expect(abs(answered.timeIntervalSince1970 - (1_792_832_400 + 72.25)) < 0.001)
    }

    @Test func decodesErrorEnvelope() throws {
        let envelope = try Fixtures.decode(ErrorEnvelope.self, Fixtures.error)
        #expect(envelope.error.code == "already_resolved")
        #expect(envelope.error.message == "answered on Sam's iPhone")
    }

    @Test func decodesDeviceExample() throws {
        let device = try Fixtures.decode(Device.self, Fixtures.device)
        #expect(device.id == "01JBV...")
        #expect(device.kind == .iphone)
        #expect(device.name == "Sam's iPhone")
        #expect(device.node == "nodeid:xyz")
        #expect(device.createdAt == nil)
    }

    @Test func decodesDeviceWithRealTimestamps() throws {
        let json = Fixtures.device.replacingOccurrences(of: "\"...\"", with: "\"2026-10-24T09:00:00Z\"")
        let device = try Fixtures.decode(Device.self, json)
        #expect(device.createdAt == Date(timeIntervalSince1970: 1_792_832_400))
        #expect(device.lastSeenAt == device.createdAt)
    }

    @Test func ignoresUnknownFieldsAndValues() throws {
        let json = Fixtures.request
            .replacingOccurrences(of: "\"kind\": \"authorize\"", with: "\"kind\": \"quiz\", \"future\": {\"a\": 1}")
            .replacingOccurrences(of: "\"urgency\": \"normal\"", with: "\"urgency\": \"panic\"")
            .replacingOccurrences(of: "\"state\": \"pending\"", with: "\"state\": \"snoozed\"")
            .replacingOccurrences(of: "\"stage\": \"mac\"", with: "\"stage\": \"watch\"")
            .replacingOccurrences(of: "\"style\": \"destructive\"", with: "\"style\": \"loud\"")
        let request = try Fixtures.decode(Request.self, json)
        #expect(request.kind.rawValue == "quiz")
        #expect(request.urgency.rawValue == "panic")
        #expect(request.state.rawValue == "snoozed")
        #expect(request.stage?.rawValue == "watch")
        #expect(request.options[2].style.rawValue == "loud")
    }

    @Test func toleratesMissingOptionalFields() throws {
        let json = #"{ "id": "x", "kind": "decision", "title": "T", "state": "pending" }"#
        let request = try Fixtures.decode(Request.self, json)
        #expect(request.options.isEmpty)
        #expect(request.body == nil)
        #expect(request.allowText == false)
        #expect(request.urgency == .normal)
    }

    @Test func parsesRFC3339Variants() {
        let base = Date(timeIntervalSince1970: 1_792_832_400)
        #expect(RFC3339.parse("2026-10-24T09:00:00Z") == base)
        #expect(RFC3339.parse("2026-10-24T11:00:00+02:00") == base)
        let nanos = RFC3339.parse("2026-10-24T09:00:00.123456789Z")
        #expect(abs((nanos?.timeIntervalSince1970 ?? 0) - (1_792_832_400.123456)) < 0.001)
        let millis = RFC3339.parse("2026-10-24T11:00:00.5+02:00")
        #expect(abs((millis?.timeIntervalSince1970 ?? 0) - 1_792_832_400.5) < 0.001)
        #expect(RFC3339.parse("yesterday") == nil)
        #expect(RFC3339.parse("2026-10-24T09:00:00.Z") == nil)
    }

    @Test func requestRoundTrips() throws {
        let original = try Fixtures.decode(Request.self, Fixtures.request)
        let data = try SentinelJSON.makeEncoder().encode(original)
        let decoded = try SentinelJSON.makeDecoder().decode(Request.self, from: data)
        #expect(decoded == original)
    }

    // MARK: Request bodies

    @Test func encodesCreateBody() throws {
        let body = NewRequest(
            kind: .decision,
            title: "Which migration strategy?",
            body: "optional markdown",
            options: [NewOption(id: "online", label: "Online"), NewOption(id: "offline", label: "Offline")],
            agent: NewAgent(label: "claude-code", session: "5f1c...")
        )
        let object = try Fixtures.jsonObject(body)
        let expected = try #require(
            JSONSerialization.jsonObject(with: Data(Fixtures.createBody.utf8)) as? [String: Any]
        )
        // The example writes callback_url as null; omitting it is equivalent.
        let keys = Set(object.keys).union(["callback_url"])
        #expect(keys == Set(expected.keys))
        #expect(object["kind"] as? String == "decision")
        #expect(object["allow_text"] as? Bool == false)
        #expect(object["grace_seconds"] as? Int == 0)
        #expect(object["expires_in_seconds"] as? Int == 86400)
        let options = try #require(object["options"] as? [[String: Any]])
        #expect(options.count == 2)
        #expect(Set(options[0].keys) == ["id", "label"])
        let agent = try #require(object["agent"] as? [String: Any])
        #expect(agent["label"] as? String == "claude-code")
        #expect(agent["session"] as? String == "5f1c...")
    }

    @Test func encodesOptionStyleAndNegativeWhenSet() throws {
        let option = NewOption(id: "deny", label: "Deny", style: .destructive, negative: true)
        let object = try Fixtures.jsonObject(option)
        #expect(object["style"] as? String == "destructive")
        #expect(object["negative"] as? Bool == true)
    }

    @Test func encodesAnswerBodyWithNullForUnsetKey() throws {
        let object = try Fixtures.jsonObject(AnswerBody(optionID: "approve"))
        #expect(object["option_id"] as? String == "approve")
        #expect(object["text"] is NSNull)
        #expect(Set(object.keys) == ["option_id", "text"])

        let textOnly = try Fixtures.jsonObject(AnswerBody(text: "no thanks"))
        #expect(textOnly["option_id"] is NSNull)
        #expect(textOnly["text"] as? String == "no thanks")
    }

    @Test func encodesDeviceRegistration() throws {
        let iphone = DeviceRegistration(kind: .iphone, name: "Sam's iPhone", apnsToken: "a1b2", apnsEnvironment: .sandbox)
        let object = try Fixtures.jsonObject(iphone)
        #expect(Set(object.keys) == ["kind", "name", "apns_token", "apns_environment"])
        #expect(object["kind"] as? String == "iphone")
        #expect(object["apns_environment"] as? String == "sandbox")

        let mac = try Fixtures.jsonObject(DeviceRegistration(kind: .mac, name: "Studio"))
        #expect(Set(mac.keys) == ["kind", "name"])

        let decoded = try Fixtures.decode(DeviceRegistration.self, Fixtures.deviceRegistration)
        #expect(decoded.apnsToken == "a1b2...hex")
    }

    // MARK: Frames

    @Test func decodesPresenceFrame() throws {
        let frame = try Fixtures.decode(HubFrame.self, Fixtures.presence)
        #expect(frame == .presence(PresenceFrame(idleSeconds: 12.5, locked: false, asleep: false, displayAsleep: false, sessionActive: true)))
    }

    @Test func encodesPresenceFrame() throws {
        let frame = HubFrame.presence(PresenceFrame(idleSeconds: 12.5, asleep: true))
        let object = try Fixtures.jsonObject(frame)
        #expect(Set(object.keys) == ["type", "idle_seconds", "locked", "asleep", "display_asleep", "session_active"])
        #expect(object["type"] as? String == "presence")
        #expect(object["asleep"] as? Bool == true)
        #expect(object["idle_seconds"] as? Double == 12.5)
    }

    @Test func decodesSyncDeliverRetract() throws {
        let sync = try Fixtures.decode(HubFrame.self, Fixtures.sync(Fixtures.request))
        guard case .sync(let requests) = sync else { Issue.record("not sync"); return }
        #expect(requests.map(\.id) == ["01JBV5Q8ZK6V0M7W3T2N4R8C1D"])

        let deliver = try Fixtures.decode(HubFrame.self, Fixtures.deliver(Fixtures.request))
        guard case .deliver(let delivered) = deliver else { Issue.record("not deliver"); return }
        #expect(delivered.title == "Bash: rm -rf node_modules")

        let retract = try Fixtures.decode(HubFrame.self, Fixtures.retract(Fixtures.request))
        guard case .retract(let retracted) = retract else { Issue.record("not retract"); return }
        #expect(retracted.id == delivered.id)
    }

    @Test func emptySyncAndUnknownFrames() throws {
        #expect(try Fixtures.decode(HubFrame.self, #"{"type":"sync","requests":null}"#) == .sync([]))
        #expect(try Fixtures.decode(HubFrame.self, #"{"type":"sync","requests":[]}"#) == .sync([]))
        #expect(try Fixtures.decode(HubFrame.self, #"{"type":"hello","x":1}"#) == .unknown(type: "hello"))
    }

    @Test func frameRoundTrips() throws {
        let request = try Fixtures.decode(Request.self, Fixtures.request)
        for frame in [HubFrame.sync([request]), .deliver(request), .retract(request)] {
            let data = try SentinelJSON.makeEncoder().encode(frame)
            #expect(try SentinelJSON.makeDecoder().decode(HubFrame.self, from: data) == frame)
        }
    }
}
