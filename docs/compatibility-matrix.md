# Compatibility

Swiftlight uses one app target and scheme for Apple silicon Mac, iPhone and iPad destinations. The developing iPhone/iPad experience requires iOS/iPadOS 26 or later. Sunshine and Apollo are the supported host families; tvOS has no app adapter yet. See the [mobile guide](mobile.md) and [current shared-app validation record](dev/shared-client-validation-2026-09-14.md) for destination-specific checks. Earlier simulator and physical iPad records describe the builds actually tested before target unification; they do not establish that a later project configuration passed.

The following feature availability describes the Mac client. The mobile MVP exposes SDR/HDR, Stereo/5.1/7.1 and Direct/System Spatial Audio settings, touch pointer input, and connected controllers. Physical HDR, spatial output, and matched latency acceptance remain device-specific checks; see the [mobile guide](mobile.md).

| Feature | Availability |
| --- | --- |
| HEVC SDR streaming | Supported on compatible Macs and hosts |
| HEVC HDR streaming | Supported when the host, Mac decoder, and display all support the selected HDR path |
| AV1 streaming | Supported on Macs with compatible AV1 hardware decoding |
| Stereo, 5.1, and 7.1 audio | Implemented; physical channel placement and sustained playback need broader device testing |
| System Spatial Audio | Implemented for compatible macOS/AirPods configurations; availability is system-dependent |
| Keyboard, mouse, and controllers | Implemented; device- and game-specific behavior can vary |

**Auto** is the recommended codec/HDR choice when you are unsure. Swiftlight reports an incompatibility when a mode explicitly selected by the user cannot be supported. See the [development compatibility snapshot](dev/compatibility-matrix.md) for exact test evidence and remaining release gates.
