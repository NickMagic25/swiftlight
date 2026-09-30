# Compatibility matrix

PASS means this exact check ran; source support alone is not a pass.

| Host/device/platform path | Implemented behavior | Evidence/status |
|---|---|---|
| macOS arm64 hardware HEVC Main SDR | sole decoder + canonical Metal | Four-codec offline replay evidence; real Sunshine stream awaiting user pairing |
| macOS arm64 hardware HEVC Main10 HDR10 | PQ/BT2020 canonical10 + EDR metadata | Decode/offscreen readback executed; HDR display black/white/highlights not validated |
| macOS arm64 hardware AV1 Main8 | capability-gated AV1 transport and decoder | Eight-frame fixture decode/readback executed; real host stream not validated |
| macOS arm64 hardware AV1 Main10 HDR10 | capability-gated AV110 + EDR | Fixture decode/readback executed; real HDR host/display validation pending |
| No AV1 hardware | explicit AV1 request fails; Auto intersects HEVC | Unit capability selection tested; older physical Mac not tested |
| No HDR display or host10-bit support | Auto chooses SDR; HDR On reports incompatibility | Unit negotiation tested; move between physical SDR/HDR displays pending |
| HEVC reordered/B-slice stream | decoder reports unsupported configuration | No alternate decoding or silent software path; host encoder testing pending |
| Sunshine PIN/apps/launch/resume/quit | implemented established certificate/control protocol | Crypto/protocol fixture tests; user will perform full manual pairing |
| Apollo art:// OTP | exact salt/hash/normal certificate sequence | Python and Swift vectors plus protocol fixtures; deployed host flow pending |
| Apollo arbitrary reusable API token | no verified server endpoint/scopes contract | BLOCKED on a concrete host/fork API specification if this separate feature is required |
| Apollo virtual display | requested geometry in standard launch; permission-gated host behavior | Deployed version/display capability needs validation |
| H.264 / YUV444 / HLG | not advertised; explicit rejection | Architecture audit + format tests |
| Packed native/lossless output | not enabled | SKIP evidence-gated optimization; canonical production path |
| macOS Intel | source deployment target exists | BLOCKED on build/hardware validation; HEVC capability determines usable configurations |
| iOS/iPadOS 26+ | universal SwiftUI app, shared host/streaming engine, UIKit/Metal/touch and AVAudioSession adapters | iPhone/iPad 26.5 simulator builds, launch and UI checks plus unsigned device archive; physical streaming, 27 runtime and signed distribution remain BLOCKED. See [mobile validation](mobile-mvp-validation-2026-09-13.md). |
| tvOS | core shared intent | TODO future target/focus/controller UI/audio and separate HDR API path |

No simulator result establishes hardware decode, HDR, local-network permission behavior or streaming performance.
