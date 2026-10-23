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
        .library(name: "BottariPlayer", targets: ["BottariPlayer"]),
        .library(name: "BottariRemote", targets: ["BottariRemote"]),
        .library(name: "BottariCloud", targets: ["BottariCloud"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        // Citadel builds on this fork of swift-nio-ssh; depend on the same one to import NIOSSH.
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4" ..< "0.4.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", from: "4.2.2"),
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.3.0"),
        // libmpv with FFmpeg (LGPL build) as prebuilt xcframeworks.
        .package(url: "https://github.com/mpvkit/MPVKit.git", exact: "1.0.0"),
        // 1.12 and later need the separately installed Metal toolchain; 1.19 and later
        // also run a build plugin that Xcode makes you approve first.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", .upToNextMinor(from: "1.11.2")),
        // 1.1.0, pinned by commit: it depends on a CryptoSwift branch, which a version requirement refuses.
        .package(url: "https://github.com/royalapplications/royalvnc.git", revision: "8e9d3bb9cd041266df0659651f646fef251b4c71"),
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
        .target(name: "BottariPlayer", dependencies: ["BottariCore", .product(name: "MPVKit", package: "MPVKit")]),
        .target(name: "BottariCloud", dependencies: ["BottariCore", .product(name: "Crypto", package: "swift-crypto")]),
        .testTarget(name: "BottariCloudTests", dependencies: ["BottariCore", "BottariCloud"]),
        .target(name: "BottariRemote", dependencies: [
            .product(name: "SwiftTerm", package: "SwiftTerm"),
            .product(name: "RoyalVNCKit", package: "royalvnc"),
        ]),
        .testTarget(name: "BottariCoreTests", dependencies: ["BottariCore"]),
        .testTarget(name: "BottariTransferTests", dependencies: ["BottariCore", "BottariTransfer"]),
        .testTarget(name: "BottariEditorTests", dependencies: ["BottariEditor"]),
        .testTarget(name: "BottariPlayerTests", dependencies: ["BottariCore", "BottariPlayer"]),
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
