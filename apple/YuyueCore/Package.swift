// swift-tools-version: 6.0
// The Rust core, built by apple/build-core.sh.
import PackageDescription

let package = Package(
    name: "YuyueCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "YuyueCore", targets: ["YuyueCore"])],
    targets: [
        .binaryTarget(name: "YuyueCoreFFI", path: "YuyueCoreFFI.xcframework"),
        .target(
            name: "YuyueCore",
            dependencies: ["YuyueCoreFFI"],
            // The generated bindings predate Swift 6's strict concurrency checks.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
