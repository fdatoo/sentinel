import Foundation

public struct AgentInfo: Codable, Sendable, Hashable {
    public var host: String?
    public var node: String?
    public var label: String
    public var session: String?

    public init(host: String? = nil, node: String? = nil, label: String, session: String? = nil) {
        self.host = host
        self.node = node
        self.label = label
        self.session = session
    }

    enum CodingKeys: String, CodingKey {
        case host, node, label, session
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decodeIfPresent(String.self, forKey: .host)
        node = try c.decodeIfPresent(String.self, forKey: .node)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        session = try c.decodeIfPresent(String.self, forKey: .session)
    }
}

public struct Option: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var style: OptionStyle
    public var negative: Bool

    public init(id: String, label: String, style: OptionStyle = .default, negative: Bool = false) {
        self.id = id
        self.label = label
        self.style = style
        self.negative = negative
    }

    enum CodingKeys: String, CodingKey {
        case id, label, style, negative
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        style = try c.decodeIfPresent(OptionStyle.self, forKey: .style) ?? .default
        negative = try c.decodeIfPresent(Bool.self, forKey: .negative) ?? false
    }
}

public struct Response: Codable, Sendable, Hashable {
    public var optionID: String?
    public var text: String?
    public var deviceID: String?
    public var deviceName: String?
    public var answeredAt: Date?

    public init(
        optionID: String? = nil,
        text: String? = nil,
        deviceID: String? = nil,
        deviceName: String? = nil,
        answeredAt: Date? = nil
    ) {
        self.optionID = optionID
        self.text = text
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.answeredAt = answeredAt
    }

    enum CodingKeys: String, CodingKey {
        case optionID = "option_id"
        case text
        case deviceID = "device_id"
        case deviceName = "device_name"
        case answeredAt = "answered_at"
    }
}

public struct Request: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var agent: AgentInfo
    public var kind: RequestKind
    public var title: String
    public var body: String?
    public var options: [Option]
    public var allowText: Bool
    public var urgency: Urgency
    public var sensitive: Bool
    public var graceSeconds: Int
    public var createdAt: Date?
    public var expiresAt: Date?
    public var callbackURL: String?
    public var state: RequestState
    public var stage: RoutingStage?
    public var routedTo: String?
    public var response: Response?
    public var resolvedAt: Date?

    public init(
        id: String,
        agent: AgentInfo,
        kind: RequestKind,
        title: String,
        body: String? = nil,
        options: [Option] = [],
        allowText: Bool = false,
        urgency: Urgency = .normal,
        sensitive: Bool = false,
        graceSeconds: Int = 0,
        createdAt: Date? = nil,
        expiresAt: Date? = nil,
        callbackURL: String? = nil,
        state: RequestState = .pending,
        stage: RoutingStage? = nil,
        routedTo: String? = nil,
        response: Response? = nil,
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.agent = agent
        self.kind = kind
        self.title = title
        self.body = body
        self.options = options
        self.allowText = allowText
        self.urgency = urgency
        self.sensitive = sensitive
        self.graceSeconds = graceSeconds
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.callbackURL = callbackURL
        self.state = state
        self.stage = stage
        self.routedTo = routedTo
        self.response = response
        self.resolvedAt = resolvedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, agent, kind, title, body, options
        case allowText = "allow_text"
        case urgency, sensitive
        case graceSeconds = "grace_seconds"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case callbackURL = "callback_url"
        case state, stage
        case routedTo = "routed_to"
        case response
        case resolvedAt = "resolved_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        agent = try c.decodeIfPresent(AgentInfo.self, forKey: .agent) ?? AgentInfo(label: "")
        kind = try c.decode(RequestKind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        options = try c.decodeIfPresent([Option].self, forKey: .options) ?? []
        allowText = try c.decodeIfPresent(Bool.self, forKey: .allowText) ?? false
        urgency = try c.decodeIfPresent(Urgency.self, forKey: .urgency) ?? .normal
        sensitive = try c.decodeIfPresent(Bool.self, forKey: .sensitive) ?? false
        graceSeconds = try c.decodeIfPresent(Int.self, forKey: .graceSeconds) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        callbackURL = try c.decodeIfPresent(String.self, forKey: .callbackURL)
        state = try c.decode(RequestState.self, forKey: .state)
        stage = try c.decodeIfPresent(RoutingStage.self, forKey: .stage)
        routedTo = try c.decodeIfPresent(String.self, forKey: .routedTo)
        response = try c.decodeIfPresent(Response.self, forKey: .response)
        resolvedAt = try c.decodeIfPresent(Date.self, forKey: .resolvedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(agent, forKey: .agent)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encode(body, forKey: .body)
        try c.encode(options, forKey: .options)
        try c.encode(allowText, forKey: .allowText)
        try c.encode(urgency, forKey: .urgency)
        try c.encode(sensitive, forKey: .sensitive)
        try c.encode(graceSeconds, forKey: .graceSeconds)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(expiresAt, forKey: .expiresAt)
        try c.encode(callbackURL, forKey: .callbackURL)
        try c.encode(state, forKey: .state)
        try c.encode(stage, forKey: .stage)
        try c.encode(routedTo, forKey: .routedTo)
        try c.encode(response, forKey: .response)
        try c.encode(resolvedAt, forKey: .resolvedAt)
    }
}

public struct Device: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: DeviceKind
    public var name: String
    public var node: String?
    public var createdAt: Date?
    public var lastSeenAt: Date?

    public init(
        id: String,
        kind: DeviceKind,
        name: String,
        node: String? = nil,
        createdAt: Date? = nil,
        lastSeenAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.node = node
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, name, node
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
    }

    // The timestamps are informational, so an unparseable one reads as nil
    // rather than failing device registration.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(DeviceKind.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        node = try c.decodeIfPresent(String.self, forKey: .node)
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        lastSeenAt = try? c.decodeIfPresent(Date.self, forKey: .lastSeenAt)
    }
}

public struct ErrorEnvelope: Codable, Sendable, Hashable {
    public struct Body: Codable, Sendable, Hashable {
        public var code: String
        public var message: String

        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }
    }

    public var error: Body

    public init(error: Body) {
        self.error = error
    }
}

// MARK: - Request bodies

public struct NewOption: Codable, Sendable, Hashable {
    public var id: String
    public var label: String
    public var style: OptionStyle?
    public var negative: Bool?

    public init(id: String, label: String, style: OptionStyle? = nil, negative: Bool? = nil) {
        self.id = id
        self.label = label
        self.style = style
        self.negative = negative
    }
}

public struct NewAgent: Codable, Sendable, Hashable {
    public var label: String
    public var session: String?

    public init(label: String, session: String? = nil) {
        self.label = label
        self.session = session
    }
}

/// Body of `POST /v1/requests`.
public struct NewRequest: Codable, Sendable, Hashable {
    public var kind: RequestKind
    public var title: String
    public var body: String?
    public var options: [NewOption]
    public var allowText: Bool
    public var urgency: Urgency
    public var sensitive: Bool
    public var graceSeconds: Int
    public var expiresInSeconds: Int
    public var callbackURL: String?
    public var agent: NewAgent?

    public init(
        kind: RequestKind,
        title: String,
        body: String? = nil,
        options: [NewOption] = [],
        allowText: Bool = false,
        urgency: Urgency = .normal,
        sensitive: Bool = false,
        graceSeconds: Int = 0,
        expiresInSeconds: Int = 86400,
        callbackURL: String? = nil,
        agent: NewAgent? = nil
    ) {
        self.kind = kind
        self.title = title
        self.body = body
        self.options = options
        self.allowText = allowText
        self.urgency = urgency
        self.sensitive = sensitive
        self.graceSeconds = graceSeconds
        self.expiresInSeconds = expiresInSeconds
        self.callbackURL = callbackURL
        self.agent = agent
    }

    enum CodingKeys: String, CodingKey {
        case kind, title, body, options
        case allowText = "allow_text"
        case urgency, sensitive
        case graceSeconds = "grace_seconds"
        case expiresInSeconds = "expires_in_seconds"
        case callbackURL = "callback_url"
        case agent
    }
}

/// Body of `POST /v1/requests/{id}/response`. Both keys are always written, with
/// `null` for the unset one, as in the api.md example.
public struct AnswerBody: Codable, Sendable, Hashable {
    public var optionID: String?
    public var text: String?

    public init(optionID: String? = nil, text: String? = nil) {
        self.optionID = optionID
        self.text = text
    }

    enum CodingKeys: String, CodingKey {
        case optionID = "option_id"
        case text
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(optionID, forKey: .optionID)
        try c.encode(text, forKey: .text)
    }
}

/// Body of `POST /v1/devices`.
public struct DeviceRegistration: Codable, Sendable, Hashable {
    public var kind: DeviceKind
    public var name: String
    public var apnsToken: String?
    public var apnsEnvironment: APNsEnvironment?

    public init(
        kind: DeviceKind,
        name: String,
        apnsToken: String? = nil,
        apnsEnvironment: APNsEnvironment? = nil
    ) {
        self.kind = kind
        self.name = name
        self.apnsToken = apnsToken
        self.apnsEnvironment = apnsEnvironment
    }

    enum CodingKeys: String, CodingKey {
        case kind, name
        case apnsToken = "apns_token"
        case apnsEnvironment = "apns_environment"
    }
}

// MARK: - List envelopes

struct RequestList: Decodable {
    var requests: [Request]

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requests = try c.decodeIfPresent([Request].self, forKey: .requests) ?? []
    }

    enum CodingKeys: String, CodingKey { case requests }
}

struct DeviceList: Decodable {
    var devices: [Device]

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        devices = try c.decodeIfPresent([Device].self, forKey: .devices) ?? []
    }

    enum CodingKeys: String, CodingKey { case devices }
}
