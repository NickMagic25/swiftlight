# Swiftlight

A native macOS Moonlight client built with SwiftUI, Metal, Core Audio, GameController, and a shared Apple streaming core. Every compressed video frame goes through the separately pinned **MoonlightAppleVideo** package with hardware decoding required. Sunshine and Apollo are the hosts.

macOS is the first application target. iOS, iPadOS and tvOS adapters are future work. The macOS implementation builds and passes server-free hardware validation. Live Vibepollo checks have verified saved pairing, authenticated library access, a short HEVC 10-bit Desktop stream, input capture/release, and local disconnect. A presentation deadlock found during live testing was corrected; see the [stream follow-up](docs/stream-deadlock-validation.md). The [statistics follow-up](docs/stream-statistics-validation.md) verifies the disconnect/statistics shortcuts and movable Liquid Glass panel against a live host. The final full-screen viewport matched the 3440 × 1440 external display; broader display, pairing/input/audio/HDR coverage and sustained performance are **not yet release-validated**. See the [acceptance matrix](docs/acceptance-matrix.md).

## Build and run

Requires macOS14+, Xcode26.6/Swift6.3.3, command-line developer tools, CMake, Perl, Python3, curl and a C/C++ build toolchain. Validated on arm64 macOS26.6.2 using SDK26.5. Internet access is needed for the first bootstrap and SwiftPM resolution.

```sh
git clone --recurse-submodules https://github.com/NickMagic25/swiftlight.git
cd swiftlight
scripts/build-app.sh
open .build/Swiftlight.app
```

`moonlight-common-c` is a Git submodule at `Dependencies/moonlight-common-c`, pinned to `62e066388f1a1b133e0bee947b9a374311a3354b`, including upstream's exact ENet/nanors submodules. Bootstrap initializes missing submodules, verifies their revisions and pristine state, then applies the explicit [patch series](patches/moonlight-common-c/README.md) to an ignored generated source tree compiled by `CStreamBridge`. Upstream source is never edited during a build. See [dependency maintenance](docs/dependencies.md).

Bootstrap also downloads SHA-256-pinned Opus1.5.2/OpenSSL3.6.4 sources and builds static libraries. SwiftPM fetches decoder revision `8d92ee039dc19fe50dc0158d5098d4c5646c6a56`. No Homebrew dynamic library is shipped. The bundle includes dependency notices. Debug builds select the sole available Apple Development or Developer ID Application identity, or accept an explicit `SIGNING_IDENTITY`. With no certificate available they use ad-hoc signing, which can trigger Keychain authorization after rebuilding. Release builds require an explicit real signing identity. See [signing and safe bundle replacement](docs/signing.md); distribution and notarization are separate.

Run `scripts/bootstrap-dependencies.sh` before opening `Package.swift` in Xcode or invoking SwiftPM directly. The bundle script adds the actual application's Info.plist, native privacy/Game Mode declarations, notices and signature. Running the bare SwiftPM executable is not the normal app installation/permission flow.

For work on the sibling decoder package, use an explicit local package override without copying its source:

```sh
SWIFTLIGHT_DECODER_PATH=../moonlight-apple-decoder scripts/build-app.sh
```

The scripts use `--manifest-cache none` so SwiftPM reevaluates the override. Omit the environment variable for the immutable remote dependency. No decoder-package changes were needed for this client.

## First connection

1. Choose **Add Computer**, then enter an address or choose a Bonjour-discovered host. Custom ports and `[IPv6]:port` are supported.
2. Choose **Start PIN Pairing** and enter the displayed PIN in Sunshine/Apollo. Apollo also accepts an `art://` link or separate address/OTP/passphrase fields.
3. Choose stream settings, then an application. If the application is already running, Swiftlight resumes it.
4. Streams start in native full screen by default; disable **Start streams in full screen** in Presentation settings for windowed playback. The first frame captures input when Swiftlight is active; **Control–Option–Shift–Z** releases capture and shows the stream controls. Click the video to capture again.
5. **Disconnect** leaves the remote application running. **Quit Remote Application** is a separate confirmed action.

The library loads real covers from the paired host into a 3:4 grid. Hover or focus a cover to reveal its title and Play/Resume action; unavailable artwork uses a titled fallback. Native controls and floating panels share Liquid Glass on macOS 26 and later, with material and accessibility fallbacks. Artwork stays in a bounded memory-only cache. See [appearance and covers](docs/appearance.md) for behavior, resource limits and the pending live visual checks.

| Shortcut | Action |
| --- | --- |
| Control–Option–Shift–Q | Disconnect locally; leave the remote application running. |
| Control–Option–Shift–S | Show or hide stream statistics while preserving input capture. |
| Control–Option–Shift–Z | Release input capture and show stream controls. |
| Control–Command–F | Toggle native full screen. |

In **Settings → Stream Statistics**, choose **Simple** or **Detailed** and **Top Left**, **Top Center** or **Top Right**. Defaults are **Simple** and **Top Center**. Detail and position save immediately for every computer, persist across launches, and take effect during the current stream without reconnecting. The statistics panel uses an opaque background and is drawn into the video’s existing Metal pass. Its cached text updates independently of video frames, and accessible rows remain available without overlapping visual layers. See the [statistics rendering investigation](docs/statistics-metal-overlay-2026-09-13.md) for implementation and measured limits. See [stream statistics](docs/stream-statistics.md) for measurement definitions and limits.

Relative mouse mode is for games; Absolute mode maps the pointer through the same clean-aperture/fit/fill viewport and rejects letterbox input. Physical controllers support analog controls and available haptics. Stream request changes require reconnect; display movement/resize changes presentation immediately, while a new native pixel request needs reconnect. HDR On fails clearly if unavailable; Auto intersects host codec/10-bit support, hardware decoder candidates and display capability.

Client private keys and certificate pins live in Keychain. The macOS development app explicitly uses the login Keychain; iOS/tvOS core defaults to the data-protection Keychain. There is no fallback after arbitrary credential errors. Apollo one-time secrets are not retained. See [manual pairing tests](docs/host-manual-test.md).

## Export a stream for debugging

Presentation defaults are **On decoded frame**, **VSync off**, and **3 drawable buffers**. Decoded-frame pacing submits the newest available frame without a display-link wait; disabling VSync permits tearing. HDR configuration and layer-placement experiments remain opt-in because they regressed throughput in live comparisons. Existing explicitly saved presentation settings remain in effect. **Frame pacing**, **VSync**, and **Drawable buffers** can be changed in Settings and apply on reconnect. See [latency debugging and measured results](docs/stream-latency-debugging.md) for measurements and remaining presentation variance.

After disconnecting, choose **Stream → Export Last Stream Diagnostics…** or the same action in the library's computer-options menu. Save the JSON file wherever you want. It contains the completed connection attempt's settings, outcome, recent statistics timeline, and decoder/renderer/network/audio counters. Failed connection attempts are included. The last report is retained in memory until replaced by the next completed attempt or Swiftlight quits; export it before closing the app. Pairing credentials, host addresses, application names and media are excluded. See [diagnostic exports](docs/diagnostic-exports.md) for the schema and measurement limits.

Schema 5 separates completed GPU submissions from confirmed display presentations. `completedFrameTimings` remains available when a drawable has no usable presentation timestamp; `presentationTimings` joins completion and confirmed presentation for the same submission. These bounded recent windows distinguish CPU scheduling, GPU execution and the wait after GPU completion. GPU completion is not display latency.

Debug builds save finalized reports locally and expose **Stream → Run Latency Comparison (Short/Full)**. The selected host's Desktop stream is captured at 10, 30 and 50 seconds per case under `~/Library/Application Support/Swiftlight/LatencyExperiments/`. **Cancel Latency Comparison** stops the sequence. Settings are restored afterward and Desktop remains running remotely. Native PQ output is a debug-only comparison: its nonlinear PQ layer uses nil EDR metadata under Apple's API contract, so its highlight handling requires separate validation before adoption.

## Offline validation

```sh
scripts/validate-offline.sh
```

This runs unit/protocol/ownership tests, the native ASan/UBSan harness, independent OTP vectors, real HEVC/AV1 hardware decode and production Metal render/readback for all eight fixture sets, and the sole-decoder audit. It requires an Apple GPU and HEVC/AV1 hardware; a sandbox or unsupported device can block these checks and must not be called a pass. Outputs are written to `artifacts/` and `.build/native-transport-tests/`.

The latest full Swift suite passed 95 tests (70 XCTest and 25 host tests), including hardware readbacks for statistics overlay color/placement/lifetime, artwork protocol/image bounds, statistics preferences, shortcut ownership, presentation policy, Keychain caching and a deterministic regression for the drawable callback deadlock. The integrated macOS debug app built and signed successfully, and the release product compiled. Native ASan, UBSan and TSan checks passed. Ten isolated window-lifecycle groups and nineteen packaging checks also pass. The initial live checks are partial functional evidence; they do not replace the remaining acceptance gates.

```sh
.build/debug/swiftlight-replay --fixture fixtures/av1-accounting-10/manifest.json \
  --mode paced --output artifacts/av1-paced.json
SWIFTLIGHT_SANITIZERS=thread scripts/validate-transport-native.sh
python3 scripts/acceptance-report.py
```

Correctness and paced offscreen modes are distinct. Offscreen GPU completion is never reported as display latency. Short small fixtures are not a 4K60 benchmark. Real display, network and sustained-load methodology is in [benchmarking](docs/benchmarking.md); exact executed evidence and remaining gates are in [implementation report](docs/implementation-report.md).

For a host-free visual check, open **Stream → Video Validation** in the app and choose a fixture manifest. The window uses the production decoder and Metal renderer. Its separate lifecycle regression is `python3 scripts/validate-preview-lifecycle.py`; that automated check opens no window and does not measure visible presentation.

- [Architecture and lifetime](docs/architecture.md)
- [Appearance and application covers](docs/appearance.md)
- [Authenticated host artwork](docs/host-artwork.md)
- [Verified API/protocol assumptions](docs/verified-assumptions.md)
- [Compatibility matrix](docs/compatibility-matrix.md)
- [Video validation](docs/video-validation.md)
- [Transport and audio](docs/transport.md)
- [Licensing and distribution](docs/licensing.md)
