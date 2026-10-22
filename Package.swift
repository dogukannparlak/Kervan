// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kervan",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "EngineCore", targets: ["EngineCore"]),
        .library(name: "QueueKit", targets: ["QueueKit"]),
        .executable(name: "kervan", targets: ["kervan"]),
        .executable(name: "kervand", targets: ["kervand"]),
        .executable(name: "kervan-native-host", targets: ["kervan-native-host"]),
        .executable(name: "KervanApp", targets: ["KervanApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "EngineCore",
            resources: [.copy("Resources/presets")]
        ),
        .target(
            name: "QueueKit",
            dependencies: ["EngineCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "KervanIPC",
            dependencies: ["QueueKit"]
        ),
        .executableTarget(
            name: "kervand",
            dependencies: ["EngineCore", "QueueKit", "KervanIPC"]
        ),
        .executableTarget(
            name: "KervanApp",
            dependencies: ["EngineCore", "QueueKit", "KervanIPC"]
        ),
        .executableTarget(
            name: "kervan-native-host",
            dependencies: ["KervanIPC"]
        ),
        .executableTarget(
            name: "kervan",
            dependencies: [
                "EngineCore",
                "QueueKit",
                "KervanIPC",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "EngineCoreTests",
            dependencies: ["EngineCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "QueueKitTests",
            dependencies: ["QueueKit", "KervanIPC"]
        ),
    ]
)
