import Foundation

/// Where the hub is and, in dev mode only, who we claim to be.
public struct HubEndpoint: Sendable, Hashable {
    public var baseURL: URL
    /// `X-Sentinel-Node`, sent only when non-empty.
    public var devNode: String?
    /// `X-Sentinel-Host`, sent only when non-empty.
    public var devHost: String?

    public init(baseURL: URL, devNode: String? = nil, devHost: String? = nil) {
        self.baseURL = baseURL
        self.devNode = devNode
        self.devHost = devHost
    }

    func apply(to request: inout URLRequest) {
        if let node = devNode, !node.isEmpty {
            request.setValue(node, forHTTPHeaderField: "X-Sentinel-Node")
        }
        if let host = devHost, !host.isEmpty {
            request.setValue(host, forHTTPHeaderField: "X-Sentinel-Host")
        }
    }

    /// Parses user-entered text. A bare host gets `https://`.
    public static func parseBaseURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil
        else { return nil }
        return url
    }
}

public struct HubClient: Sendable {
    public let endpoint: HubEndpoint
    private let session: URLSession

    /// Time limit for ordinary calls. Long polls add their wait on top.
    public static let requestTimeout: TimeInterval = 15

    public init(endpoint: HubEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    public init(baseURL: URL, devNode: String? = nil, devHost: String? = nil, session: URLSession = .shared) {
        self.init(endpoint: HubEndpoint(baseURL: baseURL, devNode: devNode, devHost: devHost), session: session)
    }

    // MARK: Requests

    public func createRequest(_ body: NewRequest) async throws -> Request {
        try await send("POST", ["v1", "requests"], body: body)
    }

    public func getRequest(id: String) async throws -> Request {
        try await send("GET", ["v1", "requests", id])
    }

    /// One long poll: returns when the request leaves `pending` or `wait` seconds
    /// pass (the hub caps it at 300), whichever comes first.
    public func getRequest(id: String, wait: Int) async throws -> Request {
        try await send(
            "GET", ["v1", "requests", id],
            query: [URLQueryItem(name: "wait", value: String(wait))],
            timeout: Self.requestTimeout + TimeInterval(wait)
        )
    }

    /// Long-polls until the request leaves `pending`, then returns it. Cancel the
    /// surrounding task to stop. `minimumPollInterval` keeps a hub that returns
    /// early from turning this into a busy loop.
    public func awaitResolution(
        id: String,
        pollSeconds: Int = 60,
        minimumPollInterval: Duration = .seconds(1)
    ) async throws -> Request {
        while true {
            try Task.checkCancellation()
            let started = ContinuousClock.now
            let request = try await getRequest(id: id, wait: pollSeconds)
            if request.state != .pending { return request }
            let elapsed = ContinuousClock.now - started
            if elapsed < minimumPollInterval {
                try await Task.sleep(for: minimumPollInterval - elapsed)
            }
        }
    }

    public func listRequests(state: RequestState? = nil, limit: Int? = nil) async throws -> [Request] {
        var query: [URLQueryItem] = []
        if let state { query.append(URLQueryItem(name: "state", value: state.rawValue)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        let list: RequestList = try await send("GET", ["v1", "requests"], query: query)
        return list.requests
    }

    public func cancelRequest(id: String) async throws -> Request {
        try await send("DELETE", ["v1", "requests", id])
    }

    public func respond(to id: String, optionID: String?, text: String? = nil) async throws -> Request {
        try await send("POST", ["v1", "requests", id, "response"], body: AnswerBody(optionID: optionID, text: text))
    }

    // MARK: Devices

    public func registerDevice(_ registration: DeviceRegistration) async throws -> Device {
        try await send("POST", ["v1", "devices"], body: registration)
    }

    public func listDevices() async throws -> [Device] {
        let list: DeviceList = try await send("GET", ["v1", "devices"])
        return list.devices
    }

    // MARK: Plumbing

    func makeURL(_ components: [String], query: [URLQueryItem] = []) -> URL {
        var url = endpoint.baseURL
        for component in components {
            url.append(component: component)
        }
        guard !query.isEmpty, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        parts.queryItems = query
        return parts.url ?? url
    }

    private func send<Response: Decodable>(
        _ method: String,
        _ path: [String],
        query: [URLQueryItem] = [],
        body: (any Encodable & Sendable)? = nil,
        timeout: TimeInterval = HubClient.requestTimeout
    ) async throws -> Response {
        var request = URLRequest(url: makeURL(path, query: query), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        endpoint.apply(to: &request)
        if let body {
            request.httpBody = try SentinelJSON.makeEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw HubError.unreachable(error.code)
        }

        guard let http = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if let envelope = try? SentinelJSON.makeDecoder().decode(ErrorEnvelope.self, from: data) {
                throw HubError.api(status: http.statusCode, code: envelope.error.code, message: envelope.error.message)
            }
            let text = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw HubError.api(status: http.statusCode, code: "http_\(http.statusCode)", message: text)
        }

        do {
            return try SentinelJSON.makeDecoder().decode(Response.self, from: data)
        } catch {
            throw HubError.decoding(String(describing: error))
        }
    }
}
