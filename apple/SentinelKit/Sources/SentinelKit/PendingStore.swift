import Foundation

/// The set of requests currently pending on this device, fed by hub frames.
/// A value type so the apply logic is testable without UI.
public struct PendingStore: Sendable {
    public enum Change: Sendable, Hashable {
        /// A request this store hadn't seen. Show it.
        case delivered(Request)
        /// A request left. Carries the terminal request when the hub sent one
        /// (`retract`), or the last known copy when a `sync` dropped it.
        case retracted(Request)
        /// Already known; refreshed in place.
        case updated(Request)
    }

    public private(set) var requests: [Request] = []

    public init() {}

    public var count: Int { requests.count }

    public func request(id: String) -> Request? {
        requests.first { $0.id == id }
    }

    @discardableResult
    public mutating func apply(_ frame: HubFrame) -> [Change] {
        switch frame {
        case .sync(let incoming):
            return replace(with: incoming)
        case .deliver(let request):
            return [upsert(request)].compactMap { $0 }
        case .retract(let request):
            guard remove(id: request.id) != nil else { return [] }
            return [.retracted(request)]
        case .presence, .unknown:
            return []
        }
    }

    private mutating func replace(with incoming: [Request]) -> [Change] {
        var changes: [Change] = []
        let incomingPending = incoming.filter { $0.state == .pending }
        let incomingIDs = Set(incomingPending.map(\.id))

        for existing in requests where !incomingIDs.contains(existing.id) {
            changes.append(.retracted(existing))
        }
        let oldIDs = Set(requests.map(\.id))
        for request in incomingPending {
            changes.append(oldIDs.contains(request.id) ? .updated(request) : .delivered(request))
        }
        requests = incomingPending.sorted(by: Self.newestFirst)
        return changes
    }

    private mutating func upsert(_ request: Request) -> Change? {
        guard request.state == .pending else {
            // A deliver carrying a terminal request is a retract in all but name.
            return remove(id: request.id) == nil ? nil : .retracted(request)
        }
        if let index = requests.firstIndex(where: { $0.id == request.id }) {
            requests[index] = request
            return .updated(request)
        }
        requests.append(request)
        requests.sort(by: Self.newestFirst)
        return .delivered(request)
    }

    private mutating func remove(id: String) -> Request? {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return nil }
        return requests.remove(at: index)
    }

    /// Removes a request after this device answered it.
    public mutating func remove(requestID: String) {
        _ = remove(id: requestID)
    }

    private static func newestFirst(_ a: Request, _ b: Request) -> Bool {
        switch (a.createdAt, b.createdAt) {
        case (let x?, let y?): return x > y
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return a.id > b.id
        }
    }
}
