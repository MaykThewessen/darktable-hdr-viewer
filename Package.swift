// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HDRViewer",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        // Pure Foundation/Darwin library: protocol model, header codec, IPC server.
        // No AppKit, Metal, or other UI frameworks. Importable by tests.
        .target(
            name: "HDRViewerCore",
            path: "Sources/HDRViewerCore"
        ),

        // App executable: AppKit/Metal UI. Imports HDRViewerCore for the IPC layer.
        .executableTarget(
            name: "HDRViewer",
            dependencies: ["HDRViewerCore"],
            path: "Sources/HDRViewer",
            exclude: ["Shaders.metal"],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("QuartzCore")
            ]
        ),

        // Protocol regression tests. No AppKit/Metal dependency.
        .testTarget(
            name: "HDRViewerTests",
            dependencies: ["HDRViewerCore"],
            path: "Tests/HDRViewerTests"
        )
    ]
)
