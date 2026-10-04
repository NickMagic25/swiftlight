# Compatibility

Swiftlight uses one app target and scheme for Apple silicon Mac, iPhone and iPad destinations. The developing iPhone/iPad experience requires iOS/iPadOS 26 or later. Sunshine and Apollo are the supported host families; tvOS has no app adapter yet. See the [mobile guide](mobile.md) and [current shared-app validation record](dev/shared-client-validation-2026-09-14.md) for destination-specific checks. Earlier simulator and physical iPad records describe the builds actually tested before target unification; they do not establish that a later project configuration passed.

The following feature availability describes the Mac client. The mobile MVP exposes SDR/HDR, Stereo/5.1/7.1 and Direct/System Spatial Audio settings, touch pointer input, and connected controllers. Physical HDR, spatial output, and matched latency acceptance remain device-specific checks; see the [mobile guide](mobile.md).

| Feature | Availability |
| --- | --- |
| HEVC SDR streaming | Supported on compatible Macs and hosts |
| HEVC HDR streaming | Supported when the host, Mac decoder, and display all support the selected HDR path |
| AV1 streaming | Supported on Macs with compatible AV1 hardware decoding |
| HEVC 4:4:4 | Opt-in, with separate hardware checks for 8-bit and 10-bit profiles and matching host support |
| AV1 4:4:4 | Capability-gated; AV1 Main 4:2:0 support does not imply AV1 High 4:4:4 support |
| Stereo, 5.1, and 7.1 audio | Implemented; physical channel placement and sustained playback need broader device testing |
| System Spatial Audio | Implemented for compatible macOS/AirPods configurations; availability is system-dependent |
| Keyboard, mouse, and controllers | Implemented; device- and game-specific behavior can vary |

**Auto** is the recommended codec/HDR choice when you are unsure. Swiftlight reports an incompatibility when a mode explicitly selected by the user cannot be supported. See the [development compatibility snapshot](dev/compatibility-matrix.md) for exact test evidence and remaining release gates.

On October 4, 2026, an Apple M3 Mac running macOS 27.0.1 successfully decoded HEVC RExt 8-bit and 10-bit 4:4:4 samples with hardware required, full-resolution chroma, and Metal texture import. The signed app also received live 3440×1440 HEVC HDR10/PQ/Rec.2020 4:4:4 output. AV1 High 8-bit and 10-bit 4:4:4 session creation returned `kVTVideoDecoderUnsupportedDataFormatErr`; the same-run AV1 Main 4:2:0 controls passed. This is evidence for that Mac and OS. The shared setting and hardware check also apply on iPhone and iPad, whose physical-device 4:4:4 acceptance remains pending. Broader host interoperability, sustained cadence and physical HDR appearance require separate testing; see the [validation record](dev/chroma-444-validation-2026-10-04.md).
