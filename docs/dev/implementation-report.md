# macOS implementation report

Swiftlight now contains a native macOS application, shared core/host/transport/video modules, native dependency bootstrap, a signed local app bundle, server-free replay/validation, and acceptance/compatibility documentation. It is **not release-complete**. The initial clean validation was offline. Later live checks verified saved pairing, authenticated library access, a short HEVC 10-bit Desktop stream, input capture/release, and local disconnect. The agent did not enter the PIN. Full-screen geometry matched the tested 3440 × 1440 external display. Broader display configurations, sustained playback, lifecycle/codec coverage and explicit remote quit remain unverified.

## Implemented

SwiftUI host/library/settings and PIN/Apollo pairing flows; Bonjour/manual IPv4/IPv6/custom ports; saved nonsecret host metadata and explicit macOS login-Keychain identity/pins; pinned TLS and certificate challenge; app launch/resume and separately confirmed remote quit; global/per-host settings and capability-aware HEVC/AV1/10-bit negotiation; native/safe-area/window geometry; generation-safe session cancellation/reconnect/suspension; common-c pull transport; stereo Opus/CoreAudio bounded ring and route rebuild; keyboard/relative/absolute mouse, controllers and haptics; native fullscreen/Game Mode eligibility; path/socket diagnostics; floating-point Metal SDR/PQ/EDR rendering with retained CoreVideo texture wrappers; bounded replay metrics and redacted live JSON export.

The dedicated visual validation window uses the same video adapter/renderer to exercise actual display-link drawables independently of a host. Its counters and clock labels distinguish predicted, GPU-complete and confirmed-presented work. Visual replay findings are recorded after execution; it is not a live gaming benchmark. macOS streams now start in native full screen by default, with a persisted windowed-playback preference and a window controller that restores prior presentation on disconnect. Windowed launch and toolbar restoration were observed; the final native full-screen window, view, layer and drawable all matched3440×1440. Full-screen streams hard-hide the menu bar and Dock, with prior presentation restored afterward.

## Package and upstream changes

The decoder remains a separate `MoonlightAppleVideo` SwiftPM dependency pinned to `8d92ee039dc19fe50dc0158d5098d4c5646c6a56`, the existing checkout revision. No decoder source changes were made. Existing uncommitted Qt integration work in the decoder repository remains intact. The application contains no alternate video decoder or H.264 fallback.

common-c is a pristine source-locked Git checkout pinned to `62e066388f1a1b133e0bee947b9a374311a3354b`, with exact ENet/nanors pins. The build applies the explicit, targeted patch series to generated sources, covering callback lifetime/atomic arbitration, read-only clock/socket access and confirmed RTP frame outcome counters. See `dependencies.md` and `transport.md`. Opus1.5.2 and OpenSSL3.6.4 are built statically from SHA-verified source archives. The local app's GPL/dependency notices are bundled. Apple targets beyond macOS require future application/dependency slices.

## Executed validation

Toolchain: Xcode26.6 (17F113), Swift6.3.3, macOS26.5 SDK, arm64 macOS26.6.2 (25G83).

Commands executed during implementation:

```sh
scripts/bootstrap-dependencies.sh
SWIFTLIGHT_DECODER_PATH=../moonlight-apple-decoder scripts/build-app.sh
SWIFTLIGHT_DECODER_PATH=../moonlight-apple-decoder CLANG_MODULE_CACHE_PATH=/tmp/swiftlight-module-cache \
  swift test --disable-sandbox --manifest-cache none --filter CoreTests
scripts/validate-offline.sh
SWIFTLIGHT_SANITIZERS=thread scripts/validate-transport-native.sh
python3 scripts/audit-decoder.py
python3 scripts/acceptance-report.py
```

The full offline script expands to Swift unit/protocol/hardware tests, two independent Python OTP vectors, three dependency preparation tests using isolated Git repositories, native ASan/UBSan checks and all eight fixture replay commands. The dependency checks cover patch isolation, idempotence, generated-source integrity, wrong pins, dirty checkouts, failed patches and preserving local work. Individual replay/ASan/Metal commands are in `video-validation.md`. Native clang static-analysis commands and limits are in `transport.md`.

The clean offline baseline against common-c `62e0663` passed all 36 Swift tests (11 core, 12 host, 7 transport, 6 video), the three dependency tests, two OTP vectors and eight hardware replay/readback fixtures. The app built and signed successfully twice, including replacement of notices copied from a read-only SwiftPM checkout. Strict signature verification and symbol inspection confirmed the bundle and statically linked common-c entry points. The three targeted patches applied to a separately cloned, pristine recursive submodule in the isolated export. These baseline results are archived in [validation-baseline-2026-09-12.json](validation/validation-baseline-2026-09-12.json).

The pairing follow-up fixed async URLSession authentication delegate routing, changed-pin error classification, first-refresh trust lookup through a host alias, stored-pin/unpaired-host recovery, and the signed app's transport policy for fully qualified hostnames. That follow-up suite passed 39 tests: 24 XCTest cases (11 core, 7 transport, 6 video) and 15 Swift Testing host cases. The host suite includes a loopback Network.framework mutual-TLS peer with fresh memory-only identities, exact pin rejection, and alias/recovery regressions. This run is distinct from the archived clean offline baseline; see [pairing-fix-validation.md](pairing-fix-validation.md).

The subsequent stream follow-up diagnosed a live renderer/Core Animation lock inversion from two opposing blocked stacks and separated encoding from callback metrics locks. Its deterministic drawable callback regression passed under Metal API validation with real GPU encoding/completion and synthetic presentation; it does not claim physical display measurement. That follow-up full suite passed 48 tests (11 core, 4 presentation-policy, 19 host, 7 transport, 7 video), including four Keychain caching/invalidation tests. Ten no-window lifecycle groups and nineteen isolated packaging checks passed. Logs are `artifacts/drawable-lock-regression.log` and `artifacts/stream-fix-tests.log`; exact scope and later geometry-build limits are in [stream-deadlock-validation.md](stream-deadlock-validation.md).

The separate `python3 scripts/validate-preview-lifecycle.py` regression passed seven real-HEVC lifecycle checks against the exact production preview source: final-frame retention after finite playback, honest terminal/presentation status, callback-entry timing label, retained frame validity after decoder teardown, the Completed Stop action, destruction before restart, and cancellation of queued Play. It ended with zero live frame owners. This test opened no window and measured no visible presentation.

The statistics follow-up passes 62 Swift tests and native RTP/telemetry sanitizer checks. Live testing verified Q to disconnect, S to toggle statistics, both detail levels and all three panel positions without reconnecting. Measurement definitions, exact executable hash and validation limits are in [stream-statistics-validation.md](stream-statistics-validation.md).

A separate clean source export at `/private/tmp/swiftlight-clean-verification` excluded all build outputs, downloaded and hash-verified the native archives anew, compiled them from source, resolved the pinned remote decoder with no local override, built/signed the app and ran the documented suite. This is an isolated source export of the uncommitted implementation, not a claim that the code was committed or published. Its results are preserved in the archived baseline; [validation-summary.json](validation/validation-summary.json) and the pairing follow-up report distinguish subsequent evidence.

Offline evidence includes real HEVC Main/Main10 and AV1 Main8/Main10 hardware output, every-visible-pixel production Metal readback comparisons, 24 canonical full/video/chroma/crop cases, pending8-to10bit dimension changes, malformed/truncated input, inline/no-display callbacks, bounded capacity, reset/keyframe recovery and retained output after decoder destruction. Each AV1 accounting fixture resolves71 accepted/completed units to48 outputs,23 no-display and20 show-existing events, with zero live retained frame owners at teardown. Tests report no fake decoded frames as codec evidence.

Native ownership/audio/callback tests passed under ASan/UBSan and separately TSan, including6 frame scenarios,100000 ordered stereo frames, permission/clock checks and blocked-callback teardown stress. Video tests and AV1 accounting replay passed ASan with Metal API validation. ASan leak detection was disabled on macOS; explicit frame-owner accounting is scoped ownership evidence, not a process-wide30-minute leak test.

Normal macOS application launch, empty host library, and settings accessibility/UI inspection were executed during the offline baseline. The later relaunched app displayed **Paired** for `ratatoskr.aardvark-adelie.ts.net` and exposed **48 app launch buttons**, verifying saved-pair recognition and authenticated library retrieval over the tailnet address. After the renderer fix, live UI inspection confirmed a short Desktop stream with decoded 3440 × 1440 HEVC 10-bit output, input capture/release, and local disconnect returning to the library and native window without the previous hang. The final developer-signed build separately verified full-screen screen/window/view/layer/drawable3440×1440, followed by the restored paired library and toolbar. Existing pairing access succeeded across developer-signed rebuilds; their designated requirements match. Prompt-free migration from earlier ad-hoc Keychain access controls is not claimed. The PIN entry was not an agent action. Certificate replacement/revocation, comprehensive Keychain lifecycle/recovery, audio playback, remote physical input/haptics, network fault recovery and physical HDR display behavior remain untested. No simulator or other Apple-platform app build is claimed.

## Remaining release gates

The acceptance matrix is the authoritative status source. Its current totals are16 PASS,0 FAIL,1 SKIP,17 BLOCKED and2 TODO. The TODO rows are the future iOS/iPadOS and tvOS applications. The SKIP row is evidence-gated native/lossless output; canonical output remains the validated baseline.

| Non-PASS macOS release requirements | Exact prerequisite/check |
|---|---|
| HOST-01, HOST-02, HOST-03, LIVE-01 | Saved pairing, authenticated library retrieval, short HEVC Desktop playback and local disconnect have partial live evidence. Remaining checks include Bonjour/IPv6/custom ports and privacy permissions; revocation/certificate replacement/Keychain recovery; AV1 and broader launch/resume/playback/explicit-quit interoperability. |
| LIFE-02, INPUT-01 | Local capture/release and disconnect were observed. Remote keyboard, mouse and controller behavior plus held-input disconnect/cancel/focus/hotplug/sleep/reconnect/quit sequences remain to be qualified. |
| GEOM-01, PACE-01 | Physical notched/scaled Mac and external display; fullscreen/resize/movement/viewport alignment, VRR/cadence/missing drawables under a live workload. |
| AUDIO-01 | Host audio playback on wired/Bluetooth/default route changes, interruptions, underruns and measured A/V synchronization. |
| NET-01 | Host on Ethernet and Wi-Fi, plus VPN/IPv6/path changes/loss/reordering; compare actual socket route and recovery diagnostics. |
| UI-01, APPLE-01 | Complete paired/streaming native UI and VoiceOver walkthrough; normally launched signed app network privacy deny/regrant and sleep/power lifecycle. |
| PERF-01 | Fixed4K60 host/scene/encoder/bitrate/display/network, repeated matched-client measurements and30-minute thermal/memory/queue workload. |

Capability-dependent Apollo OTP/permission/virtual-display and separate API-token contracts, physical HDR and Game Mode activation also remain BLOCKED. They require the corresponding deployed host credentials/capabilities/display and user/system controls. Follow `manual-validation.md` and `host-manual-test.md` rather than converting these rows into passes based on offline coverage.

No live4K60 latency, sub1ms client overhead, Game Mode benefit, network improvement or full-application performance result is claimed. Short offscreen paced timings are labeled smoke measurements and are not a gaming/display benchmark.
