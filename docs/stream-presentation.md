# Stream presentation policy

macOS streams start in full screen by default. The “Start streams in full screen” setting can select windowed launch and is saved by the existing “Save for This Computer” and “Use as Global Defaults” actions. It is a launch preference; changing settings does not itself move an active window.

`StreamSettings.launchInFullScreen` defaults to `true`. Decoding older global or per-host settings without that key preserves their resolution, custom dimensions, frame rate, bitrate, automatic bitrate, codec, HDR, scaling and pointer choices. Only missing fields receive defaults. An explicitly saved `false` survives encoding and decoding.

The shared `StreamPresentationPolicy.launchesFullScreen(on:settings:)` honors the preference on macOS and always returns `true` for iOS, iPadOS and tvOS. This policy does not create a window or scene. The macOS adapter owns native NSWindow transitions and restoration. The iPhone/iPad adapter presents the stream in a SwiftUI full-screen cover with native UIKit display integration; the operating system still owns windowing and system gestures. tvOS presentation remains future work. See the [mobile guide](mobile.md) for controls and platform validation limits.

Presentation and stream resolution are independent. Full-screen launch does not select a resolution, codec or refresh rate. Native, Native — Safe Area, Window and explicit dimensions continue through the existing geometry policy.

On iPhone and iPad, the stream renders at the physical display's native pixel
size, including scaled display modes. Resized windows use the owning display's
native scale. This preserves the selected stream resolution while avoiding an
oversized presentation surface; touch input and statistics remain aligned with
the video. The operating system still selects Direct or Composited presentation.
See the [iPad presentation investigation](dev/ipad-presentation-2026-09-14.md) for
measurement evidence and current limits.

During a full-screen stream, macOS presentation uses `hideMenuBar` and `hideDock`, as requested. Conflicting `autoHideMenuBar`, `autoHideDock` and `autoHideToolbar` options are removed. No process-switching or Force Quit restrictions are added. Exit, session teardown and window detachment restore the previous options, retaining AppKit's current full-screen bit and removing the full-screen-only toolbar option when the window has exited full screen. Windowed streaming does not apply this override.

The native transition uses the documented [full-screen content-size delegate hook](https://developer.apple.com/documentation/appkit/nswindowdelegate/window%28_%3Awillusefullscreencontentsize%3A%29) to request the destination screen's entire size, and the [presentation-options hook](https://developer.apple.com/documentation/appkit/nswindowdelegate/window%28_%3Awillusefullscreenpresentationoptions%3A%29) to supply the stream's presentation policy before the transition. A delegate proxy first calls the existing delegate's implementation and overrides those two results only for the active stream window. Other optional selectors are forwarded. Teardown restores the original weak delegate only when the proxy is still installed, so a later SwiftUI delegate replacement is preserved. Existing full-screen windows retain a bounded frame-fit fallback; its presence alone is not evidence that AppKit accepts the requested size.

The focused core tests cover migration of a complete older profile, persisted windowed launch, missing/default versus invalid stored values, and every platform's policy. Live checks confirmed windowed launch, full-screen launch with a 3440 × 1440 viewport on the tested external display, input capture/release, and restoration to the paired library and toolbar. Failure restoration and other display configurations retain separate manual qualification.

`python3 scripts/validate-stream-window-lifecycle.py` compiles the controller with in-memory window/application facades and records its source hash. It tests cancellation and delayed transitions, repeated sessions, original state restoration, presentation option validity, native size negotiation, optional delegate forwarding and restoration, and the actual eight-second timeout. It creates no real window and measures no visible presentation; live display geometry remains a separate check.

The final signed build’s exact screen/window/view/layer/drawable agreement is recorded in `artifacts/fullscreen-display-final.json`. This does not qualify notched displays, mixed scaling, display moves or every native full-screen lifecycle.
