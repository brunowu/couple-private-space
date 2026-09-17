// swift-tools-version: 6.0
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let signalRoot = ".dependencies/src/libsignal-0.102.2"
let package = Package(
    name: "CouplePrivateSpace",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "CoupleUI", targets: ["UI"]),
        .library(name: "CoupleApplication", targets: ["Application"]),
        .library(name: "DevelopmentSupport", targets: ["DevelopmentSupport"]),
        .executable(name: "couple-lab", targets: ["CoupleLab"])
    ],
    targets: [
        .binaryTarget(name: "SignalNative", path: ".dependencies/SignalNative.xcframework"),
        .target(name: "LibSignalClient", dependencies: ["SignalNative"], path: signalRoot + "/swift/Sources/LibSignalClient",
                linkerSettings: [
                    .unsafeFlags(["-L" + root + "/" + signalRoot + "/target/debug"], .when(platforms: [.macOS])),
                    .linkedFramework("Security"), .linkedFramework("CoreFoundation"), .linkedLibrary("c++")
                ]),
        .target(name: "CSQLCipher", path: ".dependencies/CSQLCipher", publicHeadersPath: "include",
                cSettings: [.define("SQLITE_HAS_CODEC"), .define("NDEBUG", to: "1"),
                            .define("SQLITE_EXTRA_INIT", to: "sqlcipher_extra_init"),
                            .define("SQLITE_EXTRA_SHUTDOWN", to: "sqlcipher_extra_shutdown"),
                            .define("SQLCIPHER_CRYPTO_CC"), .define("SQLITE_TEMP_STORE", to: "3"),
                            .define("SQLITE_THREADSAFE", to: "1"), .define("SQLITE_OMIT_LOAD_EXTENSION")],
                linkerSettings: [.linkedFramework("Security"), .linkedFramework("CoreFoundation")]),
        .target(name: "Domain"),
        .target(name: "Crypto", dependencies: ["Domain", "LibSignalClient"]),
        .target(name: "Persistence", dependencies: ["Domain", "CSQLCipher"]),
        .target(name: "Transport", dependencies: ["Domain"]),
        .target(name: "Notification", dependencies: ["Domain"]),
        .target(name: "Sync", dependencies: ["Domain", "Crypto", "Transport", "Notification"]),
        .target(name: "UI", dependencies: ["Domain", "Sync", "Notification"]),
        .target(name: "Application", dependencies: ["Domain", "Crypto", "Persistence", "Transport", "Sync", "Notification", "UI"]),
        .target(name: "DevelopmentSupport", dependencies: ["Domain", "Crypto", "Persistence", "Transport", "Sync", "Notification", "UI"]),
        .executableTarget(name: "CoupleLab", dependencies: ["Domain", "Crypto", "Persistence", "Transport", "Sync"]),
        .testTarget(name: "CoupleCoreTests", dependencies: ["Domain", "Crypto", "Persistence", "Transport", "Sync", "Notification", "DevelopmentSupport", "Application"])
    ],
    swiftLanguageModes: [.v5]
)
