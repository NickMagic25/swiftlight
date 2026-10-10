# Mobile system keyboard

The iPhone/iPad stream reserves a one-finger right-edge swipe for showing and
hiding the system keyboard. Stream Controls provides Show keyboard, and the
Game stream accessibility element exposes the same toggle. Keyboard visibility
is transient session state and starts false. The left-edge disconnect gesture
is independent. Both edge strips are excluded from forwarded screen touches.

`MobileStreamKeyboard` is a narrow UIKit text-input adapter attached to the
existing Metal surface. A temporary `UITextField` owns UIKit's language
composition and a `UIInputViewController` owns the native `UIInputView` and
SwiftUI accessory buttons:
Windows, Alt–Tab, Alt–F4 and Hide. The field and accessory are removed when
hidden. The video layer, drawable geometry, renderer and pacing are unchanged;
the system keyboard covers part of the video while visible.

Accessory buttons use opaque near-black backgrounds and semibold white labels
to stay readable over bright or busy video. Alt–F4 retains its destructive role
and red label. The fills stay opaque during pressed and disabled states, and
the labels follow Dynamic Type.

Only committed text is sent. Marked text stays local until UIKit finishes
composition; repeated completion notifications cannot resend the commit. A
zero-width sentinel lets UIKit deliver repeated Backspace presses without
showing local text. Return sends Enter and leaves the keyboard open. The shared
`SoftKeyboardTextInput` planner maps printable ASCII to US Windows virtual keys
and Shift, matching the inspected VoidLink behavior. A run containing Unicode
uses common-c's UTF-8 text API intact, including combining and emoji sequences.
Actual insertion and keyboard-layout behavior depend on the host application.
Commits are bounded to 4096 UTF-8 bytes and invalid control input is rejected
before sending a prefix. Paste uses UIKit's single-line field behavior; use
Return to send an explicit Enter to the host.

The presenter captures the session generation for visibility and failure
callbacks, and its existing focus revision protects delayed sheet dismissal.
Input admission is checked before each send. Hide retires the field before
UIKit resignation callbacks, clears text and handlers, and releases held input.
Controls, suspension, disconnect and session replacement hide the keyboard;
they cannot replay buffered composition into a later session. A denied keyboard
permission or failed enqueue hides the keyboard and reports an issue through
existing Stream Controls.

The shared transport sends each shortcut as one serialized press/release
transaction. It synthesizes required modifier presses, releases in reverse
order, preserves modifiers already held by physical input, rolls back partial
admission, and retains failed releases for teardown cleanup. Text and shortcuts
respect Apollo's separate keyboard permission (`0x1000`). Queue admission does
not prove host insertion. See [transport input ownership](transport.md#input-and-apollo-permissions).

## References and design guidance

The local VoidLink reference was revision `5d3985e7d2c75293082885a2e83006efebb1a213`,
specifically `StreamView.m`, `KeyboardInputField.m`, `InputAccessoryBar.swift`
and `CommandManager.swift`. No reference source or dependencies were imported.
Its marked-text commit handling and Windows virtual-key mapping informed the
adapter; Swiftlight uses the requested direct right-edge toggle.

Reviewed October 10, 2026 against Apple's official HIG and DocC content:

- [Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards), [gestures](https://developer.apple.com/design/human-interface-guidelines/gestures) and [accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility): use the system keyboard, discoverable gesture instructions, labeled buttons and an ordinary control alternative.
- [UITextField](https://developer.apple.com/documentation/uikit/uitextfield) and [UITextInput markedTextRange](https://developer.apple.com/documentation/uikit/uitextinput/markedtextrange): preserve system text composition instead of forwarding provisional characters.
- [UIResponder inputAccessoryViewController](https://developer.apple.com/documentation/uikit/uiresponder/inputaccessoryviewcontroller) and [SwiftUI Button](https://developer.apple.com/documentation/swiftui/button): let UIKit own the accessory controller's placement beside the native keyboard, and keep the accessory content in SwiftUI.
- [UIInputView allowsSelfSizing](https://developer.apple.com/documentation/uikit/uiinputview/allowsselfsizing) and [UIHostingController sizeThatFits](https://developer.apple.com/documentation/swiftui/uihostingcontroller/sizethatfits(in:)): measure height at UIKit's logical container/proposed width, preserving larger text without assuming a fixed screen or native-pixel width.
- [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons), [materials](https://developer.apple.com/design/human-interface-guidelines/materials) and [accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility): preserve native button roles and accessible labels, and use opaque fills for legibility over changing video content.

## Local validation

Recorded October 10, 2026 with Xcode 27.0, iOS/iPadOS 27 simulators and a 26.0
deployment override for the mobile builds:

| Check | Result and scope |
| --- | --- |
| Primary Xcode app | Release generic-iOS device, iOS simulator/test bundle and macOS builds passed. Device builds were unsigned local compilation; no physical device was installed or run. |
| Shared text planner and transport | Focused SwiftPM tests passed: 8 text planner and 19 transport cases. They cover all printable ASCII, composed Unicode, bounds, whole-commit validation, inactive admission and native transaction ownership. |
| Host-independent gate | `scripts/validate-ci.sh` passed: 178 XCTest cases executed with 27 hardware cases skipped, 102 Swift Testing cases, native decoder/PyroWave/transport checks, release/dependency/packaging checks, app harnesses and decoder audit. Skips do not establish hardware acceptance. |
| Native keyboard transport | ASan/UBSan passed through CI; a separate `SWIFTLIGHT_SANITIZERS=thread scripts/validate-transport-native.sh` passed. The sender spy verifies permission gates, Unicode validity, byte bounds, modifier preservation, partial failure, failed-release cleanup and concurrent chord serialization. No host input was sent. |
| Touch and presenter integration | Updated `validate-mobile-touch-input.py` passed 30 checks on each iPhone/iPad simulator. `validate-mobile-presentation.py` passed 17 lifecycle and 41 observation checks on each, including edge thresholds, input admission, keyboard request publication and stale session generations. These use synthetic touches and a fake keyboard surface. |
| Real UIKit system keyboard adapter | `validate-mobile-keyboard.py` compiles the production adapter/planner with a recording transport. Final iPhone default/rotation and largest-text/rotation runs passed 45 and 47 checks; the largest-text iPad run passed 46. Actual first responder, keyboard accessory ownership/layout, ASCII/Unicode, marked/unmark composition, Return/Backspace, stale field/accessory callbacks, cleanup and failures were checked. The iPhone keyboard remained open through scene rotation in both directions. iPad's OS rejected the rotation request in its windowing mode; the field remained active, and an isolated production accessory adapted to 360/680-point containers. This does not establish physical iPad rotation. |
| Visual inspection | System keyboard screenshots were inspected on iPhone and iPad, including largest text and iPhone landscape. Shortcut labels remain legible; a fixed keyboard-down Hide button stays visible while the host shortcuts can scroll. VoiceOver and physical input remain manual checks. |

Logs are `.build/ipad-keyboard-{focused,ci,tsan}.log` and
`.build/ipad-keyboard-{touch-routing,presentation-lifecycle,presentation-observation}-{ipad,iphone}.log`.
Primary builds use `.build/ipad-keyboard-{device,simulator-build,mac}.log`.
Keyboard adapter logs/screenshots use `.build/mobile-keyboard-{ipad,iphone}{,-large}`
with `.log` / `.png` extensions; rotated screenshots have a `-rotated.png` suffix.

After the opaque-button appearance change, the Release generic-iOS device build
and iOS simulator/test-bundle build passed again. The production keyboard adapter
harness passed on iPad at default text size and iPhone at the largest accessibility
text size; both screenshots were inspected. These fresh runs are recorded in
`.build/ipad-keyboard-contrast-{device,simulator-build}.log` and
`.build/mobile-keyboard-contrast-{ipad,iphone-large}.{log,png}`. They do not verify
physical iPad legibility over a live stream or frame-to-display timing.

## Physical acceptance

On the intended iPhone/iPad and streaming host, test right-edge show/hide in
Trackpad and Native Touch, repeat Backspace, Return, accented text and a composed
input language. Verify Windows, Alt–Tab and Alt–F4 against disposable host
windows. Open controls while composing, background, disconnect and reconnect;
no text or held modifiers may survive those transitions. Check VoiceOver,
Dynamic Type, rotation and floating/split iPad keyboards. Recheck left-edge
disconnect, hidden-keyboard HDR Direct presentation, and matched frame-to-display
timing with the keyboard hidden and visible. Simulator UI, native sender spies
and successful builds do not establish these physical or host results.
