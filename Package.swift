// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TextReaderHelper",
    platforms: [.macOS(.v14)],
    dependencies: [
        // "Check for Updates…": downloads, verifies and installs new releases.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "TextReaderHelper",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
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
                // build_app.sh puts Sparkle.framework in Slit.app/Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "TextReaderHelperTests",
            dependencies: ["TextReaderHelper"],
            path: "Tests/TextReaderHelperTests"
        ),
    ]
)
