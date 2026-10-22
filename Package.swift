// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kervan",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "EngineCore", targets: ["EngineCore"]),
        .executable(name: "kervan", targets: ["kervan"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "EngineCore",
            resources: [.copy("Resources/presets")]
        ),
        .executableTarget(
            name: "kervan",
            dependencies: [
                "EngineCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "EngineCoreTests",
            dependencies: ["EngineCore"]
        ),
    ]
)
