import Foundation
import SentinelKit
import UIKit
@preconcurrency import UserNotifications

@MainActor
@Observable
final class AppModel {
    enum LoadState: Equatable {
        case notConfigured
        case loading
        case loaded
        case unreachable
        case failed(String)
    }

    enum AnswerOutcome: Equatable {
        case sent
        case cancelled
        /// Someone else got there first; the text names who.
        case alreadyResolved(String)
        case failed(String)
    }

    static let shared = AppModel()

    var settings: HubSettings
    private(set) var pending: [Request] = []
    private(set) var history: [Request] = []
    private(set) var loadState: LoadState = .loading
    private(set) var registrationNote: String?
    /// A transient message such as "Already answered on Sam's iPhone".
    var banner: String?
    var path: [String] = []
    var showingSettings = false

    @ObservationIgnored private var apnsToken: String?
    @ObservationIgnored private var registeredSignature: String?

    private init() {
        settings = HubSettings.load(defaultDeviceName: UIDevice.current.name)
    }

    private var client: HubClient? {
        settings.endpoint(devHost: UIDevice.current.name).map { HubClient(endpoint: $0) }
    }

    func request(id: String) -> Request? {
        pending.first { $0.id == id } ?? history.first { $0.id == id }
    }

    // MARK: Loading

    func refresh() async {
        guard let client else {
            loadState = .notConfigured
            return
        }
        if pending.isEmpty && history.isEmpty { loadState = .loading }
        do {
            async let pendingList = client.listRequests(state: .pending, limit: 50)
            async let allList = client.listRequests(limit: 50)
            let (pendingRequests, all) = try await (pendingList, allList)
            pending = pendingRequests
            history = all.filter { $0.state != .pending }
            loadState = .loaded
            clearStaleNotifications()
        } catch let error as HubError where error.isUnreachable {
            loadState = .unreachable
        } catch is CancellationError {
            return
        } catch {
            loadState = .failed(Self.describe(error))
        }
    }

    /// Fetches one request, for a notification tap on something not in the lists yet.
    func loadRequest(id: String) async -> Request? {
        if let known = request(id: id) { return known }
        return try? await client?.getRequest(id: id)
    }

    /// Removes delivered notifications for requests that are not pending. This also
    /// catches retracts whose push iOS never delivered.
    private func clearStaleNotifications() {
        let live = Set(pending.map(\.id))
        let center = UNUserNotificationCenter.current()
        Task {
            let delivered = await center.deliveredNotifications().map(\.request.identifier)
            let stale = delivered.filter { !live.contains($0) }
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        }
    }

    func retracted(requestID: String) async {
        pending.removeAll { $0.id == requestID }
        await refresh()
    }

    // MARK: Settings and registration

    func save(_ newSettings: HubSettings) {
        settings = newSettings
        settings.save()
        Task {
            await registerDevice()
            await refresh()
        }
    }

    func setAPNsToken(_ token: String) {
        apnsToken = token
        Task { await registerDevice() }
    }

    /// Without a token (the simulator, or push permission refused) the phone can
    /// still answer requests, so register without one.
    func apnsRegistrationFailed(_ error: Error) {
        registrationNote = "Push registration failed: \(error.localizedDescription)"
        Task { await registerDevice() }
    }

    func registerDevice() async {
        guard let client else { return }
        let name = settings.trimmedDeviceName.isEmpty ? UIDevice.current.name : settings.trimmedDeviceName
        #if DEBUG
        let environment = APNsEnvironment.sandbox
        #else
        let environment = APNsEnvironment.production
        #endif
        let registration = DeviceRegistration(
            kind: .iphone,
            name: name,
            apnsToken: apnsToken,
            apnsEnvironment: apnsToken == nil ? nil : environment
        )
        do {
            _ = try await client.registerDevice(registration)
            registrationNote = nil
        } catch {
            registrationNote = "Couldn't register with the hub: \(Self.describe(error))"
        }
    }

    // MARK: Answering

    /// Answers from inside the app. Authorize approvals go through Face ID first.
    func answer(_ request: Request, optionID: String?, text: String?) async -> AnswerOutcome {
        guard let client else { return .failed("Set the hub URL in Settings first.") }
        do {
            if request.requiresAuthentication(forOptionID: optionID) {
                try await DeviceAuthenticator.authenticate(
                    reason: "Approve \"\(request.title)\" from \(request.agent.label)"
                )
            }
            let resolved = try await client.respond(to: request.id, optionID: optionID, text: text)
            applyResolved(resolved)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [request.id])
            return .sent
        } catch DeviceAuthenticationError.cancelled {
            return .cancelled
        } catch let error as HubError where error.isAlreadyResolved {
            Task { await refresh() }
            return .alreadyResolved(error.alreadyResolvedDescription ?? "Already answered")
        } catch {
            return .failed(Self.describe(error))
        }
    }

    /// Answers from a notification action. The action's own
    /// `.authenticationRequired` has already unlocked the device.
    func answerFromNotification(requestID: String, optionID: String) async {
        guard let client else {
            await postLocal(id: "\(requestID).result", title: "Sentinel isn't set up", body: "Open the app and set the hub URL.")
            return
        }
        do {
            let resolved = try await client.respond(to: requestID, optionID: optionID)
            applyResolved(resolved)
        } catch let error as HubError where error.isAlreadyResolved {
            let message = error.alreadyResolvedDescription ?? "Already answered"
            banner = message
            await postLocal(id: "\(requestID).result", title: message, body: "Your answer wasn't sent.")
            await refresh()
        } catch {
            await postLocal(
                id: "\(requestID).result",
                title: "Answer not sent",
                body: Self.describe(error) + " Open Sentinel to try again."
            )
        }
    }

    func open(requestID: String) {
        showingSettings = false
        path = [requestID]
        Task { await refresh() }
    }

    private func applyResolved(_ resolved: Request) {
        pending.removeAll { $0.id == resolved.id }
        history.removeAll { $0.id == resolved.id }
        history.insert(resolved, at: 0)
    }

    private func postLocal(id: String, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = NotificationCategories.open
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let hubError = error as? HubError {
            if hubError.isUnreachable { return "Can't reach the hub. Is Tailscale connected?" }
            return hubError.errorDescription ?? "Something went wrong."
        }
        return error.localizedDescription
    }
}
