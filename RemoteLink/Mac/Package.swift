// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RemoteLinkMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "RemoteLinkMac", targets: ["RemoteLinkMac"]),
        .executable(name: "karen-remote-cli", targets: ["RemoteLinkCLI"]),
    ],
    targets: [
        .target(
            name: "RemoteLinkMac",
            path: "Sources/RemoteLinkMac"
        ),
        .executableTarget(
            name: "RemoteLinkCLI",
            dependencies: ["RemoteLinkMac"],
            path: "Sources/RemoteLinkCLI"
        ),
        .testTarget(
            name: "RemoteLinkMacTests",
            dependencies: ["RemoteLinkMac"],
            path: "Tests/RemoteLinkMacTests"
        ),
    ]
)

