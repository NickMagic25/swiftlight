# Mobile stream controls validation — September 14, 2026

This follow-up covers the mobile performance settings, statistics, local stream
controls, remote-session confirmations, full-screen status-bar presentation, HDR,
and surround/spatial audio integration.
It does not replace the separate mobile distribution or latency acceptance gates.
The recorded runs preceded the single-target/four-folder reorganization. See the
[shared-app validation record](shared-client-validation-2026-09-14.md) for current
structure and subsequent regression results.

## Behavior and implementation

- Settings exposes the shared frame-pacing and drawable-buffer choices. The
  mobile `CAMetalLayer` consumes both choices on the next stream. Apple's separate
  `displaySyncEnabled` switch is unavailable on iOS/iPadOS.
- Statistics default to hidden when no saved preference exists. Settings stages
  the visibility default, detail, and position until Save. Three-finger tap and
  Stream Controls change the current stream without overwriting that default.
- The existing 250 ms monitor samples statistics only while visible. Core Text
  rasterization runs off-main, rejects cancelled revisions, and installs into the
  existing Metal video pass. Hiding removes the bitmap and its accessibility rows.
  VoiceOver metadata describes installed rows, including their rendered placement.
- Three-finger hold and Command–Escape open Stream Controls. A left-edge
  one-finger swipe of about half the width disconnects locally. These controls
  release held input; disconnect retains the remote application.
- Long-pressing the running application's cover offers remote quit. Starting a
  different application asks for confirmation before quitting the current one.
  Actions capture host identity and generation, and authenticated host control
  checks the running app again before quitting. A refused quit refreshes the
  accessible library; trust or library-access failures still clear it.
- Streaming requests status-bar and persistent-system-overlay hiding. The mobile
  plist explicitly declares `LSSupportsGameMode`, removing the missing-key warning
  observed in the user's enabled Metal HUD. Game Mode activation belongs to the OS.

## Evidence

Xcode 26.6 (17F113), Swift 6.3.3, iOS SDK 26.5. The physical device was an
iPad Pro 11-inch (M5), iPadOS 26.6.2 (23G90). The simulator was iPhone 17 Pro,
iOS 26.5. Builds used the committed decoder dependency and existing signing team.
All logs, device identifiers, screenshots, and result bundles remain in ignored
`artifacts/mobile-parity/`.

| Check | Current result |
| --- | --- |
| Xcode MCP mobile build | Final HDR candidate passed on the connected iPad destination; warning-level build log had no issues. |
| Mobile Release build | Device Release build passed with debug capture disabled by compilation. This is not an exported/distributed archive acceptance result. |
| Physical iPad UI checks | `ipad-device-retest.xcresult`: three passed, zero failed/skipped. Settings Cancel, Save, relaunch persistence and restoration; three-finger statistics show/hide with accessibility rows; left-edge local disconnect; both destructive prompts shown and cancelled. |
| HDR/audio settings on iPad | `ipad-hdr-audio-delivery.xcresult`: the same staged, persisted, Stereo-restriction and restoration checks passed. The performance-settings test also passed in `ipad-hdr-audio-settings.xcresult`; its earlier HDR test failed because full test swipes overshot the target row. Controlled shorter test drags resolved that automation issue. |
| HDR/audio settings on iPhone | `iphone-hdr-audio-delivery.xcresult`: passed Cancel, Save/relaunch, Stereo forcing Direct, removal of the spatial option in Stereo, and restoration of original preferences. |
| iPhone settings | `iphone-settings-verified.xcresult`: persistence check passed. Frame pacing, drawable buffers, and statistics default survive Save/relaunch; Cancel discards changes; original settings restored. |
| iPhone accessibility-size navigation | The large-text/rotation check passed in `iphone-settings.xcresult`. Portrait/landscape primary actions remain reachable. This does not cover every picker with VoiceOver or maximum text size. |
| macOS Xcode build | Passed with the shared rasterizer changes. Only the AppIntents metadata-extraction warning remained. |
| Hardware offline gate | `scripts/validate-offline.sh` passed with hardware access: 77 XCTest and 39 Swift Testing checks, two OTP vectors, nine dependency checks, native ASan/UBSan gates, and all eight HEVC/AV1 SDR/HDR/accounting/reconfiguration replays. This is Mac hardware decode and Metal readback, not iPad display acceptance. |
| Focused SwiftPM checks | Eight XCTest checks for statistics/preferences and 13 remote-session Swift Testing checks passed. RemoteSessionTests exercise the existing macOS model, not a mobile host-mutation fixture. |

Reviewed iPad screenshots show live streamed content, the statistics bitmap
visible and hidden, and no iPad time/date/Wi-Fi/battery bar over the stream. The
status bar returns in the library. Settings controls and both confirmation
popovers are legible in the device's Dark appearance. The iPhone simulator's
Light settings capture has legible labels and native controls without overlapping
rows. The enabled Apple Metal HUD is independent of Swiftlight statistics.

The first settings test exposed missing picker accessibility values, which were
added. HDR/audio testing also found that disabling a tagged Picker text did not
disable the corresponding native menu option. System Spatial Audio is now omitted
from the Stereo menu, and the corrected iPhone and iPad tests passed. Its iPhone variant initially tried reading an unmaterialized Form row;
the corrected test scrolls each control into view before asserting its value.
The first opt-in attempt did not pass the environment variable into the runner;
live checks now use Xcode's documented `TEST_RUNNER_` prefix. Those skipped or
failed attempts are not counted as successful checks above.

No SwiftUI state-publication, layout-cycle, or unsatisfiable-constraint issue was
observed in the inspected runs. Simulator UIKit emitted
`no visual style classes have been registered at all` without a visible defect.
Xcode also logged missing LLDB version snapshots and stale SpringBoard
accessibility-server messages. The passed iPad result was finalized after
cancelling optional stalled `devicectl diagnose` collection; Xcode exited zero
and the result bundle reports Passed. Subsequent live checks disable verbose
device diagnostics collection. A simulator result also attached a SpringBoard
crash inside XCTest automation; the inspected crash was not Swiftlight. The final
HDR/audio tests completed successfully, and no Swiftlight crash was found.

## Reproduction and remaining acceptance

The historical runs used the former `SwiftlightMobile` scheme and UI test target.
For the current unified project, with an already paired host and an application
already running, opt into the physical checks using the actual connected
destination and signing team:

```sh
TEST_RUNNER_SWIFTLIGHT_LIVE_UI_TESTS=1 xcodebuild \
  -project Swiftlight.xcodeproj -scheme Swiftlight \
  -configuration Debug -destination 'platform=iOS,id=YOUR_DEVICE_UDID' \
  -derivedDataPath .build/mobile-check \
  -collect-test-diagnostics never -parallel-testing-enabled NO DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  '-only-testing:SwiftlightUITests/MobileNavigationTests/testLiveStreamStatisticsAndEdgeDisconnect()' \
  '-only-testing:SwiftlightUITests/MobileNavigationTests/testRunningApplicationActionsRequireConfirmation()' test
```

The live test resumes the existing application and disconnects locally. The
confirmation test never confirms a remote quit or starts a different application.
Actual successful/refused remote termination still needs a disposable host
session or an injected mobile fixture; no user application was terminated here.

Physical iPhone streaming, manual three-finger hold, VoiceOver/focus navigation,
controller/audio routes, interruption recovery, and iOS/iPadOS 27 remain separate
checks. At the end of this recorded pass, Command–Escape used SwiftUI scene commands
after an earlier UIKit shortcut attempt did not open the sheet. The subsequent
shared-feature regression also reproduced the missing controls sheet, so the
three passed tests above do not establish keyboard acceptance. The native
responder fix and its rerun are tracked in the [shared-app validation
record](shared-client-validation-2026-09-14.md). No 27 toolchain/runtime was installed.

No matched baseline/off/on latency acceptance is claimed. A signed instrumented
SDR baseline and its build-for-testing products are preserved separately from the
HDR candidate, with source and binary hashes in the ignored investigation folder.
The final Debug candidate was installed on the connected iPad. At that point, live comparison
was blocked because Xcode reported the iPad was locked and required its
passcode. Later functional tests with concurrent Mac/iPad streams were not matched
performance trials. The visible statistics sample and Apple Metal HUD are not matched
steady-state trials or proof of zero overhead. See [streaming latency](stream-latency-debugging.md).

## Latency investigation status

The supplied iPad screenshot reports 120 received FPS, a 37.82 ms recent mean
first-packet → display time, and 1.47 ms mean decode time. The independent Metal
HUD shows about 67.92 FPS and 28.59 ms present delay. These windows and populations
are not aligned, so subtracting their means would not identify a stage cost.
They justify collecting same-frame confirmed presentation paths and cadence;
they do not identify the decoder, overlay, or drawable count as the cause.

Source inspection found that iOS cannot use the Mac's `displaySyncEnabled=false`
setting. Both clients already use the same decoder, renderer, bounded latest-frame
mailbox, and GPU admission limit. The mobile HDR adapter now configures metadata
before acquiring its drawable and selects the newest decoded frame again after
acquisition, which can block. It also avoids acquiring a drawable when there is
no frame to present. Those ordering changes satisfy HDR setup and frame freshness
requirements; they are not yet a measured latency improvement. Pacing and drawable
buffer defaults are unchanged pending controlled results.

Next, compare at least three matched hidden/visible runs of the preserved SDR
baseline and candidate, including same-frame stage means/tails, confirmed cadence,
and unconfirmed/evicted timing counts. Inspect two- versus three-drawable and
immediate versus display-paced variants only while holding the other inputs
constant. Keep HDR/audio-route comparisons separate from the SDR timing baseline.
There is no claimed mobile latency reduction or overlay no-regression result yet.

## HDR, audio, and timing follow-up

The mobile plist declares Game Mode support; the inspected physical-device Metal
HUD reports **Game Mode On**. The OS controls activation. The separate Mac VSync
switch remains unavailable on iOS; no unsupported switch or equivalent behavior
is claimed.

HDR settings now participate in the same per-codec host/device negotiation as
macOS. The owning window's potential EDR headroom determines display capability.
The mobile Metal layer uses extended-linear sRGB, the shared 203-nit HDR reference,
and cached HDR10 display metadata configured before drawable acquisition. This
setup requires actual HDR10 decoding, EDR presentation, and visual validation on
a compatible physical display; a simulator or configuration flag is insufficient.

The audio form exposes Stereo/5.1/7.1 independently from Direct/System Spatial
Audio. The mobile audio session declares multichannel content before activation;
Direct queries the actual RemoteIO hardware format and uses the existing downmix
when a route has fewer channels. An accessible Stream Controls value reflects
spatial playback availability, including capability-change notifications. It does
not assert active head tracking. Configuration-only notifications retain the
stream only when the output is unchanged and its relevant channel contract is
preserved; actual output changes still disconnect locally.

Native ASan/UBSan and separate TSan checks passed with playback disabled. They
exercise the existing host harness, ring/layout/downmix and sample-buffer
ownership contracts. They do not execute the iOS RemoteIO branch or establish
AirPods playback. Three focused shared negotiation/metadata checks also passed.
The full offline hardware gate subsequently passed, including HDR readback and ownership checks
on the Mac. An initial sandboxed attempt could not access Metal/VideoToolbox; it
is retained separately and is not counted as a hardware pass. Physical iPad HDR
and spatial-audio output acceptance remains pending.

The requested cross-platform Apple API policy is recorded in `AGENTS.md`: apply
an API across each implemented client where its availability and hardware support
permit it, and document concrete platform limits and remaining device validation.

Current Apple HIG/API references and UI decisions are listed in
[the mobile guide](../mobile.md#apple-design-guidance). The Game Mode declaration
was checked against Apple's [LSSupportsGameMode documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/lssupportsgamemode)
on September 14, 2026; it is supported on iOS/iPadOS 18.6 and later.
