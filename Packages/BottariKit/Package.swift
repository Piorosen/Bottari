// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BottariKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BottariCore", targets: ["BottariCore"]),
        .library(name: "BottariSFTP", targets: ["BottariSFTP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        // Citadel builds on this fork of swift-nio-ssh; depend on the same one to import NIOSSH.
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4" ..< "0.4.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", from: "4.2.2"),
    ],
    targets: [
        .target(name: "BottariCore"),
        .target(
            name: "BottariSFTP",
            dependencies: [
                "BottariCore",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "KeychainAccess", package: "KeychainAccess"),
            ]
        ),
        .testTarget(name: "BottariCoreTests", dependencies: ["BottariCore"]),
        .testTarget(
            name: "BottariSFTPTests",
            dependencies: [
                "BottariCore",
                "BottariSFTP",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
    ]
)
