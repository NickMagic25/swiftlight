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
let nativeMobileInclude = root + "/.build/dependencies/mobile/include"
let nativeIncludes: [CSetting] = [
    .unsafeFlags(["-I", nativeInclude], .when(platforms: [.macOS])),
    .unsafeFlags(["-I", nativeMobileInclude], .when(platforms: [.iOS]))
]
// Xcode's multiplatform app target supplies SDK-specific LIBRARY_SEARCH_PATHS for device
// versus simulator. SwiftPM platform conditions cannot distinguish those SDKs.
let nativeLibrarySearch: [LinkerSetting] = [
    .unsafeFlags(["-L", nativeLibrary], .when(platforms: [.macOS]))
]
let package = Package(
    name: "Swiftlight",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17)],
    products: [
        .library(name: "SwiftlightCore", targets: ["SwiftlightCore"]),
        // The primary Xcode app project consumes these shared modules as local-package products.
        // Keep SwiftPM support for module tests, replay tooling, and the secondary app packager.
        .library(name: "SwiftlightHost", targets: ["SwiftlightHost"]),
        .library(name: "SwiftlightTransport", targets: ["SwiftlightTransport"]),
        .library(name: "SwiftlightVideo", targets: ["SwiftlightVideo"]),
        // Keep the secondary packager's executable distinct from the Xcode app
        // target, so UI-test host lookup resolves Swiftlight.app unambiguously.
        .executable(name: "swiftlight-desktop", targets: ["SwiftlightApp"]),
        .executable(name: "swiftlight-replay", targets: ["SwiftlightReplay"])
    ],
    dependencies: [decoder],
    targets: [
        .target(name: "SwiftlightCore", path: "Sources/shared/SwiftlightCore"),
        .target(name: "CHostCrypto", path: "Sources/shared/CHostCrypto", publicHeadersPath: "include",
                cSettings: nativeIncludes,
                linkerSettings: nativeLibrarySearch + [.linkedLibrary("crypto")]),
        .target(name: "SwiftlightHost", dependencies: ["CHostCrypto"], path: "Sources/shared/SwiftlightHost"),
        // bootstrap-dependencies.sh prepares these sources from the pinned common-c submodule
        // and the explicit patch series. The upstream checkout remains pristine.
        .target(name: "CStreamBridge", path: "Sources/shared/CStreamBridge", sources: ["StreamBridge.c", "AudioOutput.c", "AudioRing.c", "AudioFormat.c", "AudioSpatialOutput.m", "vendor/common-c/src",
                "vendor/common-c/enet/callbacks.c", "vendor/common-c/enet/compress.c", "vendor/common-c/enet/host.c",
                "vendor/common-c/enet/list.c", "vendor/common-c/enet/packet.c", "vendor/common-c/enet/peer.c",
                "vendor/common-c/enet/protocol.c", "vendor/common-c/enet/unix.c", "vendor/common-c/nanors/rs.c",
                "vendor/common-c/nanors/deps/obl/oblas_common.c", "vendor/common-c/nanors/deps/obl/oblas_lite.c"],
                publicHeadersPath: "include", cSettings: nativeIncludes + [
                    // The native audio wrapper explicitly owns its Objective-C objects and dispatch sources.
                    .unsafeFlags(["-fblocks", "-fno-objc-arc"]), .headerSearchPath("vendor/common-c/src"), .headerSearchPath("vendor/common-c/enet/include"),
                    .headerSearchPath("vendor/common-c/nanors"), .headerSearchPath("vendor/common-c/nanors/deps"),
                    .headerSearchPath("vendor/common-c/nanors/deps/obl"),
                    .define("__APPLE_USE_RFC_3542"), .define("HAS_SOCKLEN_T"), .define("HAS_FCNTL"), .define("HAS_POLL"), .define("HAS_GETADDRINFO"),
                    .define("HAS_GETNAMEINFO"), .define("HAS_INET_PTON"), .define("HAS_INET_NTOP"),
                    .define("HAS_MSGHDR_FLAGS"), .define("NDEBUG")
                ], linkerSettings: nativeLibrarySearch + [.linkedLibrary("crypto"), .linkedLibrary("opus"),
                    .linkedFramework("AudioToolbox"), .linkedFramework("CoreAudio"), .linkedFramework("CoreMedia"),
                    .linkedFramework("AVFoundation")]),
        .target(name: "SwiftlightTransport", dependencies: ["CStreamBridge", "SwiftlightCore"], path: "Sources/shared/SwiftlightTransport"),
        .target(name: "SwiftlightVideo", dependencies: [.product(name: "MoonlightAppleVideo", package: "moonlight-apple-decoder")], path: "Sources/shared/SwiftlightVideo"),
        .executableTarget(name: "SwiftlightApp", dependencies: ["SwiftlightCore", "SwiftlightVideo", "SwiftlightHost", "SwiftlightTransport"],
            path: "Sources",
            exclude: ["mobile", "tv", "shared/SwiftlightCore", "shared/SwiftlightHost", "shared/CHostCrypto",
                      "shared/SwiftlightTransport", "shared/CStreamBridge", "shared/SwiftlightVideo", "shared/SwiftlightReplay"],
            sources: ["desktop", "shared/SwiftlightApp"]),
        .executableTarget(name: "SwiftlightReplay", dependencies: ["SwiftlightVideo", .product(name: "MoonlightAppleVideo", package: "moonlight-apple-decoder")], path: "Sources/shared/SwiftlightReplay"),
        .testTarget(name: "SwiftlightHostTests", dependencies: ["SwiftlightHost"]),
        .testTarget(name: "SwiftlightAppTests", dependencies: ["SwiftlightApp"]),
        .testTarget(name: "SwiftlightTransportTests", dependencies: ["SwiftlightTransport", "CStreamBridge"]),
        .testTarget(name: "SwiftlightCoreTests", dependencies: ["SwiftlightCore"]),
        .testTarget(name: "SwiftlightVideoTests", dependencies: ["SwiftlightVideo"])
    ],
    swiftLanguageModes: [.v6]
)
