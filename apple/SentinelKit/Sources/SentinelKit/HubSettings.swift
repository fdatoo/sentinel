import Foundation

/// What the user configures in either app: where the hub is, what to call this
/// device, and an optional dev-mode node identity.
public struct HubSettings: Equatable, Sendable {
    public var hubURL: String
    public var deviceName: String
    public var devNode: String

    public init(hubURL: String = "", deviceName: String, devNode: String = "") {
        self.hubURL = hubURL
        self.deviceName = deviceName
        self.devNode = devNode
    }

    private enum Key {
        static let hubURL = "sentinel.hubURL"
        static let deviceName = "sentinel.deviceName"
        static let devNode = "sentinel.devNode"
    }

    public static func load(from defaults: UserDefaults = .standard, defaultDeviceName: String) -> HubSettings {
        let name = defaults.string(forKey: Key.deviceName) ?? ""
        return HubSettings(
            hubURL: defaults.string(forKey: Key.hubURL) ?? "",
            deviceName: name.isEmpty ? defaultDeviceName : name,
            devNode: defaults.string(forKey: Key.devNode) ?? ""
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(hubURL, forKey: Key.hubURL)
        defaults.set(deviceName, forKey: Key.deviceName)
        defaults.set(devNode, forKey: Key.devNode)
    }

    public var baseURL: URL? { HubEndpoint.parseBaseURL(hubURL) }

    public var trimmedDeviceName: String {
        deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The dev identity headers are sent only when a node id is set; the host
    /// header then carries `devHost`, a display name for this machine.
    public func endpoint(devHost: String?) -> HubEndpoint? {
        guard let baseURL else { return nil }
        let node = devNode.trimmingCharacters(in: .whitespacesAndNewlines)
        if node.isEmpty { return HubEndpoint(baseURL: baseURL) }
        return HubEndpoint(baseURL: baseURL, devNode: node, devHost: devHost)
    }
}
