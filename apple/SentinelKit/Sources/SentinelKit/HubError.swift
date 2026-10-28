import Foundation

/// Error codes the hub documents in api.md.
public enum HubErrorCode {
    public static let invalidRequest = "invalid_request"
    public static let forbidden = "forbidden"
    public static let notFound = "not_found"
    public static let alreadyResolved = "already_resolved"
}

public enum HubError: Error, Sendable, Equatable {
    /// The hub answered with a non-2xx status. `code` and `message` come from the
    /// error envelope; when the body isn't an envelope, `code` is `http_<status>`.
    case api(status: Int, code: String, message: String)
    /// The hub couldn't be reached or the connection failed.
    case unreachable(URLError.Code)
    case invalidResponse
    case decoding(String)

    public var code: String? {
        if case .api(_, let code, _) = self { return code }
        return nil
    }

    public var isAlreadyResolved: Bool { code == HubErrorCode.alreadyResolved }

    public var isUnreachable: Bool {
        if case .unreachable = self { return true }
        return false
    }

    /// "Already answered on Sam's iPhone" style text for a 409.
    public var alreadyResolvedDescription: String? {
        guard case .api(_, HubErrorCode.alreadyResolved, let message) = self else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Already answered elsewhere" }
        if trimmed.lowercased().hasPrefix("answered") { return "Already " + trimmed }
        return "Already resolved: " + trimmed
    }
}

extension HubError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .api(_, let code, let message):
            return message.isEmpty ? code : "\(message) (\(code))"
        case .unreachable:
            return "Can't reach the hub."
        case .invalidResponse:
            return "The hub sent a response that isn't HTTP."
        case .decoding(let detail):
            return "Couldn't read the hub's response: \(detail)"
        }
    }
}
