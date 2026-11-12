// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TunnelOnePolicy",
    platforms: [.macOS(.v12)],
    products: [.library(name: "TunnelOnePolicy", targets: ["TunnelOnePolicy"])],
    targets: [
        .target(name: "TunnelOnePolicy", path: "Sources/TunnelOneShared"),
        .testTarget(name: "ProxySettingsTests", dependencies: ["TunnelOnePolicy"])
    ]
)
