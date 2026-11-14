// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Titan",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "titan", targets: ["titan"]),
        .library(name: "TitanCore", targets: ["TitanCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "TitanCore"),
        .executableTarget(
            name: "titan",
            dependencies: [
                "TitanCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "TitanCoreTests", dependencies: ["TitanCore"]),
    ]
)
