// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DogSC",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RecorderCore", targets: ["RecorderCore"]),
        .executable(name: "DogSC", targets: ["DogSCApp"]),
    ],
    targets: [
        .target(
            name: "RecorderCore",
            path: "Sources/RecorderCore"
        ),
        .executableTarget(
            name: "DogSCApp",
            dependencies: ["RecorderCore"],
            path: "Sources/DogSCApp"
        ),
    ],
    swiftLanguageModes: [.v5]
)
