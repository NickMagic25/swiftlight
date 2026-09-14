# Mobile MVP validation — September 13–14, 2026

This record covers the initial universal `SwiftlightMobile` iPhone/iPad target.
It is a local validation record, not a distribution or physical streaming acceptance.

## Implementation

- iOS/iPadOS 26 minimum, universal device families 1 and 2, shared Xcode scheme
  with a native UI test target. The macOS scheme and SwiftPM packager remain.
- SwiftUI computer/library navigation, PIN pairing and settings, using existing
  authenticated host control, Keychain identity and saved-host storage.
- Full-screen UIKit/Metal integration reuses the existing streaming pipeline,
  transport, controller hub and sole MoonlightAppleVideo decoder. The initial
  mobile defaults are SDR and stereo. Touch pointer input and connected game
  controllers are supported; [the mobile guide](../mobile.md) lists scope limits.
- Session generations reject retired work; teardown completes before reconnect.
  App inactivity and the controls sheet suspend input. Backgrounding, network
  loss and audio interruption end the local session without quitting the host app.
  Connection feedback and Cancel remain visible until the first decoded video
  frame; input is admitted only after transport startup and that frame.
- Separate device and simulator OpenSSL/Opus libraries, per-SDK linker paths,
  versioned dependency caches, app icon, privacy manifest and seven license notices.
- Cloud hooks prepare the correct SDK dependencies and version branch/release
  builds. The ad-hoc exporter validates the universal device archive. See
  [Cloud setup](xcode-cloud.md) for the actual remote configuration steps.

## Local evidence

The installed toolchain was Xcode 26.6 (17F113), Swift 6.3, with iOS/iPadOS 26.5
SDKs and simulator runtimes. Package resolution used the committed decoder pin.
Local logs and result bundles are in the ignored `artifacts/mobile/` directory.

| Check | Result and scope |
| --- | --- |
| Xcode MCP mobile build | Final build passed for iPhone 17 Pro simulator. The warning-level build log and Issue Navigator both returned zero issues; `xcode-mcp-delivery-build.log`. |
| iPhone/iPad UI suite | Final `mobile-ui-delivery.xcresult`: three tests passed on iPhone 17 Pro and three on iPad Pro 11-inch (M5), iOS/iPadOS 26.5. Actual app launch, address rejection/cancel, settings cancel/save/relaunch persistence, accessibility XXXL text and strict landscape/portrait window-orientation checks. Screenshot review is separate from interaction assertions. |
| Device Release archive | Passed, arm64 iPhoneOS, unsigned. Correct bundle identifier, device families, deployment version, icons, privacy manifest, dSYM and seven matching notices; system-only dynamic dependencies. Final `archive-audit.json` confirms no `stat`/`fstat`/`lstat` imports and retained Apple secure RNG. |
| Primary macOS Xcode build | Passed. |
| `scripts/validate-ci.sh` | Passed after correcting the Release tests' Python shim. Hardware tests are deliberately off in this gate. |
| `scripts/validate-offline.sh` | Passed, including hardware HEVC/AV1 fixtures through the production decoder/Metal readback and source audit. These are Mac/offscreen results, not mobile presentation results. |
| Native ASan/UBSan and separate TSan | Passed transport, input/ownership and audio harnesses. No physical mobile audio playback was measured. |
| Mobile cryptography runtime | Passed on iPhone 17 Pro/iOS 26.5 simulator: secure entropy, ephemeral identity/PKCS12, signature/tamper rejection, AES ECB/CBC/GCM vectors, rejected GCM tag and unavailable file-store lookup. No app pairing credentials were used. |
| Release and clean native bootstrap regressions | 20 Release tests and 9 dependency-preparation tests passed, including read-only incremental license copying, mobile-only license preparation, patch rejection and cache invalidation. |

The Xcode build tools emit the informational AppIntents metadata-extraction
warning because this app has no AppIntents dependency. This is distinct from a
SwiftUI compiler or runtime layout warning. Simulator system accessibility and
launch-metric messages are not evidence of app correctness or live presentation.

The first UI run passed address/cancel and large-text/rotation interactions but
failed the switch assertion. Its recording showed XCUITest tapping the center
of the Form row instead of its trailing switch. The corrected test targets the
switch and waits for the value change. An incremental run also found read-only
license outputs; the copy phase now installs writable bundle copies without
altering the immutable source notice. Both fixes have focused regression coverage.

The first paired run exposed an iPad SwiftUI runtime warning about a bottom
toolbar inserted into a hosting view. Moving Settings alongside Add in the
native top toolbar eliminated that warning. Full-display screenshots and a
strict window-orientation check replaced the earlier permissive rotation check.
That stricter check exposed an iPhone simulator stuck in portrait, accompanied
by stale SpringBoard accessibility errors. Restarting that simulator without
erasing app data restored rotation; the same strict check then passed. Reviewed
iPhone and iPad landscape captures have no black padding and retain accessible
large-text navigation and form actions.

The final delivery run exported 18 screenshots, with 12 distinct flow captures
reviewed across both device families. No SwiftUI runtime issue text or crash
attachments were present. The final apps were relaunched on both simulators;
their ordinary computer/library screens were inspected. Screenshot maps and
the review are retained in `artifacts/mobile/ui-review.md` and `delivery-ui/`.

The initial linked device binary retained OpenSSL's unused file-store `stat`
import. The [mobile-only provider patch](../../patches/openssl/README.md) removes
that registration, without changing cryptographic algorithms or the Mac build.
All mobile slices were rebuilt, the expanded crypto probe passed, and the final
device archive no longer imports file-metadata APIs. Original Mac source and
native archive hashes are unchanged. Normal distribution privacy review and
App Store Connect processing remain required.

## Remaining acceptance

- No physical iPhone or iPad was connected. Host pairing, live video/audio,
  touch/controller behavior, input release during interruptions and frame-to-display
  latency remain unverified on each physical device family. No mobile latency or
  HDR acceptance is claimed.
- Xcode 27 and iOS/iPadOS 27 runtimes were not installed. Apple HIG/API guidance
  was reviewed for the platform-adaptive controls, but 26 compilation does not
  establish 27 runtime or visual acceptance.
- The Mac locked during interactive simulator inspection. Automated launch,
  navigation and screenshot evidence must be distinguished from full manual
  VoiceOver, keyboard, appearance, resizing and physical-device acceptance.
- App Store Connect required sign-in. Remote mobile Cloud workflows, signing,
  TestFlight groups, registered-device exports and tester installation were not
  configured or verified in this run. No commit, push, tag or release was made.

Apple references and design decisions are in [the mobile guide](../mobile.md#apple-design-guidance).

## September 14 navigation follow-up

Add Host is now a text row below the saved entries in My Computers, including
when no computers are saved. Settings occupies the former plus action's top
toolbar position. The Xcode MCP build and warning-level Issue Navigator were
clean. Two focused UI tests passed on each simulator family in
`mobile-host-row.xcresult`, covering Add Host validation/cancellation and
large-text scrolling, orientation changes, Add Host activation and Settings
access. These four checks cover this layout change; the device archive and
broader suite above describe the preceding MVP run.

## September 14 cover-grid follow-up

The mobile library now compiles the shared `AppLibraryGrid`, `AppArtworkStore`,
and `GlassStyle` sources. Mobile game names stay visible beneath covers, and
Add Host uses the same semantic headline font and tint. Loading uses the
existing authenticated host artwork API, bounded thumbnail/cache work, and
generation checks. Background work, refresh, and streaming pause artwork
requests. Cancelling an Add Computer operation also clears its operation marker
so a later authentication failure cannot preserve an old paired library.

- Xcode MCP mobile build passed, with no warning-level build entries or Issue
  Navigator findings after the final model fix.
- The macOS Xcode app build passed in `.build/mobile-grid-macos`; no SwiftUI or
  compiler warnings. Its only build warning was skipped AppIntents metadata
  extraction because the app has no AppIntents framework dependency.
- `mobile-cover-grid.xcresult`: six focused checks passed across iPhone 17 Pro
  and iPad Pro 11-inch (M5), both iOS/iPadOS 26.5. These cover Add Host address
  rejection/cancellation, primary navigation at large text with rotation, and
  the saved paired computer's actual library grid.
- `mobile-cover-grid-dark.xcresult`: the paired-library check passed again on
  both destinations after the cancellation fix, using Simulator's actual Dark
  appearance. Both simulators' original Light appearance was restored afterward.
- Inspected real host covers and labeled fallbacks, wrapping game names, and
  portrait/landscape layouts: two/four columns on the tested iPhone and three/five
  on the tested iPad with its sidebar visible. Accessibility XXXL uses one column.
  The first result bundle is Light appearance, including the initial attachment
  whose name incorrectly mentioned dark; the second bundle records Dark.
- The existing artwork-store harness passed all 13 checks; the cached
  `HostArtworkTests` suite passed all six tests under normal macOS access.
  Sandbox-only ImageIO fixture failures did not reproduce with that access.
- No matching SwiftUI state/layout or unsatisfiable-constraint warnings were
  observed in either simulator's captured app output during the first run. The
  iPad unified-log scan also found none from 00:57 to approximately 01:01 EDT;
  iPhone unified logs were unavailable after that simulator shut down.

Result bundles and inspected screenshots remain under ignored
`artifacts/mobile/`. The library checks do not start an application or a stream;
physical-device streaming, full VoiceOver/keyboard acceptance, distribution, and
iOS/iPadOS 27 remain subject to the separate gates above.
