// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TextReaderHelper",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TextReaderHelper",
            path: "Sources",
            resources: [
                .copy("Resources/OpenDyslexic-Regular.otf"),
                .copy("Resources/OpenDyslexic-Bold.otf")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(
            name: "TextReaderHelperTests",
            dependencies: ["TextReaderHelper"],
            path: "Tests/TextReaderHelperTests"
        ),
    ]
)
