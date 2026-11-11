// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KarenRemoteCompanion",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CompanionCore", targets: ["CompanionCore"]),
        .executable(name: "karen-companion", targets: ["CompanionApp"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CompanionCore",
            path: "Sources/CompanionCore"
        ),
        .executableTarget(
            name: "CompanionApp",
            dependencies: ["CompanionCore"],
            path: "Sources/CompanionApp"
        ),
        .testTarget(
            name: "CompanionCoreTests",
            dependencies: ["CompanionCore"],
            path: "Tests/CompanionCoreTests"
        ),
    ]
)

