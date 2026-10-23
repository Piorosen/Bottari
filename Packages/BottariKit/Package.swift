// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BottariKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BottariCore", targets: ["BottariCore"]),
        .library(name: "BottariSFTP", targets: ["BottariSFTP"]),
        .library(name: "BottariTransfer", targets: ["BottariTransfer"]),
        .library(name: "BottariEditor", targets: ["BottariEditor"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        // Citadel builds on this fork of swift-nio-ssh; depend on the same one to import NIOSSH.
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4" ..< "0.4.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", from: "4.2.2"),
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.3.0"),
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
        .target(name: "BottariTransfer", dependencies: ["BottariCore"]),
        .target(name: "BottariEditor", dependencies: [.product(name: "Highlightr", package: "Highlightr")]),
        .testTarget(name: "BottariCoreTests", dependencies: ["BottariCore"]),
        .testTarget(name: "BottariTransferTests", dependencies: ["BottariCore", "BottariTransfer"]),
        .testTarget(name: "BottariEditorTests", dependencies: ["BottariEditor"]),
        .testTarget(
            name: "BottariSFTPTests",
            dependencies: [
                "BottariCore",
                "BottariSFTP",
                "BottariTransfer",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
    ]
)
