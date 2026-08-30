// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DogSC",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RecorderCore", targets: ["RecorderCore"]),
        .executable(name: "DogSC", targets: ["DogSCApp"]),
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
    ],
    swiftLanguageModes: [.v6]
)
