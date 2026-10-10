# Mobile presentation and controller routing

Swiftlight presents an iPhone/iPad stream with a native full-screen `GCEventViewController`. Its root becomes the opaque `MobileStreamView`, backed directly by a `CAMetalLayer`, when the streaming pipeline is ready. A temporary SwiftUI child supplies connection feedback and Cancel; it is removed after the first decoded frame. Stream Controls remain a SwiftUI sheet. Statistics remain a cached bitmap drawn in the video's existing Metal pass.

The library stays in SwiftUI, inside a narrow `GCEventViewController` input adapter. Both native adapters set `controllerUserInteractionEnabled` to false so Swiftlight's GameController profile callbacks own controller routing. Touch, keyboard shortcuts and accessibility continue through their existing controls. The presenter observes session changes directly, captures the session identity and generation, retires the previous surface before replacement, and rejects actions from an old connection attempt.

## Direct presentation acceptance

This hierarchy change removes SwiftUI stream-hosting ancestors. It does not force Direct presentation: iPadOS chooses the presentation path. HDR tone mapping now offers Linear and PQ, with PQ as the default. The internal floating-point extended-linear sRGB output with HDR10 metadata remains the system-tone-mapped baseline/fallback. Neither selectable mode clips HDR values to an SDR target to obtain a different HUD label.

The user's October 10 M5 iPad follow-up confirmed Direct in SDR and Composited in HDR on the initial native-presenter build. Both used RGBA16Float, so that format alone did not explain the difference. Enabling EDR and HDR metadata/system tone mapping was the remaining configuration difference; its role in composition was an inference, not an established driver restriction. Apple documents the current [system tone-mapping path](https://developer.apple.com/documentation/metal/using-system-tone-mapping-on-video-content) without guaranteeing Direct presentation. After the output choices became accessible, the user reported Direct in the Metal HUD for both Linear and PQ. This is physical-device evidence for that presentation-mode observation; it does not establish HDR brightness, highlight correctness, cadence or lower latency.

The inspected [iCube iOS renderer](https://github.com/Provenance-Emu/iCube/blob/1e1bf1632b45c6d05d8148f85df559c14f66a0be/Source/iOS/App/Common/Emulation/EmulationCoordinator.mm#L465-L490) at commit `1e1bf1632b45c6d05d8148f85df559c14f66a0be` selects BGRA8 for SDR and RGBA16Float when its EDR option is enabled. However, its [Metal backend disables HDR output on iPhoneOS](https://github.com/Provenance-Emu/iCube/blob/1e1bf1632b45c6d05d8148f85df559c14f66a0be/Source/Core/VideoBackends/Metal/MTLUtil.mm#L83-L88), and the inspected [EDR/color-space setup is macOS-only](https://github.com/Provenance-Emu/iCube/blob/1e1bf1632b45c6d05d8148f85df559c14f66a0be/Source/Core/VideoBackends/Metal/MTLMain.mm#L161-L186). The user's TestFlight revision is unknown. Its Direct result establishes device capability, but does not establish an equivalent HDR10 comparison.

On the physical iPad, compare main and this branch with the same host, codec, HDR state, frame rate, resolution, pacing, drawable count, display/window mode and brightness. Record the Metal HUD presentation mode after connection feedback disappears, then repeat with statistics hidden/visible and after opening/closing Stream Controls. Check HDR highlights, shadows and color; compare confirmed presentation cadence, skips and matched mean/p95 frame-to-API-presentation measurements. Direct mode alone does not establish physical scanout or lower latency. See [latency debugging](stream-latency-debugging.md).

## HDR tone mapping

**Settings → Video → HDR tone mapping** is shared by Mac and mobile and is
available in every build configuration, including Release and archived builds.
The two choices are **Linear** and **PQ**, with PQ as the default at the user's
request after both showed Direct in the M5 iPad Metal HUD. A missing saved choice
or the former System tone mapping choice migrates to PQ. Existing Linear and PQ
selections are retained. Save and reconnect to apply a choice; either mode may
change brightness or clip highlights.

| Mode | Actual HDR10 output | Purpose and limits |
| --- | --- | --- |
| Linear | RGBA16Float, extended-linear sRGB, EDR enabled, no layer HDR metadata | Shader values remain nits / 203, but without metadata 1.0 follows system SDR white, not a guaranteed physical 203 nits. Brightness and highlight clipping may change. Persists as `linearUnmapped`. |
| PQ (default) | BGR10A2, ITU-R 2100 PQ, EDR enabled, no layer HDR metadata | Uses the existing renderer's BT.2020/PQ output and Apple's encoded-HDR colorspace example. Requires matching BT.2020/PQ signaling. Signal range is not a measurement of panel brightness; highlight handling may differ. Persists as `nativePQ`. |
| Internal system-tone-mapped baseline/fallback | RGBA16Float, extended-linear sRGB, EDR enabled, HDR10 metadata with optical output scale 203 | Retained for controlled comparisons and unsupported PQ signaling. Omitted from the settings picker. Persists in historical reports as `systemToneMapped`. |

Apple's current [layer metadata contract](https://developer.apple.com/documentation/quartzcore/cametallayer/edrmetadata)
requires linear-transfer output with values above 1.0 for metadata-driven system
tone mapping. It documents additional GPU/memory processing and possible clipping
when metadata is absent. Its [encoded HDR example](https://developer.apple.com/documentation/metal/using-color-spaces-to-display-hdr-content)
uses BGR10A2 and a PQ colorspace without attaching that metadata. The earlier
mobile diagnostic PQ path attached metadata to packed nonlinear output; the
current PQ path corrects that configuration. Neither Apple example guarantees Direct
presentation. `toneMapMode`, `contentsHeadroom`, pacing, drawable count, Metal HUD
and view hierarchy are unchanged by the new Settings control.

For a physical comparison, first keep statistics hidden and Stream Controls
closed. Record the PQ HUD mode on one fixed HDR scene. Disconnect locally,
save **Linear**, and reconnect to the same scene with the same brightness and
stream settings, then restore **PQ**. Record HUD mode and highlight/shadow/color
changes for each choice. Compare confirmed presentation cadence, skips and
matched mean/p95 timings. Repeat with statistics shown only after the hidden
comparison; nonlinear PQ overlay blending remains approximate. The reported
Direct results with metadata absent support the metadata path as a cause on
this device, but do not establish acceptable HDR appearance or latency.

## Startup and local exit

The initial native presenter relied on the background SwiftUI representable to deliver all later session changes. A full-screen UIKit presentation removes the presenting host's views from the window; updates from that hidden host can be deferred. The separately hosted connection feedback still observes the session, so audio and the "Waiting for video" message can continue while the native surface waits for an update. The first-frame monitor also depends on a frame recorded by the renderer, so creating the surface must happen before that monitor can remove the feedback.

The native presenter now subscribes to the MainActor session independently. Since `@Published` emits before assignment, one coalesced actor task reads the completed state change and updates the surface, input admission, statistics, controls and presentation. Teardown and session replacement cancel the subscription and pending task. This adds no per-frame SwiftUI publication or polling.

Disconnect publishes the inactive session before awaiting transport/decoder teardown. The native subscription can dismiss the stream without waiting for the hidden SwiftUI host or the transport join. A reconnect still waits for the previous teardown to finish. The edge gesture and accessibility Disconnect action use local foreground/key-window admission, independently of gameplay input admission. A paused game input route must not prevent leaving the stream.

## Controller ownership

`ControllerHub` gives an active stream priority over a separately owned menu handler. It installs callbacks on the main queue, captures a route generation, and rejects retired callbacks before looking up the current transport. The hub registers existing extended-gamepad controllers, retains surviving player slots on hot plug, and publishes the controller mask without waiting for the first changed input. Losing the last controller publishes its removal too.

The shared input value model converts buttons, sticks and triggers into GameStream values. Controls held at a route change must return to neutral before forwarding resumes. This prevents a menu activation or an input released during suspension from appearing in a new game/session. Menu movement uses a threshold with hysteresis and bounded repeat; gameplay keeps the framework's input values. Menu routing cannot activate a destructive confirmation.

The shared navigation model follows the adaptive grid's column count. Computer selection stays local until activation, and scrolling keeps the outlined selection visible. iPhone/iPad navigation includes saved and discovered computers, Add Host, pairing/retry and games. Mac navigation uses the same input and selection helpers. Forms retain native touch/keyboard/accessibility interaction.

Physical acceptance includes the Razer Kishi connected before launch and connected after the first frame; all face buttons, D-pad, triggers and sticks; opening/closing controls while holding input; unplug/replug; background/foreground; reconnect; and optional rumble. Test the computer list and game grid in narrow and wide layouts. A snapshot controller or simulator cannot establish USB accessory forwarding, host interoperability or physical haptics.

### Home/Guide passthrough

The shared controller route maps an available `GCExtendedGamepad.buttonHome` to
GameStream's `SPECIAL_FLAG` (`0x0400`, Guide). While stream input is active,
`ControllerHub` requests `.disabled` system gestures for the mapped Home element,
as it does for other mapped gameplay controls. It saves and restores the prior
preference when the stream route pauses or ends, a controller is removed, or
callbacks are replaced. Library navigation does not claim Home or forward it to
a host. Existing generation rejection, held-until-neutral admission and neutral
input release apply to Home too.

This replaces the earlier deliberate exclusion of Home from streaming gesture
requests. The request remains an operating-system preference, rather than a
guarantee that Swiftlight can intercept every physical press. On iOS/iPadOS 26,
the intended double-press passthrough follows VoidLink's implementation; the
system handles the sequence and can reserve a single press for Game Overlay.
Swiftlight forwards the delivered Home down/up events without a second
double-press timer. The same mapping and scoped preference apply on macOS.
iOS/macOS 27 system Home overrides may permit direct single-press delivery; an
app-side double-press gate would incorrectly suppress those delivered events.
This adds no settings control or in-stream UI.

Sources inspected October 10, 2026:

- Apple's [iOS/iPadOS 26 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-26-release-notes) and [macOS 26 release notes](https://developer.apple.com/go/?id=macos-26-rn) describe the first Home press opening Game Overlay and setting `preferredSystemGestureState` to receive additional presses. They do not specify a double-press interval or promise exclusive Home delivery.
- The installed Xcode 27.0 (`27A266a`) GameController SDK's `GCControllerElement.h` describes `.disabled` as the direct-input request and explicitly says the preferred state may not be respected. It deprecates `.alwaysReceive` in OS 27 in favor of `.disabled`. See [preferredSystemGestureState](https://developer.apple.com/documentation/gamecontroller/gccontrollerelement/preferredsystemgesturestate).
- The same SDK's `GCControllerHomeButtonSettingsManager.h` documents OS 27's in-app override: the system's defer setting honors an app requesting `.disabled` for `GCInputButtonHome`, while the system-default setting keeps system handling. These settings are user controlled; this change does not modify them. See [Home button settings](https://developer.apple.com/documentation/gamecontroller/gccontrollerhomebuttonsettingsmanager).
- The inspected local VoidLink checkout was clean for these files at commit `5d3985e7d2c75293082885a2e83006efebb1a213`. Its [controller setup](https://github.com/The-Fried-Fish/VoidLink-previously-moonlight-zwm/blob/5d3985e7d2c75293082885a2e83006efebb1a213/VoidLink/Input/ControllerSupport.m#L1592-L1599) requests `.disabled`, its [mapping](https://github.com/The-Fried-Fish/VoidLink-previously-moonlight-zwm/blob/5d3985e7d2c75293082885a2e83006efebb1a213/VoidLink/Input/ControllerUtil.swift#L1219-L1223) includes Home as `.special`, and its [stream callback](https://github.com/The-Fried-Fish/VoidLink-previously-moonlight-zwm/blob/5d3985e7d2c75293082885a2e83006efebb1a213/VoidLink/Input/ControllerSupport.m#L1470-L1473) forwards the pressed state. Its [user instructions](https://github.com/The-Fried-Fish/VoidLink-previously-moonlight-zwm/blob/5d3985e7d2c75293082885a2e83006efebb1a213/VoidLink/Localization/Localizable.xcstrings#L18001-L18013) specify double-tap on iOS 26+ and Home Button Overrides on iOS 27+. That source is evidence for the chosen approach, not proof of behavior on Swiftlight's physical devices.

Physical acceptance requires checking double-press delivers one usable host Guide
action, releases without sticking, and leaves the system's single-press behavior
under system control. Repeat with controls open, while backgrounding, after
unplug/replug and after reconnect. On OS 27, test the default system handling and
an available user override independently. A controller without `buttonHome`
cannot provide this mapping. Snapshot tests can verify routing and restoration;
they cannot exercise Apple's physical Home gesture recognizer or host behavior.

## Apple references

Reviewed October 10, 2026:

- [Game controls](https://developer.apple.com/design/human-interface-guidelines/game-controls): directional selection, A activation, B cancellation and Menu settings. Home remains system controlled in the library; the explicit streaming passthrough request and its system limits are described above.
- [Focus and selection](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection) and [accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility): visible selection, scrolling and ordinary platform input alternatives.
- [GCEventViewController](https://developer.apple.com/documentation/gamecontroller/gceventviewcontroller): explicit profile routing while SwiftUI owns the UI.
- [Going full screen](https://developer.apple.com/design/human-interface-guidelines/going-full-screen): immersive presentation with reachable controls.
- [UIKit full-screen presentation](https://developer.apple.com/documentation/uikit/uimodalpresentationstyle/fullscreen) and [Published](https://developer.apple.com/documentation/combine/published): native updates must survive removal of the presenting host and read values after assignment.
- [System video tone mapping](https://developer.apple.com/documentation/metal/using-system-tone-mapping-on-video-content) and [Metal performance HUD metrics](https://developer.apple.com/documentation/xcode/understanding-metal-performance-hud-metrics): preserve HDR output and distinguish API timing from presentation-mode/device acceptance.
- [Pickers](https://developer.apple.com/design/human-interface-guidelines/pickers), [pop-up buttons](https://developer.apple.com/design/human-interface-guidelines/pop-up-buttons), [Settings](https://developer.apple.com/design/human-interface-guidelines/settings), [accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) and [SwiftUI Picker](https://developer.apple.com/documentation/swiftui/picker): native menu selection with explicit tags, a meaningful default, an accessible current value and existing staged settings on mobile. Picker, Settings and accessibility guidance were read again October 10, 2026 for the two-choice control; it retains the existing native menu and concise labels.

## Validation boundary

Initial implementation checks completed October 10, 2026, using Xcode 27.0 (27A266a), before the physical follow-up exposed the missing native observation:

| Check | Result and scope |
| --- | --- |
| `Swiftlight.xcodeproj`, `Swiftlight` scheme, Debug | Mac, generic iOS device and both simulator destinations built successfully. Mobile commands supplied `IPHONEOS_DEPLOYMENT_TARGET=26.0` and `CODE_SIGNING_ALLOWED=NO`; the device build was not installed or exported. Existing local project settings were preserved. |
| `scripts/validate-ci.sh` | Passed Swift, Python, decoder, packaging, native transport and app harness gates. The ordinary CI run intentionally skipped 27 hardware tests. |
| `scripts/validate-offline.sh` | Passed available Mac hardware decode, Metal readback and fixture checks. AV1 8-bit and 10-bit 4:4:4 hardware decode tests were skipped because this Mac does not support those profiles. No live stream or iPad display was tested. |
| Native transport sanitizer gates | ASan/UBSan and the separate `SWIFTLIGHT_SANITIZERS=thread scripts/validate-transport-native.sh` run passed. |
| Controller tests | Six shared input tests, five snapshot-controller hub tests and three navigation-model tests passed within the Swift suites. They cover numeric conversion, held-input admission, menu edges/repeat, callback retirement, hot plug and adaptive grid movement. |
| Mobile UI tests | `testAddComputerRejectsInvalidAddressAndCanCancel` and `testLargeTextAndRotationKeepPrimaryActionsReachable` passed on iPadOS 27 and iOS 27 simulators. Screenshots were inspected for the library, form controls, large text and rotation. These tests do not use a physical controller. |
| Native mobile presentation harness | Passed on both simulators against initial presenter source SHA-256 `8a90b8ef22505899f56386f267ff784beac2032518f77d589d8df24889e7308a`. Covers waiting feedback, opaque Metal root/window coverage, removal of feedback, controls sheets, reconnect/disconnect, failed admission, dismantling and generation retirement during UIKit sheet animations. Temporarily omitting the controls-generation guard reproduced the expected stale-completion failure. This run manually drove presenter updates and did not cover the missing observation. |
| Signed Mac app inspection | Launched the local Xcode bundle and inspected the library, Add Computer cancellation and Settings. No live host connection or physical controller was used. |

The startup/exit follow-up adds a SwiftUI observation harness using the actual `MobileControllerEventContent` and background presentation representable. It changes published session state without manually driving normal presenter updates. A preserved source lacking the native subscription failed pipeline attachment within 1.5 seconds on the iPhone simulator. The iPad simulator's exact nested host delivered the ordinary updates in that run, but failed the controlled suspended-adapter check. Hidden-host update behavior therefore varies; these runs expose the unsafe dependency without proving the exact timing cause on the user's physical iPad.

The corrected source also tests edge callbacks with gameplay input disabled, rejection of short/cancelled gestures and stopped/detached/non-key surfaces, feedback removal, statistics and controls publication, reconnect and dismissal before a deliberately delayed fake transport teardown. The tests invoke the production handlers with synthetic recognizers; they do not establish physical touch recognition or live teardown latency.

Follow-up verification on the corrected presenter source SHA-256 `ba9c3434ebb4f693e4b1e34d82ad848c20ee8d9475603d8c823dc0312798a27c`:

| Check | Result and scope |
| --- | --- |
| Primary Xcode app build | Debug generic iOS device and simulator builds passed with the supported deployment target override. No physical installation or signing/export acceptance. Logs: `.build/ipad-controller-regression-{device,simulator}-build.log`. |
| Observation harness | Passed on iPadOS 27 and iOS 27, including the exact library adapter and suspended-adapter boundary. Native pipeline attachment took about 11–21 ms and edge callback dismissal about 22–24 ms in these runs, before a fake two-second transport teardown. These are simulator state-propagation timings, not live startup, touch latency or frame-to-display measurements. Logs: `.build/ipad-controller-observation-after-{ipad,iphone}.log`. |
| Lifecycle harness | Passed on both simulators, including retirement during controls animations, replacement by a different session with an equal generation, cancellation of the old subscription and rejection of late updates after dismantling. Logs: `.build/ipad-controller-presentation-{ipad,iphone}.log`. |
| Regression sensitivity | The preserved source without native observation failed as described above. Restoring the previous gameplay-input gate in temporary generated code failed the expected disabled-input edge-exit assertion. Production files were not changed for these probes. |
| Script/source checks | Python compilation and `git diff --check` passed. No decoder, renderer, transport ownership or HDR output change was made in this follow-up; the broader gates above describe the earlier implementation. |

Run both standalone presentation checks with a booted simulator:

```sh
python3 scripts/validate-mobile-presentation.py <booted-simulator-UDID> --mode lifecycle
python3 scripts/validate-mobile-presentation.py <booted-simulator-UDID> --mode observation
```

It extracts the native presentation controllers from the production source and substitutes a fake session and Metal view. It tests UIKit lifecycle and hierarchy; it does not run the video pipeline, validate HDR, establish Direct mode or measure latency. Temporary harness apps are removed after the run.

### HDR experiment verification

The HDR follow-up adds configuration choices without changing decoder sources or
the renderer's shader. The following checks were recorded October 10, 2026 for
the earlier revision with a Debug-only picker and a forced Release baseline.
That visibility/effective-mode gate is superseded by the subsequent explicit
opt-in control in every build configuration. These rows remain a record of the
earlier runs, rather than verification of the visibility change:

| Check | Result and scope |
| --- | --- |
| Primary Xcode app builds | Debug Mac, generic iOS device and simulator builds passed. Device build used `CODE_SIGNING_ALLOWED=NO` and `IPHONEOS_DEPLOYMENT_TARGET=26.0`; no physical installation or signing/export acceptance. Logs: `.build/ipad-controller-hdr-{macos,device,simulator}-build.log`. |
| Settings and option policy | Three XCTest settings cases and two Swift Testing option cases passed in Debug and Release at the earlier revision. Cover migration, saved choices, unchanged stream requests, rejected values, legacy capture options, the former Release baseline gate and consistent diagnostic fields. The Release gate is now superseded by explicit opt-in in every configuration. Logs: `.build/ipad-controller-hdr-settings-{debug,release}.log`. |
| Offline hardware gate | `scripts/validate-offline.sh` passed: 137 XCTest cases with two unsupported AV1 4:4:4 hardware skips, 96 Swift Testing cases, decoder/native checks and committed fixture readbacks. Includes the existing four native-PQ GPU readback cases. No live stream, visible tone mapping or physical HDR was tested. Log: `.build/ipad-controller-hdr-offline.log`. |
| Native HDR layer harness | 23 checks passed using the exact `MobileHDRLayerState` source compiled against native macOS QuartzCore. Covers unchanged caches, same-color mode transitions, clearing/restoring metadata, packed-PQ eligibility, return to SDR, reset and malformed baseline metadata rejection before mutation. This checks layer properties, not tone-mapping execution or display luminance. Log: `.build/ipad-controller-hdr-layer-macos.log`. |
| Simulator HDR capability | iPadOS 27 and iOS 27 report `CAEDRMetadata.isAvailable == false`. Fresh SDR and unsupported-HDR/no-mutation checks passed; HDR transition checks are BLOCKED. No capability doubles or generated-source availability overrides were used. Logs: `.build/ipad-controller-hdr-layer-{ipad,iphone}.log`. |
| Mac Settings inspection | Launched the signed Xcode bundle, inspected the native experiment menu and selected PQ, then restored the baseline and verified its displayed value after reopening. No stream or physical HDR test. |
| Mobile Settings flow | `testHDRAndAudioSettingsCancelAndPersist` passed on both iPadOS 27 and iOS 27. Settings screenshots were inspected, including the new baseline-valued experiment control. The test covers normal HDR/audio staging, cancellation and persistence; it does not select the new experimental choices or run video. Logs and result bundles: `.build/ipad-controller-hdr-{ipad,iphone}-ui.{log,xcresult}`. |

Run the layer checks independently:

```sh
python3 scripts/validate-mobile-hdr.py --platform macos
python3 scripts/validate-mobile-hdr.py <booted-simulator-UDID>
```

The harness extracts the production layer adapter and its actual color/metadata
value types. Its JSON records source/harness hashes and explicitly marks physical
luminance, system-tone-mapping execution, live video and Direct presentation as
unverified. The tested mobile HDR adapter SHA-256 is
`a349e4965d99610a00b3211cddb49d3a5d7089c2ef58ce313da2fad81171f8c0`.
The final generated harness hash is
`1da0b344abe3d4c52989e2550327f95a04f7f7f7022dc49725bc22c0193f859b`.
The 203-nit optical scale is preserved in the baseline source configuration; no
public getter exposes it for a dynamic assertion. Passing layer-property checks
does not validate physical output scaling.

### Settings visibility correction

The shared scheme's Run action uses Release, while the first HDR experiment
picker was compiled only under `DEBUG`. Normal Xcode Run therefore omitted the
picker. That correction made the control available in every configuration and
made the stream resolver honor its saved selection in Release. At this revision,
System tone mapping was still the missing-key and first-use default, and the
library Settings route was **Video → HDR output experiment**. The subsequent
two-choice/default change below supersedes these labels and defaults. In-stream
Stream Controls does not contain video quality settings.

The generic iOS device, simulator and Mac primary Xcode Release builds passed
after this correction. Three settings XCTest cases and three render-option
Swift Testing cases passed in both Debug and Release, including normal defaults
and Release honoring settings instead of legacy diagnostic flags. Logs:
`.build/ipad-controller-hdr-visible-release-{device,simulator,macos}.log` and
`.build/ipad-controller-hdr-visible-{debug,release}-tests.log`.

The focused Release UI case `testHDRExperimentIsAvailableAndPersists` passed on
both the iPad Pro 13-inch (M5) and iPhone 18 Pro simulators running OS 27. It
selected all three choices, verified Cancel discards changes, saved a different
choice and verified persistence after relaunch. The saved-choice screenshots
were inspected on both devices, and teardown restored their original selections.
Log and result bundle: `.build/ipad-controller-hdr-visible-release-ui.{log,xcresult}`.
This validates the Settings flow without negotiating or presenting a stream.

The renderer and native layer adapters were not changed by this correction;
physical HDR/Direct acceptance was still unverified at the time of these checks.

### Two-choice HDR setting and PQ default

After rebuilding with the visible control, the user reported that both Linear
and PQ showed Direct in the Metal HUD on the physical M5 iPad Pro. The user then
requested retaining the setting with only Linear and PQ and making PQ the default.
The shared picker is now labeled **HDR tone mapping** and exposes exactly those
two choices in every configuration. Its existing `hdrOutputExperiment`
accessibility identifier is retained.

Settings keep the persisted `linearUnmapped` and `nativePQ` identities. Missing
settings and the former `systemToneMapped` choice migrate to PQ; explicit Linear
and PQ choices are retained. The internal system-tone-mapped mode remains for
fallback and controlled comparisons. Save and reconnect to apply a selection.
The user report verifies the HUD mode observed on that iPad; it does not supply
HDR brightness/color measurements, matched cadence or frame-to-display timings.
The build and test rows above record earlier revisions and do not validate this
default/migration change.

Current checks for the two-choice revision:

| Check | Result and scope |
| --- | --- |
| Settings and option policy | Five settings XCTest cases and four render-option Swift Testing cases passed in both Debug and Release. Cover PQ defaults, legacy migration without changing other preferences, preservation of Linear/PQ, unchanged stream requests, rejected values and an explicit internal system baseline. Logs: `.build/ipad-controller-hdr-two-modes-{debug,release}-tests.log`. |
| Primary Xcode app builds | Release generic iOS device, iOS simulator and Mac builds passed. Mobile builds used `CODE_SIGNING_ALLOWED=NO` and `IPHONEOS_DEPLOYMENT_TARGET=26.0`. No physical installation or signing/export validation. Logs: `.build/ipad-controller-hdr-two-modes-{device,macos,ui}.log`. |
| Native HDR layer harness | 23 native Mac layer-property checks passed with the updated enum. The layer adapters and shader were unchanged; this does not render a stream or verify physical brightness or Direct mode. Log: `.build/ipad-controller-hdr-two-modes-layer.log`. |
| Mac Settings inspection | Launched the Xcode Release app, verified the HDR tone mapping value was PQ and the menu contained only Linear and PQ, then closed the menu and quit without saving preferences. No host stream or authentication check. |
| Mobile Settings flow | Release `testHDRToneMappingOffersOnlyLinearAndPQAndPersists` passed on iPad Pro 13-inch (M5) and iPhone 18 Pro simulators running OS 27. Verified both choices are available, the system choice is absent, Cancel discards changes and a saved choice persists after relaunch. Inspected both saved-choice screenshots; teardown restored the original choices. Log and result bundle: `.build/ipad-controller-hdr-two-modes-ui.{log,xcresult}`. No stream was run. |

### Home/Guide follow-up verification

The Home/Guide change affects the shared controller mapping and the scoped
system-gesture request. It does not change transport ownership, rendering or
video configuration. Earlier controller and HDR results above record their
respective revisions. The following fresh checks passed October 10, 2026:

| Check | Result and scope |
| --- | --- |
| Controller input and routing tests | Seven Core XCTest cases and 12 Swift Testing cases (nine controller hub, three menu navigation) passed in both Debug and Release. New cases verify the Guide wire bit, exact delivered Home press/release samples with simultaneous controls, menu isolation, held-Guide admission across pause/resume, retired callback rejection, neutral/mask publication on removal and gesture preference restoration. Snapshot controllers exercise the production hub with an injected sender; no network stream or OS gesture recognizer is run. Logs: `.build/ipad-controller-guide-{debug,release}-tests.log`. |
| Primary Xcode app builds | Release generic iOS device, iOS simulator and Mac builds passed. Mobile builds used `CODE_SIGNING_ALLOWED=NO` and `IPHONEOS_DEPLOYMENT_TARGET=26.0`; no physical installation or signing/export validation. Logs: `.build/ipad-controller-guide-{device,simulator,macos}.log`. |
| Source review | `git diff --check` passed. The default controller sender continues to call the existing transport API with the mapped sample; no native transport, decoder or shader source was changed. |

Physical controller gesture recognition and the host's resulting Guide action
remain separate acceptance checks. Neither successful compilation nor a snapshot
controller establishes physical double-press delivery, single-press Game Overlay
behavior or the host's response. Installation and those checks are left to the
user's iPad testing.

Local logs are under `.build/ipad-controller-*.log`; mobile UI results are in `.build/ipad-controller-mobile-ui.xcresult`. These ignored outputs are local evidence and are not distributed with the source.

Physical iPad installation and testing are left to the user. The user's initial native build reached Direct in SDR and remained Composited in HDR; startup was delayed and edge disconnect failed in both modes. The later user report confirms the Metal HUD showed Direct for both Linear and PQ on the M5 iPad. Startup and swipe acceptance after the corrections, HDR brightness/color and cadence, physical Kishi forwarding, rumble, live-host interoperability, launch cancellation during host requests and frame-to-display latency acceptance remain unverified until the device checks above are completed.
