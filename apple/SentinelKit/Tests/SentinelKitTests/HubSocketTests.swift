import Foundation
import Network
import Testing
@testable import SentinelKit

/// A loopback WebSocket server built on Network.framework.
final class LoopbackWebSocketServer: @unchecked Sendable {
    // Justification: `connections` and `headers` are only touched under `lock`;
    // the listener and queue are immutable after init.
    private let queue = DispatchQueue(label: "loopback-ws")
    private let listener: NWListener
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var headerLog: [[String: String]] = []
    let received: AsyncStream<String>
    private let receivedContinuation: AsyncStream<String>.Continuation
    private let greeting: String?

    init(greeting: String?) throws {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.setClientRequestHandler(DispatchQueue(label: "loopback-ws-handshake")) { _, headers in
            NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        listener = try NWListener(using: parameters, on: .any)
        self.greeting = greeting
        (received, receivedContinuation) = AsyncStream.makeStream()
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let once = Counter()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready where once.next() == 1:
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error) where once.next() == 1:
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    var connectionCount: Int { lock.withLock { connections.count } }

    func dropAllConnections() {
        let current = lock.withLock { connections }
        for connection in current { connection.cancel() }
    }

    func stop() {
        listener.cancel()
        dropAllConnections()
        receivedContinuation.finish()
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        // The connection reports ready before the upgrade response is flushed, and a
        // frame sent in that window aborts the client, so wait a beat.
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard state == .ready, let self, let connection, let greeting = self.greeting else { return }
            self.queue.asyncAfter(deadline: .now() + 0.3) { self.send(greeting, on: connection) }
        }
        connection.start(queue: queue)
        receiveLoop(connection)
    }

    private func send(_ text: String, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .text, let data {
                self.receivedContinuation.yield(String(decoding: data, as: UTF8.self))
            }
            self.receiveLoop(connection)
        }
    }
}

@Suite(.serialized) struct HubSocketTests {
    @Test(.timeLimit(.minutes(1))) func connectsReceivesFramesAndSendsPresence() async throws {
        let sync = Fixtures.sync(Fixtures.request)
        let server = try LoopbackWebSocketServer(greeting: sync)
        let port = try await server.start()
        defer { server.stop() }

        let socket = HubSocket(
            endpoint: HubEndpoint(baseURL: URL(string: "http://127.0.0.1:\(port)")!, devNode: "mac-1")
        )
        await socket.start()

        var connected = false
        for await state in socket.states where state == .connected {
            connected = true
            break
        }
        #expect(connected)

        var frames = socket.frames.makeAsyncIterator()
        let first = await frames.next()
        guard case .sync(let requests)? = first else {
            Issue.record("expected a sync frame, got \(String(describing: first))")
            await socket.stop()
            return
        }
        #expect(requests.map(\.id) == ["01JBV5Q8ZK6V0M7W3T2N4R8C1D"])

        let sent = await socket.send(PresenceFrame(idleSeconds: 3, asleep: true))
        #expect(sent)
        var incoming = server.received.makeAsyncIterator()
        let text = try #require(await incoming.next())
        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["type"] as? String == "presence")
        #expect(object["asleep"] as? Bool == true)
        #expect(object["idle_seconds"] as? Double == 3)

        await socket.stop()
    }

    @Test(.timeLimit(.minutes(1))) func reconnectsAfterTheServerDropsTheConnection() async throws {
        // Like the hub, greet every connection with a sync frame.
        let server = try LoopbackWebSocketServer(greeting: Fixtures.sync(Fixtures.request))
        let port = try await server.start()
        defer { server.stop() }

        let socket = HubSocket(endpoint: HubEndpoint(baseURL: URL(string: "http://127.0.0.1:\(port)")!))
        await socket.start()

        var states = socket.states.makeAsyncIterator()
        var connects = 0
        var dropped = false
        let deadline = ContinuousClock.now + .seconds(15)
        while connects < 2, ContinuousClock.now < deadline, let state = await states.next() {
            if state == .connected {
                connects += 1
                if connects == 1 {
                    server.dropAllConnections()
                    dropped = true
                }
            }
        }
        #expect(dropped)
        #expect(connects == 2)
        await socket.stop()
    }

    @Test func sendReturnsFalseWhenNotConnected() async {
        let socket = HubSocket(endpoint: HubEndpoint(baseURL: URL(string: "http://127.0.0.1:1")!))
        #expect(await socket.send(PresenceFrame(idleSeconds: 0)) == false)
    }
}
