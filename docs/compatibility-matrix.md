# Compatibility

Swiftlight has a macOS client on Apple silicon and a developing universal iPhone/iPad client for iOS/iPadOS 26 or later. Sunshine and Apollo are the supported host families. The [mobile MVP](mobile.md) builds and runs in both simulator families; physical-device streaming and distribution remain unverified. tvOS has no app adapter yet.

The following feature availability describes the Mac client. The mobile MVP currently exposes SDR, stereo, touch pointer input and connected controllers; see its guide for the remaining device checks.

| Feature | Availability |
| --- | --- |
| HEVC SDR streaming | Supported on compatible Macs and hosts |
| HEVC HDR streaming | Supported when the host, Mac decoder, and display all support the selected HDR path |
| AV1 streaming | Supported on Macs with compatible AV1 hardware decoding |
| Stereo, 5.1, and 7.1 audio | Implemented; physical channel placement and sustained playback need broader device testing |
| System Spatial Audio | Implemented for compatible macOS/AirPods configurations; availability is system-dependent |
| Keyboard, mouse, and controllers | Implemented; device- and game-specific behavior can vary |

**Auto** is the recommended codec/HDR choice when you are unsure. Swiftlight reports an incompatibility when a mode explicitly selected by the user cannot be supported. See the [development compatibility snapshot](dev/compatibility-matrix.md) for exact test evidence and remaining release gates.
