# Verified assumptions

Checked 2026-09-12 against Xcode 26.6 (17F113), Swift 6.3.3 (swiftlang-6.3.3.1.3), macOS 26.5 SDK (host OS 26.6.2, build25G83) and the pinned source revisions below. Compiling an API is not evidence of its behavior on older physical devices.

| Assumption | Evidence and implementation decision |
|---|---|
| Decoder is a SwiftPM C module | `moonlight-apple-decoder` revision `8d92ee039dc19fe50dc0158d5098d4c5646c6a56`, Package.swift/header/architecture inspected and compiled through SwiftlightVideo. The brief's older f1a3bc1 revision is superseded by the existing checkout; no decoder source changes made. |
| Hardware required and exact terminal ownership | Pinned decoder.h `mav_decoder_submit_copy`, reset/drain/destroy contract; production adapter fixture gates. Codec queries are candidate checks only. |
| HEVC/AV1 advertised format bits differ from server codec bits | common-c `Limelight.h` and Qt `session.h` map host AV1 0x10000/0x20000 to transport 0x1000/0x2000. No H.264/4:4:4 advertisement. |
| CAMetalDisplayLink available macOS14/iOS17/tvOS17 | Xcode SDK QuartzCore/CAMetalDisplayLink.h and [Apple documentation](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink). Update has drawable, targetTimestamp and targetPresentationTimestamp. Use supplied drawable and one preferred frame of latency. |
| CAEDRMetadata is not a universal Apple API | SDK CAEDRMetadata.h: macOS10.15/iOS16; explicitly unavailable on tvOS. Future tvOS HDR needs a platform implementation, not a copied macOS call. |
| EDR optical scale is configurable | SDK CAEDRMetadata.h defines C = opticalOutputScale × linear buffer value. Renderer uses PQ nits/203 with scale203 metadata. [Apple HDR workflow](https://developer.apple.com/documentation/metal/using-system-tone-mapping-on-video-content). Physical HDR remains unverified. |
| Canonical zero format constraints do not enable native/lossless | Pinned decoder config/header and SwiftPM build exclude experiments. Do not enable environment-controlled experiments in production. |
| Safe area may already be applied by system fullscreen | SDK NSScreen safeAreaInsets plus actual window intersection; no device-model lookup. Unit tests cover double-inset prevention. Physical display gate remains open. |
| Game Mode is eligibility, not activation | [LSSupportsGameMode](https://developer.apple.com/documentation/bundleresources/information-property-list/lssupportsgamemode), [legacy key](https://developer.apple.com/documentation/bundleresources/information-property-list/gcsupportsgamemode), [Apple requirements](https://support.apple.com/en-us/105118). Game category and native full screen; legacy key retained for macOS14. No force-enable API or active indicator. |
| Bonjour/local-network privacy needs application context | [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy). macOS bundle has description and _nvstream._tcp declaration. Signed normal-launch permission denial/regrant is a manual check. tvOS privacy declarations must be independently evaluated. |
| Apollo token means verified OTP protocol here | Apollo `adc5c5a0bd80831ce495434bb16aee2cd4175fb8`, Artemis `c5cf27f4dc822db0e863c4691e7a70c74bea977a`; see host-protocol.md and cross-language vectors. No arbitrary bearer token contract verified. |
| Socket service types already exist upstream | Pinned common-c PlatformSockets.c assigns Apple voice/video service types. Keep transport/FEC/ENet/crypto unchanged except documented callback-lifetime patch. System NWPath does not identify the live socket route. |

Apple's documentation web pages returned JavaScript wrappers through web retrieval. API availability and comments were independently read from the selected SDK headers. Links remain references, not claims of real device validation.
