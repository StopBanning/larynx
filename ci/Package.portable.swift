// swift-tools-version: 6.1
// The portable part of Larynx only: the text cleanup (LarynxText) and its tests, with no Apple frameworks and no
// speech dependency. CI copies this over Package.swift to build and test it on Windows and Linux; the shipping
// Windows app (windows/) runs the same library as larynx-text, a small process that cleans JSON lines.
import PackageDescription

let package = Package(
    name: "LarynxPortable",
    products: [
        .library(name: "LarynxText", targets: ["LarynxText"]),
        .executable(name: "larynx-text", targets: ["larynx-text"]),
    ],
    targets: [
        .target(name: "LarynxText", resources: [.process("Resources")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "LarynxTextJSON", dependencies: ["LarynxText"], path: "windows/swift/LarynxTextJSON",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "larynx-text", dependencies: ["LarynxTextJSON"], path: "windows/swift/larynx-text",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "LarynxTextTests", dependencies: ["LarynxText"], path: "tests/LarynxTextTests",
                    exclude: ["README.md"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
