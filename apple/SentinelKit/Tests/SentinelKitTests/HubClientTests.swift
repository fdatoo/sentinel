import Foundation
import Testing
@testable import SentinelKit

/// Serves canned responses to a URLSession. Handlers are global, so every suite
/// that uses it is `.serialized`.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    // Justification: the shared state is guarded by `lock`.
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var captured: [URLRequest] = []

    static func install(_ handler: @escaping Handler) {
        lock.withLock {
            self.handler = handler
            captured = []
        }
    }

    static var requests: [URLRequest] { lock.withLock { captured } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = self.request
        // URLSession moves the body into a stream before it reaches the protocol.
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            request.httpBody = data
        }
        let handler = Self.lock.withLock {
            Self.captured.append(request)
            return Self.handler
        }
        do {
            guard let handler else { throw URLError(.badServerResponse) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct HubClientTests {
    let base = URL(string: "http://127.0.0.1:7878")!

    func client(node: String? = nil, host: String? = nil) -> HubClient {
        HubClient(baseURL: base, devNode: node, devHost: host, session: StubURLProtocol.session())
    }

    func json(_ string: String) -> Data { Data(string.utf8) }

    @Test func createRequestPostsBodyAndDecodesReply() async throws {
        StubURLProtocol.install { _ in (201, Data(Fixtures.request.utf8)) }
        let created = try await client().createRequest(NewRequest(kind: .authorize, title: "Bash: rm"))
        #expect(created.id == "01JBV5Q8ZK6V0M7W3T2N4R8C1D")

        let sent = try #require(StubURLProtocol.requests.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.absoluteString == "http://127.0.0.1:7878/v1/requests")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(sent.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["title"] as? String == "Bash: rm")
        #expect(object["kind"] as? String == "authorize")
    }

    @Test func devHeadersOnlyWhenSet() async throws {
        StubURLProtocol.install { _ in (200, Data(Fixtures.request.utf8)) }
        _ = try await client().getRequest(id: "abc")
        var sent = try #require(StubURLProtocol.requests.last)
        #expect(sent.value(forHTTPHeaderField: "X-Sentinel-Node") == nil)
        #expect(sent.value(forHTTPHeaderField: "X-Sentinel-Host") == nil)

        _ = try await client(node: "", host: "").getRequest(id: "abc")
        sent = try #require(StubURLProtocol.requests.last)
        #expect(sent.value(forHTTPHeaderField: "X-Sentinel-Node") == nil)

        _ = try await client(node: "mac-1", host: "studio").getRequest(id: "abc")
        sent = try #require(StubURLProtocol.requests.last)
        #expect(sent.value(forHTTPHeaderField: "X-Sentinel-Node") == "mac-1")
        #expect(sent.value(forHTTPHeaderField: "X-Sentinel-Host") == "studio")
        #expect(sent.httpMethod == "GET")
        #expect(sent.url?.path == "/v1/requests/abc")
    }

    @Test func listUsesQueryAndUnwrapsEnvelope() async throws {
        let body = #"{ "requests": [ \#(Fixtures.request) ] }"#
        StubURLProtocol.install { _ in (200, Data(body.utf8)) }
        let requests = try await client().listRequests(state: .pending, limit: 50)
        #expect(requests.count == 1)
        let url = try #require(StubURLProtocol.requests.last?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items?.first { $0.name == "state" }?.value == "pending")
        #expect(items?.first { $0.name == "limit" }?.value == "50")

        _ = try await client().listRequests()
        #expect(StubURLProtocol.requests.last?.url?.query == nil)
    }

    @Test func respondSendsOptionAndNullText() async throws {
        StubURLProtocol.install { _ in (200, Data(Fixtures.request.utf8)) }
        _ = try await client().respond(to: "abc", optionID: "approve")
        let sent = try #require(StubURLProtocol.requests.last)
        #expect(sent.url?.path == "/v1/requests/abc/response")
        #expect(sent.httpMethod == "POST")
        let body = try #require(sent.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["option_id"] as? String == "approve")
        #expect(object["text"] is NSNull)
    }

    @Test func everyPostWithABodySendsJSONContentType() async throws {
        let device = #"{ "id": "d1", "kind": "mac", "name": "Studio" }"#
        StubURLProtocol.install { request in
            request.url?.path == "/v1/devices" ? (200, Data(device.utf8)) : (200, Data(Fixtures.request.utf8))
        }
        let hub = client()
        _ = try await hub.createRequest(NewRequest(kind: .action, title: "T"))
        _ = try await hub.respond(to: "abc", optionID: "done")
        _ = try await hub.registerDevice(DeviceRegistration(kind: .mac, name: "Studio"))
        let posts = StubURLProtocol.requests.filter { $0.httpMethod == "POST" }
        #expect(posts.count == 3)
        for post in posts {
            #expect(post.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(post.httpBody != nil)
        }
    }

    @Test func decodesCLIDeviceKind() throws {
        let json = #"{ "id": "d2", "kind": "cli", "name": "studio cli", "node": "n" }"#
        #expect(try Fixtures.decode(Device.self, json).kind == .cli)
    }

    @Test func cancelUsesDelete() async throws {
        StubURLProtocol.install { _ in (200, Data(Fixtures.request.utf8)) }
        _ = try await client().cancelRequest(id: "abc")
        #expect(StubURLProtocol.requests.last?.httpMethod == "DELETE")
        #expect(StubURLProtocol.requests.last?.url?.path == "/v1/requests/abc")
    }

    @Test func registersAndListsDevices() async throws {
        let device = #"{ "id": "d1", "kind": "mac", "name": "Studio", "node": "n", "created_at": "2026-10-24T09:00:00Z", "last_seen_at": "2026-10-24T09:00:01Z" }"#
        StubURLProtocol.install { request in
            request.httpMethod == "POST" ? (200, Data(device.utf8)) : (200, Data(#"{ "devices": [ \#(device) ] }"#.utf8))
        }
        let registered = try await client().registerDevice(DeviceRegistration(kind: .mac, name: "Studio"))
        #expect(registered.id == "d1")
        #expect(StubURLProtocol.requests.last?.url?.path == "/v1/devices")

        let devices = try await client().listDevices()
        #expect(devices.map(\.name) == ["Studio"])
    }

    @Test func mapsAlreadyResolved() async throws {
        StubURLProtocol.install { _ in (409, Data(Fixtures.error.utf8)) }
        do {
            _ = try await client().respond(to: "abc", optionID: "approve")
            Issue.record("expected a throw")
        } catch let error as HubError {
            #expect(error == .api(status: 409, code: "already_resolved", message: "answered on Sam's iPhone"))
            #expect(error.isAlreadyResolved)
            #expect(error.alreadyResolvedDescription == "Already answered on Sam's iPhone")
            #expect(!error.isUnreachable)
        }
    }

    @Test func mapsOtherErrorCodes() async throws {
        for (status, code) in [(400, "invalid_request"), (403, "forbidden"), (404, "not_found")] {
            let body = #"{ "error": { "code": "\#(code)", "message": "nope" } }"#
            StubURLProtocol.install { _ in (status, Data(body.utf8)) }
            await #expect(throws: HubError.api(status: status, code: code, message: "nope")) {
                _ = try await client().getRequest(id: "abc")
            }
        }
    }

    @Test func nonEnvelopeErrorBodyStillThrowsTyped() async throws {
        StubURLProtocol.install { _ in (502, Data("bad gateway".utf8)) }
        await #expect(throws: HubError.api(status: 502, code: "http_502", message: "bad gateway")) {
            _ = try await client().getRequest(id: "abc")
        }
    }

    @Test func networkFailureIsUnreachable() async throws {
        StubURLProtocol.install { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await client().listRequests()
            Issue.record("expected a throw")
        } catch let error as HubError {
            #expect(error == .unreachable(.cannotConnectToHost))
            #expect(error.isUnreachable)
        }
    }

    @Test func malformedSuccessBodyIsDecodingError() async throws {
        StubURLProtocol.install { _ in (200, Data("not json".utf8)) }
        do {
            _ = try await client().getRequest(id: "abc")
            Issue.record("expected a throw")
        } catch let error as HubError {
            guard case .decoding = error else { Issue.record("wrong error \(error)"); return }
        }
    }

    // MARK: Long poll

    @Test func waitSendsWaitParameter() async throws {
        StubURLProtocol.install { _ in (200, Data(Fixtures.request.utf8)) }
        _ = try await client().getRequest(id: "abc", wait: 60)
        let sent = try #require(StubURLProtocol.requests.last)
        #expect(sent.url?.query == "wait=60")
        #expect(sent.timeoutInterval > 60)
    }

    @Test func awaitResolutionLoopsUntilNotPending() async throws {
        let answered = Fixtures.request.replacingOccurrences(of: "\"state\": \"pending\"", with: "\"state\": \"answered\"")
        let counter = Counter()
        StubURLProtocol.install { _ in
            let n = counter.next()
            return (200, Data((n < 3 ? Fixtures.request : answered).utf8))
        }
        let resolved = try await client().awaitResolution(id: "abc", pollSeconds: 30, minimumPollInterval: .zero)
        #expect(resolved.state == .answered)
        #expect(StubURLProtocol.requests.count == 3)
        #expect(StubURLProtocol.requests.allSatisfy { $0.url?.query == "wait=30" })
    }

    @Test func awaitResolutionPropagatesErrors() async throws {
        let counter = Counter()
        StubURLProtocol.install { _ in
            if counter.next() == 1 { return (200, Data(Fixtures.request.utf8)) }
            return (404, Data(#"{ "error": { "code": "not_found", "message": "gone" } }"#.utf8))
        }
        await #expect(throws: HubError.api(status: 404, code: "not_found", message: "gone")) {
            _ = try await client().awaitResolution(id: "abc", minimumPollInterval: .zero)
        }
    }

    @Test func awaitResolutionStopsWhenCancelled() async throws {
        StubURLProtocol.install { _ in (200, Data(Fixtures.request.utf8)) }
        let hub = client()
        let task = Task { try await hub.awaitResolution(id: "abc", minimumPollInterval: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    // MARK: Pure helpers

    @Test func baseURLParsing() {
        #expect(HubEndpoint.parseBaseURL("https://sentinel.ts.net")?.absoluteString == "https://sentinel.ts.net")
        #expect(HubEndpoint.parseBaseURL(" sentinel.ts.net ")?.absoluteString == "https://sentinel.ts.net")
        #expect(HubEndpoint.parseBaseURL("http://127.0.0.1:7878")?.port == 7878)
        #expect(HubEndpoint.parseBaseURL("") == nil)
        #expect(HubEndpoint.parseBaseURL("ftp://x") == nil)
    }

    @Test func socketURLSwapsScheme() {
        #expect(HubSocket.socketURL(for: URL(string: "https://h.ts.net")!)?.absoluteString == "wss://h.ts.net/v1/devices/ws")
        #expect(HubSocket.socketURL(for: URL(string: "http://127.0.0.1:7878")!)?.absoluteString == "ws://127.0.0.1:7878/v1/devices/ws")
    }

    @Test func backoffDoublesAndCapsAtThirtySeconds() {
        let delays = (0..<8).map(HubSocket.backoff(attempt:))
        #expect(delays == [1, 2, 4, 8, 16, 30, 30, 30])
        #expect(HubSocket.backoff(attempt: 1_000) == 30)
        #expect(HubSocket.backoff(attempt: -3) == 1)
    }
}

final class Counter: @unchecked Sendable {
    // Justification: all access goes through `lock`.
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
