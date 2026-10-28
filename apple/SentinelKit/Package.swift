// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SentinelKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "SentinelKit", targets: ["SentinelKit"]),
    ],
    targets: [
        .target(name: "SentinelKit"),
        .testTarget(name: "SentinelKitTests", dependencies: ["SentinelKit"]),
    ],
    swiftLanguageModes: [.v6]
)
