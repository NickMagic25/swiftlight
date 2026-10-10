# Swiftlight

Swiftlight is a native Apple client for Moonlight game streaming, with a macOS app and developing iPhone and iPad MVPs. It connects to Sunshine and Apollo hosts, uses Apple hardware video decoding, and presents games through SwiftUI and Metal. The [iPhone and iPad guide](docs/mobile.md) describes the mobile feature set and its validation limits.

## What you can do on Mac

- Pair with a Sunshine or Apollo computer and browse its applications with cover artwork.
- Stream in native full screen or in a resizable window.
- Choose HEVC, AV1 or explicit [PyroWave](docs/pyrowave.md) when the host and device support the selected profile, with HDR available when the complete host, decoder and display path support it.
- Use keyboard, mouse, and physical controllers, including relative and absolute mouse modes.
- Choose Stereo, 5.1, or 7.1 audio, with Direct output or System Spatial Audio on compatible AirPods.
- View optional stream statistics and export the last completed stream's privacy-filtered diagnostics.

The same `Swiftlight` Xcode app target supports iPhone and iPad destinations on iOS and iPadOS 26 or later, with adaptive navigation, discovery, PIN pairing, cover-art browsing, and full-screen streaming with performance, HDR, and surround/spatial audio settings. tvOS remains future work. Swiftlight is still under active development; see the [mobile guide](docs/mobile.md), [compatibility guide](docs/compatibility-matrix.md), and [acceptance status](docs/dev/acceptance-matrix.md) for validation boundaries.

## Requirements

- macOS 14 or later (validated on arm64 macOS 26.6.2).
- A Sunshine or Apollo host on the same network or an accessible network path.
- A Mac with hardware support for the codec and HDR mode you select.
- Xcode 26.6 / Swift 6.3.3, CMake, Perl, Python 3, curl, and a C/C++ toolchain to build from source.

## Build and launch

Use the **Xcode project** to build, run and debug the macOS app:

```sh
git clone --recurse-submodules https://github.com/NickMagic25/swiftlight.git
cd swiftlight
scripts/bootstrap-dependencies.sh
open Swiftlight.xcodeproj
```

In Xcode, select the **Swiftlight** scheme and **My Mac** destination, choose your development team under the app target's **Signing & Capabilities**, then use **Product → Run**. The current project builds for Apple silicon.

Bootstrap downloads and builds pinned native dependencies on its first run, so internet access is required. Run it again when native dependency inputs change; local Xcode builds do not run it automatically. See [development documentation](docs/dev/README.md) for the terminal `xcodebuild` recipe, signing and verification. `Package.swift` supplies the shared modules and test/replay tooling used by the app.

For iPhone or iPad, prepare dependencies with `scripts/bootstrap-dependencies.sh --platform ios-simulator` for Simulator or `--platform ios` for devices, then keep the **Swiftlight** scheme and select the intended iPhone or iPad destination. See the [mobile guide](docs/mobile.md) for build, input, and platform details.

There is one app target, one scheme and one SwiftUI app entry point. `Sources/` has four folders: `shared` for common features and engine modules, `desktop` for Mac adapters, `mobile` for iPhone/iPad adapters, and `tv` reserved for future TV integration. The target automatically includes the shared app folder and both implemented platform folders; native code uses conditional compilation. Every destination produces `Swiftlight.app`. See the [architecture guide](docs/dev/architecture.md).

The reusable **MoonlightAppleVideo** decoder is maintained in [`Packages/moonlight-apple-decoder/`](Packages/moonlight-apple-decoder/README.md) in this repository. SwiftPM and Xcode use that local package. Its standalone CMake builds, tests, fixture tools and documentation remain alongside the decoder source.

## Connect from your Mac

1. Select **Add Computer** and enter the host address, or choose a Bonjour-discovered host. Custom ports and IPv6 addresses are supported.
2. Select **Start PIN Pairing**, then enter the PIN in Sunshine or Apollo. Apollo also supports its one-time `art://` pairing link.
3. Choose stream settings and select an application. If it is already running, Swiftlight offers to resume it.
4. Start the stream. Streams default to native full screen; turn off **Start streams in full screen** in Presentation settings for windowed playback.

During a stream, **Control–Option–Shift–Z** releases input capture and shows the stream controls; click the video to capture input again. **Control–Option–Shift–Q** disconnects while leaving the remote application running. **Control–Command–F** toggles native full screen.

Before streaming, a connected controller can browse computers and games. Use the D-pad or left stick to move the highlighted selection, **A** to select or play, **B** to return or cancel, and **Menu** to open Settings. Controller input never confirms a remote quit or application switch. Address entry, pairing, and editing settings still use the platform's ordinary controls.

During streaming, delivered **Home/Guide** presses go to the host while game input is active. On iOS/iPadOS 26, double-press the controller's Home/logo button for the system passthrough path; a single press can open Apple's Game Overlay. macOS uses the same host mapping, and newer system controller settings may allow a single press. The operating system controls which events reach Swiftlight. See the [controller routing notes](docs/dev/mobile-controller-presentation.md#homeguide-passthrough) for platform limits and physical-device checks.

See the [pairing and host guide](docs/host-protocol.md) for connection behavior and [appearance and library guide](docs/appearance.md) for artwork and accessibility behavior.

## Configure streaming

Stream settings apply when the next connection starts. Presentation settings—frame pacing, VSync, and drawable buffers—can be changed in Settings and apply on reconnect. HDR **Auto** selects a compatible mode; HDR **On** reports an incompatibility instead of silently falling back when the full path is unavailable.

HEVC and AV1 HDR retain the host's mastering-display and content-light metadata when it is absent from the encoded video. In **Settings → Video → HDR tone mapping**, choose **Linear** or **PQ**; PQ is the default and changes apply on reconnect. Older settings with no selection or the former System tone mapping selection migrate to PQ, while existing Linear and PQ selections are retained. The renderer configures the output before acquiring a drawable. HDR brightness and shadow visibility still require validation on the destination display.

In **Settings → Video → Chroma sampling**, choose **4:4:4 (sharper text)** to retain full color detail. The default remains **4:2:0**. HEVC and AV1 require matching host encoding and a successful hardware check for the exact 8-bit or 10-bit 4:4:4 profile; **Automatic** chooses a compatible codec. An unavailable explicitly requested mode reports an error. 4:4:4 uses more bandwidth, and changes apply on the next connection. See the [compatibility guide](docs/compatibility-matrix.md) for device validation.

In **Settings → Stream Statistics**, choose **Simple** or **Detailed** and a panel position. **Control–Option–Shift–S** toggles the panel without releasing input capture. The [statistics guide](docs/stream-statistics.md) explains each value and its limitations.

In **Settings → Audio**, choose the host channel layout and local output mode, then save it for the current computer or as a global default. Reconnect after changing audio settings. For AirPods spatialization, request 5.1 or 7.1 from the host, select **System Spatial Audio**, and use the macOS AirPods menu for Off, Fixed, or Head Tracked when available. See the [audio guide](docs/audio.md).

**Settings → About** shows the app version and build number on Mac, iPhone and iPad. Cloud and packaged builds also show a short commit hash when available, such as `0.2.0 (42, a1b2c3d)`, to identify the source revision.

## Troubleshooting

- If a host is not discovered, use **Add Computer** with its address and confirm that Sunshine/Apollo is reachable and pairing is enabled.
- If pairing fails after rebuilding, allow the development app to access its login Keychain and pair again if the stored identity was removed.
- If HDR or AV1 is unavailable, use **Auto** or select HEVC/SDR; support depends on the Mac, host, codec, and display together.
- If audio is silent after changing output devices, reconnect the stream and confirm macOS has selected the intended output device.
- To provide useful diagnostics, disconnect and choose **Stream → Export Last Stream Diagnostics…** before quitting Swiftlight. The export excludes credentials, host addresses, application names, and media. See [diagnostic exports](docs/diagnostic-exports.md).

## Development

Tagged versions use the [macOS release pipeline](docs/dev/releases.md) to run automated checks, sign and notarize Swiftlight, and publish an Apple silicon DMG on GitHub Releases. Version numbers derive from tags, beginning with `v0.0.1`.

Run the offline checks with:

```sh
scripts/validate-offline.sh
```

Engineering notes, validation records, benchmark methodology, dependency maintenance, and release signing instructions are collected in [`docs/dev/`](docs/dev/README.md). HEVC and AV1 use the local **MoonlightAppleVideo** package. PyroWave uses the pinned fork submodule directly through its native Metal decoder, with retained GPU planes shared by the renderer. There is no FFmpeg or software fallback.

## License

See [dependency licensing and distribution](docs/licensing.md).
