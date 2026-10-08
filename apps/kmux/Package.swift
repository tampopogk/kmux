// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kmux",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "kmux", targets: ["Kmux"])],
    targets: [
        .binaryTarget(name: "GhosttyKit", path: "../../target/ghosttykit/GhosttyKit.xcframework"),
        .target(name: "KmuxCore"),
        // The iOS Simulator's screen and touches, through Xcode's private frameworks.
        .target(name: "SimBridge", linkerSettings: ["AppKit", "IOSurface", "QuartzCore"].map { .linkedFramework($0) }),
        .testTarget(name: "KmuxCoreTests", dependencies: ["KmuxCore"]),
        .executableTarget(
            name: "Kmux",
            dependencies: ["KmuxCore", "GhosttyKit", "SimBridge"],
            linkerSettings: [.linkedLibrary("c++")] + ["AppKit", "Carbon", "CoreText", "IOSurface", "Metal", "QuartzCore", "UniformTypeIdentifiers"].map { .linkedFramework($0) }
        ),
    ]
)
