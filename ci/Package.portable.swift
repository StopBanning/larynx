// swift-tools-version: 6.1
// The portable part of Larynx only: the text cleanup (LarynxText) and its tests, with no Apple frameworks and no
// speech dependency. CI copies this over Package.swift to build and test it on Windows and Linux; the shipping
// Windows app (windows/) loads the same library through LarynxTextC, a small C-callable DLL.
import PackageDescription

let package = Package(
    name: "LarynxPortable",
    products: [
        .library(name: "LarynxText", targets: ["LarynxText"]),
        .library(name: "LarynxTextC", type: .dynamic, targets: ["LarynxTextC"]),
    ],
    targets: [
        .target(name: "LarynxText", resources: [.process("Resources")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "LarynxTextC", dependencies: ["LarynxText"], path: "windows/swift",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "LarynxTextTests", dependencies: ["LarynxText"], path: "tests/LarynxTextTests",
                    exclude: ["README.md"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
