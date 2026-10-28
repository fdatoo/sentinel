import Foundation

/// The Mac's WebSocket to `/v1/devices/ws`. It reconnects with exponential
/// backoff until `stop()`, publishes hub frames on `frames`, and drops presence
/// frames sent while disconnected (the next heartbeat replaces them).
public actor HubSocket {
    public enum State: Sendable, Hashable {
        case connecting
        case connected
        case disconnected
    }

    public static let maxBackoff: TimeInterval = 30

    /// Frames from the hub. Single consumer.
    public nonisolated let frames: AsyncStream<HubFrame>
    /// Connection changes. Single consumer. A `.connected` after a gap is the cue
    /// to send presence right away.
    public nonisolated let states: AsyncStream<State>

    private let endpoint: HubEndpoint
    private let session: URLSession
    private let frameContinuation: AsyncStream<HubFrame>.Continuation
    private let stateContinuation: AsyncStream<State>.Continuation
    private var runTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?

    public init(endpoint: HubEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
        (frames, frameContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (states, stateContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    deinit {
        runTask?.cancel()
        frameContinuation.finish()
        stateContinuation.finish()
    }

    public func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            await self?.run()
        }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        stateContinuation.yield(.disconnected)
    }

    /// Returns false when there is no live connection or the write failed.
    @discardableResult
    public func send(_ presence: PresenceFrame) async -> Bool {
        guard let socket else { return false }
        do {
            let data = try SentinelJSON.makeEncoder().encode(HubFrame.presence(presence))
            try await socket.send(.string(String(decoding: data, as: UTF8.self)))
            return true
        } catch {
            // A failed write means the connection is dead; canceling makes
            // receive() throw so the run loop reconnects.
            socket.cancel(with: .abnormalClosure, reason: nil)
            return false
        }
    }

    /// 1s, 2s, 4s, ... capped at 30s. `attempt` counts consecutive failures from 0.
    public static func backoff(attempt: Int) -> TimeInterval {
        min(maxBackoff, pow(2, Double(max(0, min(attempt, 10)))))
    }

    public static func socketURL(for baseURL: URL) -> URL? {
        guard var parts = URLComponents(url: baseURL.appending(path: "v1/devices/ws"), resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch parts.scheme?.lowercased() {
        case "https": parts.scheme = "wss"
        case "http": parts.scheme = "ws"
        default: break
        }
        return parts.url
    }

    private func run() async {
        guard let url = Self.socketURL(for: endpoint.baseURL) else { return }
        var failures = 0

        while !Task.isCancelled {
            stateContinuation.yield(.connecting)
            var request = URLRequest(url: url)
            endpoint.apply(to: &request)
            let task = session.webSocketTask(with: request)
            socket = task
            task.resume()

            do {
                let first = try await Self.firstMessage(task)
                failures = 0
                stateContinuation.yield(.connected)
                handle(first)
                while true {
                    let message = try await task.receive()
                    handle(message)
                }
            } catch {
                // Falls through to teardown and backoff.
            }

            task.cancel(with: .goingAway, reason: nil)
            socket = nil
            if Task.isCancelled { break }
            stateContinuation.yield(.disconnected)

            let delay = Self.backoff(attempt: failures)
            failures += 1
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let raw): data = raw
        @unknown default: return
        }
        // A frame we can't parse is skipped; it must not take the socket down.
        if let frame = try? SentinelJSON.makeDecoder().decode(HubFrame.self, from: data) {
            frameContinuation.yield(frame)
        }
    }

    /// The hub opens every connection with a sync frame, so receiving it is how
    /// we learn the upgrade succeeded. (A ping doesn't work for this: URLSession
    /// holds the pong behind any message that arrived first and hasn't been
    /// received, and the sync frame usually wins that race.)
    private static func firstMessage(_ task: URLSessionWebSocketTask) async throws -> URLSessionWebSocketTask.Message {
        // Canceling the task makes the pending receive fail, so a server that
        // never answers can't hold the connection in "connecting".
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            task.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }
        return try await task.receive()
    }
}
