# Shared Apple app refactor — September 14, 2026

## Result and source boundaries

`Swiftlight.xcodeproj` has one multiplatform `Swiftlight` app target and one
shared `Swiftlight` scheme. Its single `@main` SwiftUI app is
`Sources/shared/SwiftlightApp/SwiftlightApp.swift`. Mac, iPhone and iPad destinations
all produce `Swiftlight.app`; their existing bundle identifiers and plists remain
SDK-specific. `SwiftlightUITests` is the iPhone/iPad UI test bundle, not a second app.

The source tree now has exactly four top-level folders:

- `Sources/shared/`: common app features in `SwiftlightApp`, plus the Core, Host,
  Transport, Video, native bridge and Replay package modules.
- `Sources/desktop/`: native Mac coordination, views, window/input integration and
  diagnostics, guarded with `#if os(macOS)`.
- `Sources/mobile/`: native iPhone/iPad coordination, views, display/input and
  audio-session integration, guarded with `#if os(iOS)`.
- `Sources/tv/`: documentation for a future adapter, with no app membership or
  implemented TV destination.

The app target automatically includes the synchronized shared app, desktop and
mobile folders. Other shared modules are package dependencies, even though they
are visible as folders in Xcode. SwiftPM's secondary Mac executable includes only
`desktop` and `shared/SwiftlightApp`, excluding mobile, TV and the separate module
directories. Common files require no duplicate per-platform source entries.

The secondary SwiftPM executable product is `swiftlight-desktop`, while its module
remains `SwiftlightApp`. This avoids Xcode resolving the UI test host to a
same-named bare SwiftPM executable. The packager still produces
`Swiftlight.app/Contents/MacOS/Swiftlight`. The UI test target also explicitly
references the native app's target ID.

The common implementation now owns:

- The settings form's section composition and video, quality, audio, performance
  and statistics controls. Mac per-host/global saving and mobile staged Save/Cancel
  remain native wrappers. Mobile gains the existing custom sizing/FPS, integer
  scaling, pointer modes and exact bitrate controls. Stereo offers only Direct
  output on both clients.
- Immutable connection preparation: requested geometry, codec and per-codec HDR
  capability intersection, ephemeral input keys, host launch and transport
  configuration. Native display/audio capabilities and asynchronous session
  lifetime remain platform responsibilities.
- Remote-application confirmation messages and running-app library projection.
  Shared host-control failure classification clears stale authenticated libraries
  after certificate/identity failures. Quit refusal retains its separate handling.
- Statistics sampling and Simple-mode presentation hold, preserving missing-data
  semantics and separate clock domains. Mac hidden diagnostic sampling and mobile
  visible-only statistics publication retain their existing policies.
- Existing artwork/grid/glass, controller, streaming-pipeline and statistics
  rasterization implementations, moved into the common folder.

`#if os(macOS)` / `#if os(iOS)` select native scenes, imports and applicable controls.
Mac full-screen preference and VSync remain Mac-only. UIKit/AppKit display, input,
audio-session and window lifecycle adapters remain platform files. This does not
create a tvOS client or make new native integrations work without an adapter.
Runtime capabilities and OS-version availability are checked independently.

## Verification after target unification and source reorganization

The checks below must use the current `Swiftlight` scheme and four-folder source
tree. Earlier results are retained separately and do not establish acceptance of
this final structure.

| Check | Result and evidence |
| --- | --- |
| Source/project membership review | Confirmed one app target, one entry point and exactly four top-level source folders. The app target references the shared app, desktop and mobile synchronized groups; package module folders and TV are not app source members. |
| Mac Xcode Debug | Passed after the internal product rename; `artifacts/unified-target/macos-delivery-build.log`. All 32 repository app sources appear exactly once, with native files guarded by platform. The earlier launched-settings check is described separately below. |
| iPhone and iPad simulator build/UI checks | All five selected settings behaviors have passing evidence on both simulators: custom numeric Save/Cancel/validation, HDR/audio, performance/statistics, automatic bitrate persistence, and large text/rotation. iPad: five of five passed in `artifacts/unified-target/ipad-settings.xcresult`; the final numeric helper recheck also passed one of one in `ipad-numeric-final.xcresult`. iPhone: four passed in `iphone-settings-linked.xcresult`; the numeric helper's text-selection failure was corrected, and `iphone-numeric-final.xcresult` passed one of one. Both numeric retries include restored-preference equality after reopening. |
| Physical iPad touch stream regression | Passed, one test with zero failures; `artifacts/unified-target/source-layout-ipad-touch-final.log` and `.xcresult`. The single-target app resumed the existing running app and received decoded video, showed and hid statistics with three fingers, disconnected via a left-edge swipe, and verified that the remote app stayed running. |
| Physical iPad remote confirmations / keyboard | `artifacts/unified-target/source-layout-ipad-live-product-fix.log` records one passed and one failed test: remote quit/switch confirmations were cancelled successfully; the earlier combined stream test failed to open controls with Command–Escape. That keyboard route remains unresolved and now has a separate test so it does not prevent touch regression checks. Xcode reported an incomplete final result-bundle staging import for this run, so its log is the case-outcome evidence. No destructive action was confirmed. |
| Generic iOS Release/signature/license checks | Passed after the internal product rename; `artifacts/unified-target/ios-delivery-release.log`. All 32 repository app sources appear once, plus Xcode's generated asset symbols. Both final signed bundles pass strict signature verification with system trust-store access and contain the privacy manifest and seven license notices. `artifacts/unified-target/final-bundle-layout.json` records executable names, preserved bundle IDs and deployment minima. |
| Shared/native automated gate and packaging | Passed after the source move and internal product rename; `artifacts/unified-target/secondary-product-ci.log`. 77 XCTest cases with 13 intentional hardware skips, 51 Swift Testing cases, 9 dependency tests, 22 release tests, 21 packaging cases, native ASan/UBSan, artwork/display/window harnesses and decoder audit. The packager checks include a stale old-name binary to ensure the correct executable is selected. |
| Documentation source/link audit | Passed: 51 repository Markdown files, 215 maintained relative file links, zero missing targets and zero pre-existing maintained-link failures. Excluded 15 pre-existing links to absent ignored investigation artifacts. Source references use the new folders; historical commands/results remain explicitly historical. `git diff --check -- '*.md'` passed. |

The source layout keeps generated common-c output ignored at its new shared path;
bootstrap and its regression test confirm that no legacy top-level module folder
is recreated. The build logs contain only the existing App Intents metadata notice,
with no compiler source warnings or errors. Xcode MCP's connection closed during
the later project migration, so final target builds use `xcodebuild` against the
same Xcode project, scheme and SDKs.

A sandboxed signature recheck could not use the system trust store and returned
`CSSMERR_TP_NOT_TRUSTED`; the authorized verification of both unchanged bundles
passed. No signing identity, certificate or pairing state was replaced.

Simulator screenshots were inspected for shared numeric fields, invalid-value
feedback, HDR/audio and performance settings, and large-text layouts. The
review and artifact index are in `artifacts/unified-target/settings-ui-review.md`.
No matching SwiftUI state/layout or constraint warnings appeared in the sampled
runtime-log interval around 21:40–21:50. Both simulators had shut down before the
final log refresh, so this does not establish a clean runtime log for every test.

Checked-in Cloud hooks now select iOS/macOS using `CI_PRODUCT_PLATFORM` with the
single `Swiftlight` scheme, and ad-hoc export accepts `Swiftlight.app`. Existing
remote Cloud actions must select that scheme after the change is published;
remote workflow execution and artifact distribution were not verified here.

## Earlier shared-feature extraction checks

These checks preceded the final target unification and source move. They used
the then-existing Mac `Swiftlight` and mobile `SwiftlightMobile` app targets;
those historical names may still appear in their logs. They validate the recorded
feature state, not the final source layout.


Environment: Xcode 26.6, Swift 6.3.3, iPhoneOS/iPhoneSimulator 26.5 SDKs. The connected
iPad runs iPadOS 26.6.2. No iOS/iPadOS 27 SDK/runtime is installed.

| Check | Result and evidence |
| --- | --- |
| Mac Xcode Debug | Passed; `artifacts/shared-client/macos-build.log`. The compiler's source list contains all 13 shared files exactly once. |
| Physical-iPad destination through Xcode MCP | Build passed. Xcode's warning-filtered build log had no reported entries before the final settings-only rebuild; the final MCP build also returned no errors. |
| Generic iOS Release | Passed and signed; `artifacts/shared-client/mobile-release.log`. Both device families, all shared files, privacy manifest and seven license notices are present. Strict signature verification passed. This was a build, not an exported archive or distribution run. |
| Full host-independent gate | `scripts/validate-ci.sh` passed; `artifacts/shared-client/validate-ci.log`. 77 XCTest cases with 13 intentional hardware skips, 51 Swift Testing cases, dependency/release/packaging checks, native ASan/UBSan, artwork/display/window harnesses and decoder audit. Source hashes match the successful Release settings build. |
| New behavioral coverage | Six connection-preparation tests, three statistics-sampler tests and three remote-session trust regression tests passed in the full gate. They exercise actual request/mask consistency, secret redaction, missing/stale measurements, presentation holds, and rejected certificate/identity changes before or after a confirmed quit. |
| Mac launched UI | Inspected the shared settings in the signed Xcode Debug app. Corrected a duplicate numeric-field label; the field exposes an editable accessibility element. Custom FPS changed to 75 and back to its original 0. Stereo changed the output to Direct and the menu offered only Direct. No settings Save action was used during these checks. The user subsequently selected a host and started a stream in the rebuilt Mac app; this observation is not a controlled performance trial. |
| iPhone and iPad simulator settings | Superseded by the final target's simulator runs above. |
| Physical iPad stream controls | `artifacts/shared-client/ipad-live-refactor-authorized.xcresult`: one passed and one failed, zero skipped. Existing-app resume and statistics show/hide succeeded; Command–Escape did not open Stream Controls, so edge disconnect was not reached. The separate remote-action test showed and cancelled both destructive prompts and kept the running app unchanged. The native keyboard responder fix and its final regression are tracked above. |

The full gate's first sandboxed attempt could not exercise local TLS/image-service
fixtures; the authorized rerun passed. Preserve the environmental failure in
`artifacts/shared-client/validate-ci-sandbox.log`. Compiler output includes the
existing App Intents metadata-extraction notice because the app does not use that
framework; this is not a SwiftUI layout/state warning.

The new numeric UI test caught reciprocal text/value callbacks repeatedly updating
the field during a custom-FPS edit. The shared field now updates text and the draft
in the same binding transaction, with one-way synchronization for external
picker/slider changes. Later failed selections were XCTest text-replacement
failures; the harness must verify an empty field before entering replacement text.
Failed runs and zero-selected-test runs are retained as diagnostics, not passes.

## Remaining acceptance

This refactor does not establish physical HDR brightness, spatial-audio/head-pose
quality, general keyboard forwarding, or lower packet-to-presentation latency.
Matched baseline/hidden/visible trials remain required for performance claims.
Concurrent Mac/iPad streams are functional observations only. Earlier mobile
measurements and acceptance boundaries remain in the [mobile stream-controls
record](mobile-stream-controls-2026-09-14.md). No Cloud workflow, exported archive, release,
commit or publication is established by the local checks in this record.

## Apple and Swift guidance

Consulted September 14, 2026:

- Apple's [Xcode folder guidance](https://developer.apple.com/documentation/xcode/managing-files-and-folders-in-your-xcode-project)
  and [multiplatform target configuration](https://developer.apple.com/documentation/xcode/configuring-a-multiplatform-app-target)
  informed synchronized source membership in one multiplatform app target, with
  conditional native adapters.
- Current HIG [Settings](https://developer.apple.com/design/human-interface-guidelines/settings),
  [macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos),
  [iOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ios),
  [iPadOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ipados)
  and [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility),
  plus SwiftUI [Form](https://developer.apple.com/documentation/swiftui/form),
  [Picker](https://developer.apple.com/documentation/swiftui/picker) and
  [TextField](https://developer.apple.com/documentation/swiftui/textfield): common
  native controls, explicit accessible labels and platform-specific save/navigation
  behavior. These design checks are not blanket OS 27 or physical-device acceptance.
