// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ATerm",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ATerm", targets: ["ATerm"]),
    ],
    targets: [
        .target(name: "CPTY"),
        .target(
            name: "ATermCore",
            dependencies: ["CPTY"],
            // The terminal model is confined to one thread; skip runtime exclusivity checks in the hot paths.
            swiftSettings: [.unsafeFlags(["-enforce-exclusivity=unchecked"], .when(configuration: .release))]
        ),
        .target(name: "ATermApp", dependencies: ["ATermCore"]),
        .executableTarget(name: "ATerm", dependencies: ["ATermApp"]),
        .testTarget(name: "ATermCoreTests", dependencies: ["ATermCore"]),
        .testTarget(name: "ATermE2ETests", dependencies: ["ATermApp", "ATermCore"]),
        // A real modal loop ends the test runner's main run loop afterwards: it runs alone, in its own process.
        .testTarget(name: "ATermModalTests", dependencies: ["ATermApp", "ATermCore"]),
        // Opt-in checks against the real OpenRouter API (`make live-check`).
        .testTarget(name: "ATermLiveTests", dependencies: ["ATermCore"]),
    ]
)
