# PyroWave streaming

PyroWave is an intra-frame GPU wavelet codec supported by compatible Vibepollo hosts. It uses substantially more bandwidth than HEVC or AV1 and is intended for a fast wired LAN. Swiftlight uses the PyroWave implementation in its `MoonlightAppleVideo` decoder package and the shared Metal rendering path on Mac, iPhone and iPad. Device availability is checked before connecting; physical-device streaming and performance still require their own validation.

## Choose PyroWave

1. Pair with a Vibepollo host that advertises PyroWave support.
2. Open **Settings → Video → Codec** and choose **PyroWave (wired LAN)**. Automatic continues to select HEVC or AV1.
3. Choose **Chroma sampling**: **4:2:0** uses less bandwidth; **4:4:4** keeps more color detail and can improve text clarity.
4. Choose **HDR**. Automatic requests the selected chroma profile's 10-bit HDR format only when the host, Metal decoder and destination display support it. On requires that format. Off requests the 8-bit SDR format. Enable HDR on the host before connecting.
5. Save the settings and start or resume an application.

An unavailable PyroWave profile produces an error. Swiftlight preserves your explicit codec and chroma choices rather than starting a different format. Existing installations retain their codec preference and default to 4:2:0 when the new chroma setting is absent.

The codec has no embedded bitstream version. The supported Vibepollo protocol advertises bitstream identifier `186f0393` in its RTSP description; an incompatible identifier cannot be treated as a compatible stream. See the host's [PyroWave protocol](https://github.com/Nonary/Vibepollo/blob/master/docs/pyrowave-protocol.md) and the [upstream codec](https://github.com/Themaister/pyrowave).

## Set the bandwidth budget

Automatic PyroWave bitrate targets 1.6 bits per pixel for 4:2:0 SDR, scales with resolution and frame rate, multiplies the budget by 1.6 for 4:4:4 and by 1.15 for HDR, and limits the request to 20–900 Mbps. At 1920 × 1080 and 60 FPS, this requests about 199 Mbps for SDR 4:2:0 or 366 Mbps for HDR 4:4:4. These are requested budgets, not measured link capacity, picture quality or latency results.

For a faster wired link, turn off **Automatic bitrate** and enter a manual value up to **10000 Mbps**. The slider covers the first 1000 Mbps; the numeric field supports the full range. Leave room for packet overhead, audio, loss recovery and other traffic. A host's routed transmit-link speed describes its local interface and does not establish end-to-end throughput. Ethernet alone does not guarantee that a requested bitrate will arrive without loss.

Start at a conservative resolution, frame rate and bitrate. Raise one value at a time while checking network loss, decode cadence and confirmed presentation in the [statistics panel](stream-statistics.md). Compare controlled runs on the same host, device, route and display mode before making a latency or quality claim. A simulator or an offscreen Metal test does not establish live streaming performance.

High-rate PyroWave streaming requires optimized native decoding and packet
processing even when the Swift app uses Debug. The decoder package and Swiftlight's
native transport keep optimization enabled with debug symbols and assertions.
Swiftlight also replaces obsolete queued PyroWave
access units before decoding; every frame includes its own sequence header, so
this can recover latency without waiting for a keyframe. Diagnostic exports count
these replacements as `compressedStaleSkips`, separately from network loss.
See the [September 30 latency investigation](dev/pyrowave-latency-2026-09-30.md)
for measured results and validation limits.
The [native decoder follow-up](dev/pyrowave-decoder-latency-2026-09-30.md)
separates CPU preparation, Metal execution and confirmed presentation at explicit
165 FPS, and records the scope of GPU utilization measurements.

## Settings design

The shared Mac, iPhone and iPad settings use native SwiftUI menu pickers with typed selections and accessible labels. Chroma controls appear when PyroWave is selected, keeping the additional choice close to its codec. These choices follow Apple's [settings](https://developer.apple.com/design/human-interface-guidelines/settings), [pickers](https://developer.apple.com/design/human-interface-guidelines/pickers), [Picker API](https://developer.apple.com/documentation/swiftui/picker), [accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), [macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos), [iOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ios) and [iPadOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ipados) guidance reviewed on September 30, 2026. Launched-app, keyboard, VoiceOver, large-text and physical-device checks remain separate acceptance gates.
