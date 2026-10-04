# HEVC and AV1 4:4:4 validation — October 4, 2026

Swiftlight now exposes the shared Chroma sampling control for Automatic, HEVC,
AV1 and PyroWave. Existing settings default to 4:2:0. An explicit 4:4:4 request
requires matching host and exact hardware-profile capabilities before launch;
it cannot silently negotiate or decode to 4:2:0. Automatic selects a compatible
codec and HDR profile. Failures remain retryable on a later connection.

The decoder parses HEVC Range Extensions and AV1 High 8/10-bit 4:4:4, requests
canonical bi-planar output, and validates hardware acceleration, exact output
format and chroma geometry. Native probe samples retain upstream GPLv3
attribution, reproducible adaptation and hashes. There is no new runtime video
implementation or software fallback. The renderer retains CoreVideo owners
through GPU completion and samples full-resolution UV without subsampled
chroma offsets. Statistics distinguish requested, negotiated and actual output
sampling, leaving unavailable output sampling omitted.

## Executed evidence

Hardware: Apple M3, Mac15,3, macOS 27.0.1 (26A434). These results establish
capabilities on this machine and OS.

| Check | Result and scope |
| --- | --- |
| HEVC Main8/Main10 and AV1 Main8/Main10 4:2:0 controls | Actual hardware output, exact format and plane geometry passed. |
| HEVC RExt8/RExt10 4:4:4 | Actual hardware `444v`/`x444`, full-resolution 1280×720 UV and retained Metal import after reset/destruction passed. |
| AV1 High8/High10 4:4:4 | Unsupported data format at VT session creation, including default/4:2:0 output requests. Production profile query returns unavailable. |
| Strict native profile gate | Passed with `MAV_PROFILE_HARDWARE_TESTS=1 MAV_PROFILE_REQUIRE_HEVC444=1`; a known-capable HEVC profile cannot become a silent skip. |
| Decoder CMake/CTest | All 11 tests passed in the hardware offline gate, including profile probing and native PyroWave. |
| Decoder portable sanitizers and Swift ownership smoke | Focused ASan/UBSan parser/ABI/lifecycle checks and isolated SwiftPM C ABI ownership smoke passed. |
| Production Metal readback | Full/video 8/10-bit, cropped per-pixel saturated chroma and all six siting values passed. Additional ten-bit PQ/BT.2020 full/video cases passed against independent CPU references, with Metal API validation in focused runs. |
| Shared/client verification | `scripts/validate-ci.sh` and `scripts/validate-offline.sh` passed. Offline Swift suite: 128 XCTest cases, two explicit unavailable AV1 High skips, zero failures; 82 Swift Testing cases passed. Eight existing replay fixture sets passed. |
| Transport validators | Every HEVC/AV1 8/10-bit 4:2:0/4:4:4 profile creates the actual native transport. Unknown formats and H.264 remain rejected. ASan/UBSan and separate TSan transport gates passed. |
| Primary app builds | Signed Mac `Swiftlight` Xcode build and strict signature verification passed. Shared iPhone/iPad simulator build passed with deployment target 26 supplied on the command line. |
| Live signed Mac app | Observed requested, negotiated and decoded HEVC HDR10/PQ/Rec.2020 4:4:4 at 3440×1440 through the actual stream surface. |

The HEVC8 probe sample signals BT.601 primaries unsupported by the renderer.
The original color deliberately rejects; its retained storage rendering check
uses explicitly supported test primaries. This is not original-gamut acceptance
or independent decoder pixel equivalence for compressed content.

The first live connection attempt exposed stale 4:2:0-only validation masks in
both the Swift transport and C bridge. Both masks were corrected, native-creation
regressions added, and the final build/gates above rerun before the successful
live observation. Generated common-c sources and dependency pins are unchanged.

The final signed app is `.build/xcode-chroma-fixed/Build/Products/Debug/Swiftlight.app`.
Verification logs are ignored local files under `.build/chroma-fixed-*`.
The simulator build uses `IPHONEOS_DEPLOYMENT_TARGET=26.0` because the current
project's recommended-target setting resolves below existing API requirements
with this toolchain; this work does not change that project setting.

## Remaining acceptance

The live scene had variable/static content. Requested 165 Hz is configuration,
not proof of sustained 165 FPS. Matched 4:2:0/4:4:4 gaming cadence, frame-to-display
latency, bandwidth, physical HDR luminance/shadows/highlights and longer lifecycle
coverage remain unmeasured. No mobile physical-device or mobile settings-flow
acceptance is inferred from a simulator build. AV1 High hardware output remains
unavailable on the tested Mac; future devices must pass the exact profile probe.

The shared native menu picker, semantic labels and existing accessibility
identifier follow current Apple [Picker](https://developer.apple.com/documentation/swiftui/picker),
[menu picker](https://developer.apple.com/documentation/swiftui/menupickerstyle),
[pop-up button](https://developer.apple.com/design/human-interface-guidelines/pop-up-buttons)
and [accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
guidance checked on October 4. The user operated the new setting and live stream;
complete keyboard/VoiceOver and mobile appearance walkthroughs remain pending.
