// swift-tools-version: 6.0
// K.A.R.E.N. – macOS AI Personal Assistant
// Build with: swift build  (or open KarenApp.xcodeproj in Xcode)
//
// NOTE: Metal shaders (KarenApp/Sources/Metal/Orb.metal) require Xcode.app's
// metal compiler. When building with `swift build` (CLI tools only), the app
// uses a SwiftUI Canvas procedural renderer. Full Metal rendering is available
// by opening the project in Xcode.

import PackageDescription

let package = Package(
    name: "KarenApp",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "KarenApp", targets: ["KarenApp"]),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "KarenApp",
            path: "KarenApp/Sources",
            exclude: [
                // Orb.metal requires Xcode.app (metal CLI tool).
                // OrbCanvasView.swift is the active Canvas renderer.
                "Metal/Orb.metal",
            ],
            swiftSettings: [
                .define("CANVAS_RENDERER"),
            ]
        ),
    ],
    // The app uses callback-based Apple audio/network APIs that predate strict
    // Swift 6 isolation checking. Keep the Swift 6 toolchain but compile sources
    // in Swift 5 language mode until those APIs are migrated to actor isolation.
    swiftLanguageModes: [.v5]
)
