// swift-tools-version:5.9
import PackageDescription

// Local mirror of Sparkle 2.9.4 as a path-based binary target.
//
// The official dependency is `https://github.com/sparkle-project/Sparkle`
// (exact 2.9.4). On networks where SwiftPM cannot fetch the release archive,
// this local package keeps the build working: run `scripts/setup-sparkle.sh`
// once to place the official `Sparkle.xcframework` here, then build as usual.
// `Sparkle.xcframework` itself is not committed; download it with the script.

let package = Package(
    name: "Sparkle",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(name: "Sparkle", targets: ["Sparkle"])
    ],
    targets: [
        .binaryTarget(
            name: "Sparkle",
            path: "Sparkle.xcframework"
        )
    ]
)
