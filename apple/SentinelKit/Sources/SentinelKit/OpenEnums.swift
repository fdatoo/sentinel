import Foundation

/// A string-valued enum that keeps values it doesn't know about, so a newer hub
/// can't break decoding in an older client.
public protocol OpenStringEnum: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible
where RawValue == String {}

extension OpenStringEnum {
    public var description: String { rawValue }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct RequestKind: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public static let decision = RequestKind(rawValue: "decision")
    public static let authorize = RequestKind(rawValue: "authorize")
    public static let action = RequestKind(rawValue: "action")
}

public struct Urgency: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public static let low = Urgency(rawValue: "low")
    public static let normal = Urgency(rawValue: "normal")
    public static let high = Urgency(rawValue: "high")
}

public struct RequestState: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public static let pending = RequestState(rawValue: "pending")
    public static let answered = RequestState(rawValue: "answered")
    public static let expired = RequestState(rawValue: "expired")
    public static let cancelled = RequestState(rawValue: "cancelled")
}

public struct RoutingStage: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public static let grace = RoutingStage(rawValue: "grace")
    public static let mac = RoutingStage(rawValue: "mac")
    public static let phone = RoutingStage(rawValue: "phone")
    public static let done = RoutingStage(rawValue: "done")
}

public struct OptionStyle: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public static let `default` = OptionStyle(rawValue: "default")
    public static let destructive = OptionStyle(rawValue: "destructive")
}

public struct DeviceKind: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public static let mac = DeviceKind(rawValue: "mac")
    public static let iphone = DeviceKind(rawValue: "iphone")
    /// Appears in device lists; the apps never register as one.
    public static let cli = DeviceKind(rawValue: "cli")
}

public struct APNsEnvironment: OpenStringEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public static let sandbox = APNsEnvironment(rawValue: "sandbox")
    public static let production = APNsEnvironment(rawValue: "production")
}
