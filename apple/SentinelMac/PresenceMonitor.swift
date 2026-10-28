import AppKit
import CoreGraphics
import SentinelKit

/// Tracks the signals the hub routes on (idle time, lock, sleep, session) and
/// reports them: every 15 seconds, and at once when any of them changes.
@MainActor
final class PresenceMonitor {
    private static let heartbeat: TimeInterval = 15
    private static let sampleInterval: Duration = .seconds(1)
    /// Idle time falling by more than this since the last report means the user
    /// came back; report it without waiting for the heartbeat.
    private static let returnThreshold: Double = 5

    var onReport: ((PresenceFrame) -> Void)?

    private var locked = false
    private var asleep = false
    private var displayAsleep = false
    private var sessionActive = true

    private var lastReport = Date.distantPast
    private var lastReportedIdle: Double = 0
    private var loop: Task<Void, Never>?
    private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    func start() {
        guard loop == nil else { return }
        readInitialState()
        observeSystem()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.sampleInterval)
                self?.tick()
            }
        }
        report()
    }

    func stop() {
        loop?.cancel()
        loop = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }

    func snapshot() -> PresenceFrame {
        PresenceFrame(
            idleSeconds: Self.idleSeconds(),
            locked: locked,
            asleep: asleep,
            displayAsleep: displayAsleep,
            sessionActive: sessionActive
        )
    }

    /// Sends a snapshot now. Also the hook for "socket just connected".
    func report() {
        let frame = snapshot()
        lastReport = Date()
        lastReportedIdle = frame.idleSeconds
        onReport?(frame)
    }

    private func tick() {
        let idle = Self.idleSeconds()
        let heartbeatDue = Date().timeIntervalSince(lastReport) >= Self.heartbeat
        let userReturned = lastReportedIdle - idle > Self.returnThreshold
        if heartbeatDue || userReturned { report() }
    }

    static func idleSeconds() -> Double {
        // ~0 is kCGAnyInputEventType. The HID state counts only the physical
        // keyboard and mouse, so Screen Sharing input doesn't make this Mac
        // look attended; the combined session state would count it.
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func readInitialState() {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return }
        locked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
        sessionActive = session["kCGSSessionOnConsoleKey"] as? Bool ?? true
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        observe(distributed, "com.apple.screenIsLocked") { $0.locked = true }
        observe(distributed, "com.apple.screenIsUnlocked") { $0.locked = false }
        observe(workspace, NSWorkspace.willSleepNotification.rawValue) { $0.asleep = true }
        observe(workspace, NSWorkspace.didWakeNotification.rawValue) { $0.asleep = false }
        observe(workspace, NSWorkspace.screensDidSleepNotification.rawValue) { $0.displayAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification.rawValue) { $0.displayAsleep = false }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification.rawValue) { $0.sessionActive = false }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification.rawValue) { $0.sessionActive = true }
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: String,
        apply: @escaping @MainActor (PresenceMonitor) -> Void
    ) {
        let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                apply(self)
                self.report()
            }
        }
        observers.append((center, token))
    }
}
