// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BottariKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BottariCore", targets: ["BottariCore"]),
    ],
    targets: [
        .target(name: "BottariCore"),
        .testTarget(name: "BottariCoreTests", dependencies: ["BottariCore"]),
    ]
)
