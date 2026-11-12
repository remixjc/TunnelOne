// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TunnelOnePolicy",
    platforms: [.macOS(.v13)],
    products: [.library(name: "TunnelOnePolicy", targets: ["TunnelOnePolicy"])],
    targets: [
        .target(name: "TunnelOnePolicy", path: "Sources/TunnelOneShared"),
        .target(name: "TunnelOneStore", dependencies: ["TunnelOnePolicy"], path: "Sources/SystemExtension",
                exclude: ["ControlService.swift", "main.swift"]),
        .testTarget(name: "ProxySettingsTests", dependencies: ["TunnelOnePolicy"]),
        .testTarget(name: "SnapshotStoreTests", dependencies: ["TunnelOnePolicy", "TunnelOneStore"])
    ]
)
