# Swiftlight

Swiftlight is a native Apple client for Moonlight game streaming, with a macOS app and developing iPhone and iPad MVPs. It connects to Sunshine and Apollo hosts, uses Apple hardware video decoding, and presents games through SwiftUI and Metal. The [iPhone and iPad guide](docs/mobile.md) describes the mobile feature set and its validation limits.

## What you can do on Mac

- Pair with a Sunshine or Apollo computer and browse its applications with cover artwork.
- Stream in native full screen or in a resizable window.
- Choose HEVC or AV1 when the host and Mac support it, with HDR available when the complete host, decoder, and display path supports HDR.
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

## Connect from your Mac

1. Select **Add Computer** and enter the host address, or choose a Bonjour-discovered host. Custom ports and IPv6 addresses are supported.
2. Select **Start PIN Pairing**, then enter the PIN in Sunshine or Apollo. Apollo also supports its one-time `art://` pairing link.
3. Choose stream settings and select an application. If it is already running, Swiftlight offers to resume it.
4. Start the stream. Streams default to native full screen; turn off **Start streams in full screen** in Presentation settings for windowed playback.

During a stream, **Control–Option–Shift–Z** releases input capture and shows the stream controls; click the video to capture input again. **Control–Option–Shift–Q** disconnects while leaving the remote application running. **Control–Command–F** toggles native full screen.

See the [pairing and host guide](docs/host-protocol.md) for connection behavior and [appearance and library guide](docs/appearance.md) for artwork and accessibility behavior.

## Configure streaming

Stream settings apply when the next connection starts. Presentation settings—frame pacing, VSync, and drawable buffers—can be changed in Settings and apply on reconnect. HDR **Auto** selects a compatible mode; HDR **On** reports an incompatibility instead of silently falling back when the full path is unavailable.

In **Settings → Stream Statistics**, choose **Simple** or **Detailed** and a panel position. **Control–Option–Shift–S** toggles the panel without releasing input capture. The [statistics guide](docs/stream-statistics.md) explains each value and its limitations.

In **Settings → Audio**, choose the host channel layout and local output mode, then save it for the current computer or as a global default. Reconnect after changing audio settings. For AirPods spatialization, request 5.1 or 7.1 from the host, select **System Spatial Audio**, and use the macOS AirPods menu for Off, Fixed, or Head Tracked when available. See the [audio guide](docs/audio.md).

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

Engineering notes, validation records, benchmark methodology, dependency maintenance, and release signing instructions are collected in [`docs/dev/`](docs/dev/README.md). The project keeps the reusable Apple decoder in the pinned **MoonlightAppleVideo** package; it does not use FFmpeg or a software fallback.

## License

See [dependency licensing and distribution](docs/licensing.md).
