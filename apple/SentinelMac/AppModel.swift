import AppKit
import Foundation
import SentinelKit
import ServiceManagement
import UserNotifications

@MainActor
@Observable
final class AppModel {
    enum Connection: Equatable {
        case notConfigured
        case registering
        case connecting
        case connected
        case failed(String)

        var summary: String {
            switch self {
            case .notConfigured: "Set the hub URL in Settings"
            case .registering: "Registering with the hub..."
            case .connecting: "Connecting..."
            case .connected: "Connected to hub"
            case .failed(let message): message
            }
        }
    }

    static let shared = AppModel()

    var settings: HubSettings
    private(set) var pending = PendingStore()
    private(set) var connection: Connection = .notConfigured
    private(set) var launchAtLogin = false
    /// Last problem worth showing in the menu, such as a failed login item change.
    private(set) var notice: String?

    @ObservationIgnored private var client: HubClient?
    @ObservationIgnored private var socket: HubSocket?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var consumers: [Task<Void, Never>] = []
    @ObservationIgnored private let presence = PresenceMonitor()
    @ObservationIgnored private let panels = PanelController()
    @ObservationIgnored private let settingsWindow = SettingsWindowController()
    @ObservationIgnored private var started = false
    @ObservationIgnored private lazy var notifications = NotificationCoordinator { event in
        await AppModel.shared.handle(event)
    }

    private init() {
        let computerName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        settings = HubSettings.load(defaultDeviceName: computerName)
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true

        notifications.install()
        Task { await notifications.requestAuthorization() }

        panels.answerHandler = { [weak self] request, optionID, text in
            guard let self else { return }
            Task { await self.answer(request, optionID: optionID, text: text) }
        }

        presence.onReport = { [weak self] frame in
            guard let self, let socket = self.socket else { return }
            Task { await socket.send(frame) }
        }
        presence.start()

        refreshLaunchAtLogin()

        if settings.baseURL == nil {
            showSettings()
        } else {
            connect()
        }
    }

    func showSettings() {
        settingsWindow.show(model: self)
    }

    /// Persists the settings, re-registers with the hub and reopens the socket.
    func save(_ newSettings: HubSettings) {
        settings = newSettings
        settings.save()
        connect()
    }

    private func connect() {
        teardown()
        guard let endpoint = settings.endpoint(devHost: Host.current().localizedName) else {
            connection = .notConfigured
            return
        }
        let name = settings.trimmedDeviceName.isEmpty
            ? (Host.current().localizedName ?? "Mac")
            : settings.trimmedDeviceName
        let client = HubClient(endpoint: endpoint)
        self.client = client
        connection = .registering

        connectTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                do {
                    _ = try await client.registerDevice(DeviceRegistration(kind: .mac, name: name))
                    break
                } catch is CancellationError {
                    return
                } catch {
                    self?.connection = .failed(Self.describe(error))
                    try? await Task.sleep(for: .seconds(HubSocket.backoff(attempt: failures)))
                    failures += 1
                }
            }
            guard !Task.isCancelled else { return }
            self?.openSocket(endpoint: endpoint)
        }
    }

    private func openSocket(endpoint: HubEndpoint) {
        let socket = HubSocket(endpoint: endpoint)
        self.socket = socket
        connection = .connecting

        consumers = [
            Task { [weak self] in
                for await frame in socket.frames {
                    self?.handle(frame)
                }
            },
            Task { [weak self] in
                for await state in socket.states {
                    self?.socketStateChanged(state)
                }
            },
        ]
        Task { await socket.start() }
    }

    private func teardown() {
        connectTask?.cancel()
        connectTask = nil
        consumers.forEach { $0.cancel() }
        consumers = []
        if let socket {
            Task { await socket.stop() }
        }
        socket = nil
        client = nil
    }

    private func socketStateChanged(_ state: HubSocket.State) {
        switch state {
        case .connecting: connection = .connecting
        case .connected:
            connection = .connected
            presence.report()
        case .disconnected:
            if connection == .connected { connection = .connecting }
        }
    }

    // MARK: Frames

    private func handle(_ frame: HubFrame) {
        for change in pending.apply(frame) {
            switch change {
            case .delivered(let request):
                Task { await notifications.post(request) }
                panels.show(request)
            case .updated(let request):
                panels.update(request)
            case .retracted(let request):
                notifications.remove(requestID: request.id)
                let summary = request.state == .pending ? "No longer needed here" : request.resolutionSummary
                panels.resolve(requestID: request.id, summary: summary)
            }
        }
    }

    // MARK: Showing

    func showPanel(requestID: String) {
        guard let request = pending.request(id: requestID) else { return }
        panels.show(request)
        NSApp.activate()
    }

    // MARK: Answering

    func handle(_ event: NotificationEvent) async {
        guard let request = pending.request(id: event.requestID) else { return }
        if event.actionID == UNNotificationDefaultActionIdentifier {
            panels.show(request)
            NSApp.activate()
        } else {
            await answer(request, optionID: event.actionID, text: nil)
        }
    }

    func answer(_ request: Request, optionID: String?, text: String?) async {
        guard let client else { return }
        let panelModel = panels.model(for: request.id)
        panelModel?.phase = .sending

        do {
            if request.requiresAuthentication(forOptionID: optionID) {
                try await DeviceAuthenticator.authenticate(
                    reason: "Approve \"\(request.title)\" from \(request.agent.label)"
                )
            }
            _ = try await client.respond(to: request.id, optionID: optionID, text: text)
            finish(request.id, summary: "Answer sent")
        } catch DeviceAuthenticationError.cancelled {
            panelModel?.phase = .idle
        } catch let error as HubError where error.isAlreadyResolved {
            finish(request.id, summary: error.alreadyResolvedDescription ?? "Already answered")
        } catch {
            // Show the panel so the user sees the failure, even when the
            // answer came from a notification action.
            panels.show(request)
            panels.model(for: request.id)?.phase = .failed(Self.describe(error))
        }
    }

    private func finish(_ requestID: String, summary: String) {
        pending.remove(requestID: requestID)
        notifications.remove(requestID: requestID)
        panels.resolve(requestID: requestID, summary: summary)
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let hubError = error as? HubError {
            if hubError.isUnreachable { return "Can't reach the hub. Is Tailscale connected?" }
            return hubError.errorDescription ?? "Something went wrong."
        }
        return error.localizedDescription
    }

    // MARK: Login item

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            notice = nil
        } catch {
            notice = "Launch at login: \(error.localizedDescription)"
        }
        refreshLaunchAtLogin()
    }
}
