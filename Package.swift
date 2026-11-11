// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Larynx",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LarynxText", targets: ["LarynxText"]),
        .library(name: "LarynxCore", targets: ["LarynxCore"]),
        .executable(name: "larynx", targets: ["larynx"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.18.3", traits: []),
    ],
    targets: [
        .target(
            name: "LarynxText",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "LarynxCore",
            dependencies: ["LarynxText", .product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LarynxTextTests",
            dependencies: ["LarynxText"],
            path: "tests/LarynxTextTests",
            exclude: ["README.md"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "larynx",
            dependencies: ["LarynxCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
