// swift-tools-version: 6.3
import PackageDescription
import Foundation

// A local override keeps package development separate; release builds use the immutable revision.
let localDecoder = ProcessInfo.processInfo.environment["SWIFTLIGHT_DECODER_PATH"]
let decoder: Package.Dependency = localDecoder.map { .package(path: $0) } ??
    .package(url: "https://github.com/NickMagic25/moonlight-apple-decoder.git", revision: "8d92ee039dc19fe50dc0158d5098d4c5646c6a56")
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let nativeInclude = root + "/.build/dependencies/include"
let nativeLibrary = root + "/.build/dependencies/lib"
let package = Package(
    name: "Swiftlight",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17)],
    products: [
        .library(name: "SwiftlightCore", targets: ["SwiftlightCore"]),
        // The Xcode app project consumes these modules as local-package products.
        // Keep the command-line SwiftPM build as the source of truth for them too.
        .library(name: "SwiftlightHost", targets: ["SwiftlightHost"]),
        .library(name: "SwiftlightTransport", targets: ["SwiftlightTransport"]),
        .library(name: "SwiftlightVideo", targets: ["SwiftlightVideo"]),
        .executable(name: "Swiftlight", targets: ["SwiftlightApp"]),
        .executable(name: "swiftlight-replay", targets: ["SwiftlightReplay"])
    ],
    dependencies: [decoder],
    targets: [
        .target(name: "SwiftlightCore"),
        .target(name: "CHostCrypto", publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-I", nativeInclude])],
                linkerSettings: [.unsafeFlags(["-L", nativeLibrary]), .linkedLibrary("crypto")]),
        .target(name: "SwiftlightHost", dependencies: ["CHostCrypto"]),
        // bootstrap-dependencies.sh prepares these sources from the pinned common-c submodule
        // and the explicit patch series. The upstream checkout remains pristine.
        .target(name: "CStreamBridge", sources: ["StreamBridge.c", "AudioOutput.c", "AudioRing.c", "AudioFormat.c", "AudioSpatialOutput.m", "vendor/common-c/src",
                "vendor/common-c/enet/callbacks.c", "vendor/common-c/enet/compress.c", "vendor/common-c/enet/host.c",
                "vendor/common-c/enet/list.c", "vendor/common-c/enet/packet.c", "vendor/common-c/enet/peer.c",
                "vendor/common-c/enet/protocol.c", "vendor/common-c/enet/unix.c", "vendor/common-c/nanors/rs.c",
                "vendor/common-c/nanors/deps/obl/oblas_common.c", "vendor/common-c/nanors/deps/obl/oblas_lite.c"],
                publicHeadersPath: "include", cSettings: [
                    // The native audio wrapper explicitly owns its Objective-C objects and dispatch sources.
                    .unsafeFlags(["-fblocks", "-fno-objc-arc"]), .headerSearchPath("vendor/common-c/src"), .headerSearchPath("vendor/common-c/enet/include"),
                    .headerSearchPath("vendor/common-c/nanors"), .headerSearchPath("vendor/common-c/nanors/deps"),
                    .headerSearchPath("vendor/common-c/nanors/deps/obl"), .unsafeFlags(["-I", nativeInclude]),
                    .define("__APPLE_USE_RFC_3542"), .define("HAS_SOCKLEN_T"), .define("HAS_FCNTL"), .define("HAS_POLL"), .define("HAS_GETADDRINFO"),
                    .define("HAS_GETNAMEINFO"), .define("HAS_INET_PTON"), .define("HAS_INET_NTOP"),
                    .define("HAS_MSGHDR_FLAGS"), .define("NDEBUG")
                ], linkerSettings: [.unsafeFlags(["-L", nativeLibrary]), .linkedLibrary("crypto"), .linkedLibrary("opus"),
                    .linkedFramework("AudioToolbox"), .linkedFramework("CoreAudio"), .linkedFramework("CoreMedia"),
                    .linkedFramework("AVFoundation")]),
        .target(name: "SwiftlightTransport", dependencies: ["CStreamBridge", "SwiftlightCore"]),
        .target(name: "SwiftlightVideo", dependencies: [.product(name: "MoonlightAppleVideo", package: "moonlight-apple-decoder")]),
        .executableTarget(name: "SwiftlightApp", dependencies: ["SwiftlightCore", "SwiftlightVideo", "SwiftlightHost", "SwiftlightTransport"]),
        .executableTarget(name: "SwiftlightReplay", dependencies: ["SwiftlightVideo", .product(name: "MoonlightAppleVideo", package: "moonlight-apple-decoder")]),
        .testTarget(name: "SwiftlightHostTests", dependencies: ["SwiftlightHost"]),
        .testTarget(name: "SwiftlightAppTests", dependencies: ["SwiftlightApp"]),
        .testTarget(name: "SwiftlightTransportTests", dependencies: ["SwiftlightTransport", "CStreamBridge"]),
        .testTarget(name: "SwiftlightCoreTests", dependencies: ["SwiftlightCore"]),
        .testTarget(name: "SwiftlightVideoTests", dependencies: ["SwiftlightVideo"])
    ],
    swiftLanguageModes: [.v6]
)
