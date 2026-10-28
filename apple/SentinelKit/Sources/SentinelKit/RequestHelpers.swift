import Foundation
import LocalAuthentication

extension Request {
    /// Choosing a non-negative option in an `authorize` request needs device
    /// authentication first. A text-only reply or a denial doesn't.
    public func requiresAuthentication(forOptionID optionID: String?) -> Bool {
        guard kind == .authorize,
              let optionID,
              let option = options.first(where: { $0.id == optionID })
        else { return false }
        return !option.negative
    }

    /// The hub's account of who resolved the request, for retract banners.
    public var resolutionSummary: String {
        switch state {
        case .answered:
            if let name = response?.deviceName, !name.isEmpty {
                if let option = options.first(where: { $0.id == response?.optionID }) {
                    return "\(option.label) on \(name)"
                }
                return "Answered on \(name)"
            }
            return "Answered"
        case .expired: return "Expired"
        case .cancelled: return "Cancelled by the agent"
        default: return "Resolved"
        }
    }

    /// Title and body for a notification about this request, following the APNs
    /// rules in api.md: sensitive requests show only that the agent needs you.
    public var notificationTitle: String {
        if sensitive { return agent.label }
        if let host = agent.host, !host.isEmpty { return "\(agent.label) on \(host)" }
        return agent.label
    }

    public var notificationBody: String {
        sensitive ? "needs you" : title
    }
}

/// Markdown for request bodies. Inline syntax only: SwiftUI's `Text` can't lay
/// out block structure, and this keeps the author's line breaks.
public enum MarkdownRendering {
    public static func attributed(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}

public enum DeviceAuthenticationError: Error, Sendable, Equatable {
    case cancelled
    case failed(String)
}

extension DeviceAuthenticationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Authentication was cancelled."
        case .failed(let message): return message
        }
    }
}

/// Face ID, Touch ID or the device passcode, via LocalAuthentication.
public enum DeviceAuthenticator {
    public static func authenticate(reason: String) async throws {
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            throw DeviceAuthenticationError.failed(policyError?.localizedDescription ?? "Authentication isn't available.")
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if !ok { throw DeviceAuthenticationError.failed("Authentication failed.") }
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel:
                throw DeviceAuthenticationError.cancelled
            default:
                throw DeviceAuthenticationError.failed(error.localizedDescription)
            }
        }
    }
}
