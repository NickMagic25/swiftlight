# Mobile touch input

The iPhone/iPad client has two persisted touch modes: Trackpad and Native Touch.
`StreamSettings.mobileTouchMode` is independent of `pointerMode`; missing values
default to Trackpad. The picker exists only in `MobileSettingsView`, uses the
existing staged Save/Cancel behavior, and applies to the next stream. Mac and TV
have no touch-mode control or touch adapter.

Trackpad follows VoidLink's one-finger relative motion, tap to click, double tap
and hold to drag, two-finger tap to right-click and centroid scrolling. Motion
retains fractional units; wheel motion uses seven protocol units per point,
with horizontal direction inverted. Two-finger tap jitter does not scroll, and
joining a second finger releases an active drag. Pinch shortcuts, inertia and
Apple Pencil pen/pressure settings are outside this change. No VoidLink source
is imported. The inspected reference was its local revision
`5d3985e7`; the relevant implementations are `RelativeTouchHandler.m`,
`TouchPadGestureHandler.swift` and `NativeTouchHandler.m`.

Native Touch uses the pinned common-c `LiSendTouchEvent` API. Geometry reuses
`ViewportTransform` with the renderer's aperture, fit/fill/integer scaling and
drawable pixels, then normalizes into the full encoded frame. New contacts
outside visible video are rejected. Held motion clamps to the visible edge;
an invalid final position uses the last accepted position. Each of ten bounded
contacts owns a stable wrapping UInt32 wire ID. Unknown motion and completion
cannot recreate a rejected or retired contact.

`MobileTouchInput` keeps UIKit identities on the main actor and sends bounded
value actions. It reserves the left 24 points and all three-finger gestures for
local controls, counting edge-only fingers toward local suppression. Gesture
recognizers do not delay raw finger delivery. Indirect pointer taps and pans
remain separate UIKit recognizers and use the existing mouse pointer setting.
Input pauses, geometry changes and teardown retire the local states and release
host inputs. The presenter captures its session generation for notices.

The C admission gate checks active connection state, negotiated host support and
Apollo's separate touch permission (`0x200`). Unsupported support produces a
one-time notice in existing Stream Controls and uses Trackpad for that session.
Explicit denial never falls back to mouse input. Enqueue failures retire the
interaction and request held-input cleanup. Accepted contacts owe cancellation
before common-c teardown, including failed terminal enqueues. See
[transport input ownership](transport.md#input-and-apollo-permissions).

## Apple guidance

Reviewed October 10, 2026 using Apple's DocC representations:

- [Gestures](https://developer.apple.com/design/human-interface-guidelines/gestures): familiar input, discoverable gesture help, unavailable-input feedback and local/system gesture boundaries.
- [Settings](https://developer.apple.com/design/human-interface-guidelines/settings) and [SwiftUI Picker](https://developer.apple.com/documentation/swiftui/picker): two native menu choices with explicit tags, a useful default and staged persistence.
- [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility): semantic labels/current values, Dynamic Type and ordinary controls alongside gestures.
- [UIResponder touchesBegan](https://developer.apple.com/documentation/uikit/uiresponder/touchesbegan(_:with:)): multiple-touch delivery and implementing all four raw touch phases in the narrow UIKit adapter.

## Local validation

Recorded October 10, 2026 using Xcode 27.0 and iOS/iPadOS 27 simulators, with a
26.0 deployment override for local mobile builds:

| Check | Result and scope |
| --- | --- |
| Primary Xcode app | Release iOS device, iOS simulator/test bundle and macOS builds passed. No physical device installation was performed. |
| Full host-independent gate | `scripts/validate-ci.sh` passed: 168 XCTest cases (27 hardware cases skipped), 102 Swift Testing cases, dependency/release/packaging checks, native decoder/PyroWave/transport checks, app harnesses and decoder audit. Skipped hardware cases are not acceptance. |
| Focused settings, state and transport | 43 XCTest cases passed in Release: 26 touch setting/state cases and 17 transport cases. The touch setting/state cases also passed in Debug through the full gate. |
| Native transport | ASan/UBSan gate passed through CI; a separate `SWIFTLIGHT_SANITIZERS=thread scripts/validate-transport-native.sh` run passed. The synthetic sender checks capability/permission separation, wire phases, bounds, invalid values, stale IDs, failures and cancellation ownership. |
| UIKit input adapter | `python3 scripts/validate-mobile-touch-input.py <simulator>` passed 28 checks on each iPhone and iPad simulator. It compiles the production adapter and Core state with synthetic UIKit touches and a recording transport. It verifies gestures, coordinate mapping, local gesture isolation, stale cancellation, fallback, denial and failed-send cleanup. It does not send host input. |
| Native presenter | Updated existing harness passed 13 lifecycle and 30 observation checks on iPad, including local edge exit and dismissal independent of simulated transport teardown. |
| Launched settings UI | The new two-choice picker, Cancel, Save and relaunch persistence passed on iPhone and iPad simulators. The existing iPad large-text/rotation test also passed. Exported XCTest screenshots were inspected: picker label/value, help text and primary actions remain legible in portrait and at the large-text landscape size. Logs: `.build/ipad-touch-{iphone,ipad}-ui.log`; screenshots: `artifacts/ipad-touch/`. |

Physical iPhone/iPad touch recognition, host injection/multitouch behavior,
connected pointer acceptance, and matched live stream timing remain pending.
The renderer and video pipeline are unchanged, and no latency result is inferred
from these input or simulator checks. Test drags, two-finger scrolling and native
contacts against the intended host, including controls, rotation, interruption
and reconnect. Recheck the left-edge disconnect shortcut and HDR Direct
presentation on the physical device after rebuilding.
