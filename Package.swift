// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "EdgeBeat",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(
            name: "EdgeBeat",
            path: "Sources/EdgeBeat",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "EdgeBeatTests",
            dependencies: ["EdgeBeat"],
            path: "Tests/EdgeBeatTests"
        )
    ]
)
