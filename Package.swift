// swift-tools-version: 6.0

import PackageDescription
import Foundation

// Regression suites stay local; public checkouts build without their directories.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let localTestTargets: [Target] = ["DogSCApp", "RecorderCore"].compactMap { module in
    let name = "\(module)Tests"
    let path = "Tests/\(name)"
    guard FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent(path).path) else {
        return nil
    }
    return .testTarget(name: name, dependencies: [.byName(name: module)], path: path)
}

let package = Package(
    name: "DogSC",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RecorderCore", targets: ["RecorderCore"]),
        .executable(name: "DogSC", targets: ["DogSCApp"]),
        .executable(name: "dogsc-mcp", targets: ["DogSCMCP"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.4"
        ),
    ],
    targets: [
        .target(
            name: "RecorderCore",
            path: "Sources/RecorderCore"
        ),
        .executableTarget(
            name: "DogSCApp",
            dependencies: [
                "RecorderCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/DogSCApp",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker",
                    "-rpath",
                    "-Xlinker",
                    "@executable_path/../Frameworks",
                ]),
            ]
        ),
        .executableTarget(
            name: "DogSCMCP",
            path: "Sources/DogSCMCP",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ] + localTestTargets,
    swiftLanguageModes: [.v6]
)
