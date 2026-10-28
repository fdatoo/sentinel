import Foundation

/// The body of a Mac-to-hub `presence` frame, without the `type` key.
public struct PresenceFrame: Codable, Sendable, Hashable {
    public var idleSeconds: Double
    public var locked: Bool
    public var asleep: Bool
    public var displayAsleep: Bool
    public var sessionActive: Bool

    public init(
        idleSeconds: Double,
        locked: Bool = false,
        asleep: Bool = false,
        displayAsleep: Bool = false,
        sessionActive: Bool = true
    ) {
        self.idleSeconds = idleSeconds
        self.locked = locked
        self.asleep = asleep
        self.displayAsleep = displayAsleep
        self.sessionActive = sessionActive
    }

    enum CodingKeys: String, CodingKey {
        case idleSeconds = "idle_seconds"
        case locked, asleep
        case displayAsleep = "display_asleep"
        case sessionActive = "session_active"
    }
}

/// A WebSocket frame on `/v1/devices/ws`. Frames with an unrecognized `type`
/// decode as `.unknown` so a newer hub can't break an older client.
public enum HubFrame: Codable, Sendable, Hashable {
    case presence(PresenceFrame)
    case sync([Request])
    case deliver(Request)
    case retract(Request)
    case unknown(type: String)

    enum CodingKeys: String, CodingKey {
        case type, requests, request
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "presence":
            self = .presence(try PresenceFrame(from: decoder))
        case "sync":
            self = .sync(try c.decodeIfPresent([Request].self, forKey: .requests) ?? [])
        case "deliver":
            self = .deliver(try c.decode(Request.self, forKey: .request))
        case "retract":
            self = .retract(try c.decode(Request.self, forKey: .request))
        default:
            self = .unknown(type: type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .presence(let presence):
            try c.encode("presence", forKey: .type)
            try presence.encode(to: encoder)
        case .sync(let requests):
            try c.encode("sync", forKey: .type)
            try c.encode(requests, forKey: .requests)
        case .deliver(let request):
            try c.encode("deliver", forKey: .type)
            try c.encode(request, forKey: .request)
        case .retract(let request):
            try c.encode("retract", forKey: .type)
            try c.encode(request, forKey: .request)
        case .unknown(let type):
            try c.encode(type, forKey: .type)
        }
    }
}
