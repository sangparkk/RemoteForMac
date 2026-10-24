// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RemoteCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "RemoteCore", targets: ["RemoteCore"])],
    targets: [
        .target(name: "RemoteCore", path: "Shared"),
        .testTarget(name: "RemoteCoreTests", dependencies: ["RemoteCore"], path: "Tests")
    ]
)
