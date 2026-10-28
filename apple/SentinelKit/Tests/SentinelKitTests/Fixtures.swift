import Foundation
@testable import SentinelKit

/// JSON copied from docs/api.md.
enum Fixtures {
    static let request = """
    {
      "id": "01JBV5Q8ZK6V0M7W3T2N4R8C1D",
      "agent": { "host": "studio", "node": "nodeid:abc", "label": "claude-code", "session": "5f1c..." },
      "kind": "authorize",
      "title": "Bash: rm -rf node_modules",
      "body": "Working directory `/Users/sam/app`",
      "options": [
        { "id": "allow",  "label": "Allow",        "style": "default",     "negative": false },
        { "id": "always", "label": "Always allow", "style": "default",     "negative": false },
        { "id": "deny",   "label": "Deny",         "style": "destructive", "negative": true }
      ],
      "allow_text": true,
      "urgency": "normal",
      "sensitive": false,
      "grace_seconds": 10,
      "created_at": "2026-10-24T09:00:00Z",
      "expires_at": "2026-10-25T09:00:00Z",
      "callback_url": null,
      "state": "pending",
      "stage": "mac",
      "routed_to": "01JBV5...device-id",
      "response": null,
      "resolved_at": null
    }
    """

    static let error = """
    { "error": { "code": "already_resolved", "message": "answered on Sam's iPhone" } }
    """

    static let createBody = """
    {
      "kind": "decision",
      "title": "Which migration strategy?",
      "body": "optional markdown",
      "options": [ { "id": "online", "label": "Online" }, { "id": "offline", "label": "Offline" } ],
      "allow_text": false,
      "urgency": "normal",
      "sensitive": false,
      "grace_seconds": 0,
      "expires_in_seconds": 86400,
      "callback_url": null,
      "agent": { "label": "claude-code", "session": "5f1c..." }
    }
    """

    static let responseObject = """
    { "option_id": "deny", "text": "use npm ci instead", "device_id": "01JBV...", "device_name": "Sam's iPhone", "answered_at": "2026-10-24T09:01:12Z" }
    """

    static let answerBody = """
    { "option_id": "approve", "text": null }
    """

    static let deviceRegistration = """
    { "kind": "iphone", "name": "Sam's iPhone", "apns_token": "a1b2...hex", "apns_environment": "sandbox" }
    """

    // The api.md example elides both timestamps as "...".
    static let device = """
    { "id": "01JBV...", "kind": "iphone", "name": "Sam's iPhone", "node": "nodeid:xyz", "created_at": "...", "last_seen_at": "..." }
    """

    static let presence = """
    { "type": "presence", "idle_seconds": 12.5, "locked": false, "asleep": false, "display_asleep": false, "session_active": true }
    """

    static func sync(_ request: String) -> String { #"{ "type": "sync",    "requests": [ \#(request) ] }"# }
    static func deliver(_ request: String) -> String { #"{ "type": "deliver", "request": \#(request) }"# }
    static func retract(_ request: String) -> String { #"{ "type": "retract", "request": \#(request) }"# }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try SentinelJSON.makeDecoder().decode(type, from: Data(json.utf8))
    }

    static func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try SentinelJSON.makeEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

import Testing

func makeRequest(
    id: String = "r1",
    kind: RequestKind,
    options: [(String, String)],
    allowText: Bool = false,
    sensitive: Bool = false,
    state: RequestState = .pending,
    createdAt: Date? = nil
) -> Request {
    Request(
        id: id,
        agent: AgentInfo(host: "studio", node: "n", label: "claude-code"),
        kind: kind,
        title: "Do the thing",
        options: options.map { Option(id: $0.0, label: $0.1) },
        allowText: allowText,
        sensitive: sensitive,
        createdAt: createdAt,
        state: state
    )
}
