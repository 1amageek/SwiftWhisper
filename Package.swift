// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftWhisper",
    platforms: [.iOS(.v17),.macOS(.v14)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "SwiftWhisper",
            targets: ["SwiftWhisper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", branch: "main")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "SwiftWhisper",
            dependencies: [
                "WhisperKit"
            ]
        ),
        .testTarget(
            name: "SwiftWhisperTests",
            dependencies: ["SwiftWhisper"]
        ),
    ]
)
