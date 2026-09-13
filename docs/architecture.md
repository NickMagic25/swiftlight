# Architecture

Swiftlight is a native macOS SwiftUI application built on a shared Apple streaming engine. The first target is macOS 14 or later. The package declares iOS/tvOS 17 engine minima; UIKit/tvOS application adapters are follow-on work and are not shipped or validated in this macOS delivery.

## Boundaries

- `SwiftlightApp`: MainActor host/library/settings/pairing/session orchestration; AppKit Metal surface, native full screen, scoped keyboard/mouse capture, GameController and power activity.
- `SwiftlightCore`: Foundation/CoreGraphics value types for requested settings, host/device capability intersection, safe-area/viewport transforms, session generations and held-input state. No decoder, network socket or UI dependencies.
- `SwiftlightHost`: Bonjour, host HTTP/XML, Keychain identity and certificate pins, standard PIN and Apollo OTP pairing, app control and nonsecret host persistence. Its C crypto helper uses OpenSSL for established GameStream RSA/certificate operations. See `host-protocol.md`.
- `SwiftlightTransport` / `CStreamBridge`: pinned moonlight-common-c transport, pull video ownership, Opus and CoreAudio stereo output, protocol input. No video decoder.
- `SwiftlightVideo`: the sole `MoonlightAppleVideo` adapter, latest decoded-frame mailbox, production CoreVideo/Metal importer/shader, bounded instrumentation and offscreen readback validation.
- `SwiftlightReplay`: same production decoder and renderer, deterministic correctness and explicitly labeled paced offscreen workloads.

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

Geometry explicitly distinguishes display points, window backing pixels and CGDisplayMode pixel dimensions. Safe-area geometry intersects actual window content with NSScreen's safe rectangle. Already-safe native full-screen content therefore receives no second notch subtraction. Requested 4:2:0 dimensions round down to even values. Fit/fill/integer mapping is shared conceptually by rendering and input and unit-tested; physical notched/external display behavior remains a manual gate.

The canonical renderer supports NV12/P010-family video/full range output, signaled color metadata and clean aperture. It produces linear sRGB float output. PQ converts to absolute nits and divides by 203; CAMetalLayer HDR10 EDR metadata declares the corresponding 203-nit optical scale. The OS handles display tone mapping. HLG and packed native/lossless formats are rejected. Canonical output stays the baseline until an explicit package API and native sampling/performance evidence justify promotion.

## Clock domains and diagnostics

Decoder trace times use `CLOCK_UPTIME_RAW` nanoseconds. Common-c timestamps have a private start epoch. Media PTS is separate. Uncalibrated transport timestamps must never be subtracted from decoder time. Metal GPU and actual drawable presentation times use their API clock and must be calibrated before cross-domain latency claims. Display-link deadline, predicted presentation, GPU completion and observed presentation are distinct. Zero actual presentation time is unavailable evidence, not success.

Metrics buffers are bounded. Correctness replay is unpaced; paced replay reports submission-to-offscreen-completion measurements, never physical display latency. Host addresses, pairing URLs, PINs, certificates, private keys and input keys are excluded from exported diagnostics.
