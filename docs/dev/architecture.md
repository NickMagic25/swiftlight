# Architecture

Swiftlight has one `Swiftlight` Xcode app target, one shared `Swiftlight` scheme and one SwiftUI app entry point. The selected destination chooses native Mac, iPhone or iPad integration. The target supports macOS 14 or later and iOS/iPadOS 26 or later; tvOS has no application adapter yet. Package platform declarations establish shared-engine minima, while the app target defines supported runnable destinations. See the [mobile guide](../mobile.md) for the implemented surface and validation limits.

`Swiftlight.xcodeproj` owns the primary app build, run and archive workflow through the `Swiftlight` scheme. Its app target automatically compiles three synchronized folders: `Sources/shared/SwiftlightApp/`, `Sources/desktop/` and `Sources/mobile/`. Adding a source within them needs no per-file project entry; native files require platform guards. Other shared libraries are consumed through the local `Package.swift`, not compiled again as app sources. SwiftPM's secondary Mac executable product, `swiftlight-desktop` (module `SwiftlightApp`), includes only `desktop` and `shared/SwiftlightApp` from `Sources`; its separate targets provide the engine modules, tests and replay tools. See the [build guide](README.md#build-and-run-the-app-with-xcode).

Each destination produces `Swiftlight.app`. SDK-conditional settings retain the established platform bundle identifiers and plists: `net.edrisil.swiftlight` with `App/Info.plist` for Mac, and `net.edrisil.swiftlight.ios` with `App/Mobile-Info.plist` for iPhone/iPad. Native library paths, signing, resources and deployment minima also follow the destination SDK. `SwiftlightUITests` is the iPhone/iPad UI test target, not an additional app target.

`Sources/shared/SwiftlightApp/SwiftlightApp.swift` contains the single `@main` app. Narrow `#if os(macOS)` and `#if os(iOS)` branches select scenes, native imports and platform-only controls. Shared settings sections, stream-request/codec/HDR preparation, remote-action messages, statistics sampling, artwork and streaming ownership have one implementation. Version availability and actual display/audio capabilities remain independent checks: compiling an API for a platform does not establish device support.

The Mac and mobile coordinators still own their native lifecycle, navigation and persistence flows. Settings save per host or globally on Mac and use a staged Save/Cancel sheet on mobile; both consume the same controls. New common features belong in `Sources/shared/SwiftlightApp/` or the appropriate shared package module. Features that need new native integration still require a platform adapter and platform validation.

## Boundaries

`Sources/` contains exactly `shared`, `desktop`, `mobile` and `tv`.

- `Sources/shared/SwiftlightApp/`: shared app entry point, settings sections, connection preparation, remote-action presentation and host-control failure policy, statistics sampling/rasterization, `StreamingPipeline`, `ControllerHub`, `AppLibraryGrid`, `AppArtworkStore`, and `GlassStyle`.
- `Sources/desktop/`: MainActor Mac coordination; AppKit Metal surface, native full screen, scoped keyboard/mouse capture and power activity. Native files use macOS guards.
- `Sources/mobile/`: MainActor discovery, saved-host selection, PIN pairing, staged settings, and generation-checked session coordination. SwiftUI owns adaptive navigation and sheets; narrow UIKit adapters supply window geometry, Metal presentation, touch input, audio-session routing and stream accessibility. Native files use iOS guards.
- `Sources/tv/`: reserved for a future tvOS adapter. Its documentation has no app-target membership; no TV client is implemented.
- `Sources/shared/SwiftlightCore/`: Foundation/CoreGraphics value types for requested settings, host/device capability intersection, safe-area/viewport transforms, session generations and held-input state. No decoder, network socket or UI dependencies.
- `Sources/shared/SwiftlightHost/` and `Sources/shared/CHostCrypto/`: Bonjour, host HTTP/XML, Keychain identity and certificate pins, standard PIN and Apollo OTP pairing, app control and nonsecret host persistence. The C bridge uses OpenSSL for established GameStream RSA/certificate operations. See [host protocol details](host-protocol-details.md).
- `Sources/shared/SwiftlightTransport/` and `Sources/shared/CStreamBridge/`: pinned moonlight-common-c transport, pull video ownership, Opus, Direct and System Spatial Audio output, and protocol input. Native audio adapters preserve platform-specific route handling. No video decoder.
- `Sources/shared/SwiftlightVideo/`: the sole `MoonlightAppleVideo` adapter, latest decoded-frame mailbox, production CoreVideo/Metal importer/shader, bounded instrumentation and offscreen readback validation.
- `Sources/shared/SwiftlightReplay/`: same production decoder and renderer, deterministic correctness and explicitly labeled paced offscreen workloads.

## Work, bounds and ownership

SwiftUI never observes individual frames. A 250 ms timer samples state and diagnostics. Host control uses structured async calls. Common-c owns receive/assembly/FEC/control threads. A dedicated pull worker borrows each completed frame, bounds and copies the complete AU, and calls the Swift adapter synchronously. The handle is completed exactly once after the decoder has acquired the bytes or an explicit recovery rejection. See transport documentation for the deterministic ownership harness.

The adapter owns a serial decoder queue. All submit/wait/drain/reset/destroy calls execute there, away from main, audio, and packet receive threads. Callbacks may execute inline and only retain the borrowed buffer into a lock-protected mailbox and record bounded metrics. They never call decoder control. Accepted input owes one terminal completion; synchronous rejection owes none.

The decoder admits two unresolved AUs. Compressed frames are not handled as a latest-frame queue. A WOULD_BLOCK waits on the package's capacity event; a configuration-related repeat drains and retries the same AU. Failure requests a keyframe or stops the session with a visible compatibility message. The decoded handoff holds one latest frame, replacing obsolete presentation work. The GPU admits at most three command buffers. Each GPU lease retains the CVPixelBuffer and both CVMetalTexture wrappers through completion. Destroying the decoder does not release a still-referenced buffer.

The audio ring uses a single producer/single consumer atomic boundary, with a fixed capacity and an underrun-to-silence policy. The real-time callback allocates nothing, takes no blocking lock, and performs no network calls. Opus decode occurs on the transport audio worker. Audio output route changes and real A/V timing need physical validation.

`CAMetalDisplayLink` runs on the main run loop and supplies its drawable. The surface does no decode and does not obtain a second drawable. Encoding is bounded and command buffers complete asynchronously. No frame calls `waitUntilCompleted`. Main-run-loop pacing must still be profiled under UI load before claiming minimum latency.

## State and teardown

`SessionState` has idle, ready, connecting, negotiating, streaming, reconfiguring, suspending, disconnecting and failed phases. Connect captures a monotonically increasing identity. Cancellation, failure, suspension and reconfiguration retire it before teardown. Late old callbacks cannot revive streaming. Transport instances also serialize global common-c ownership.

Teardown closes video admission, releases all held input, interrupts pending connection setup, joins common-c API users and its pull worker, then destroys the decoder. The renderer retains GPU leases until completion. A reconnect waits for teardown. Disconnect never calls the remote quit endpoint. Only the separately labeled, confirmed Quit Remote Application action does so.

Sleep suspends streaming and offers a deliberate Resume action after wake. Network loss releases input and stops the connection; no socket migration is promised. Settings changes are saved and applied by controlled reconnect. Display changes update presentation geometry; native request changes require reconnect, avoiding restart storms during resize.

## Coordinates and color

Shared geometry distinguishes display points, window backing pixels and native display pixels. The Mac adapter reads CGDisplayMode dimensions and intersects actual window content with NSScreen's safe rectangle. The mobile adapter reads the owning UIWindow/UIScreen, accounts for orientation, and converts its safe-area layout frame into screen coordinates. Already-safe content receives no second safe-area subtraction. Requested 4:2:0 dimensions round down to even values. Fit/fill/integer mapping is shared by rendering and input and unit-tested; physical notched/external display behavior remains a manual gate.

The canonical renderer supports NV12/P010-family video/full range output, signaled color metadata and clean aperture. It produces linear sRGB float output. PQ converts to absolute nits and divides by 203; CAMetalLayer HDR10 EDR metadata declares the corresponding 203-nit optical scale. The OS handles display tone mapping. HLG and packed native/lossless formats are rejected. Canonical output stays the baseline until an explicit package API and native sampling/performance evidence justify promotion.

## Clock domains and diagnostics

Decoder trace times use `CLOCK_UPTIME_RAW` nanoseconds. Common-c timestamps have a private start epoch. Media PTS is separate. Uncalibrated transport timestamps must never be subtracted from decoder time. Metal GPU and actual drawable presentation times use their API clock and must be calibrated before cross-domain latency claims. Display-link deadline, predicted presentation, GPU completion and observed presentation are distinct. Zero actual presentation time is unavailable evidence, not success.

Metrics buffers are bounded. Correctness replay is unpaced; paced replay reports submission-to-offscreen-completion measurements, never physical display latency. Host addresses, pairing URLs, PINs, certificates, private keys and input keys are excluded from exported diagnostics.
