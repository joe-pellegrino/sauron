// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Sauron",
    platforms: [
        .macOS(.v26)   // Foundation Models (on-device summarization) requires macOS 26+
    ],
    targets: [
        .executableTarget(
            name: "Sauron",
            path: "Sources/Sauron",
            swiftSettings: [
                // Mirror the Xcode target (SWIFT_VERSION = 5.0) so the SPM build
                // matches the shipping build.
                .swiftLanguageMode(.v5)
            ]
        ),
        // Security regression tests. Run with `swift test`. Not part of the
        // shipping app bundle (Xcode target), so it lives in SPM only.
        .testTarget(
            name: "SauronTests",
            dependencies: ["Sauron"],
            path: "Tests/SauronTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
