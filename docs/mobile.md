# iPhone and iPad MVP

The single `Swiftlight` app target and scheme in `Swiftlight.xcodeproj` support Mac, iPhone and iPad destinations. iPhone and iPad use iOS/iPadOS 26 as their minimum version. All destinations share the SwiftUI app entry point, common settings controls, library grid, connection preparation, statistics, transport, audio engine, decoder and renderer. Native navigation, display, input and audio-route handling adapt to each platform. The mobile experience is under development; remaining differences are listed below.

## Connect and play

1. Allow Local Network access when prompted. Use the same network as a computer running Sunshine or Apollo.
2. Choose a nearby computer, or tap **Add Host** beneath **My Computers** to enter its hostname or IP address. Custom HTTP ports and bracketed IPv6 addresses are supported.
3. Select **Pair Computer** and enter the displayed PIN in Sunshine or Apollo. The application library loads after the computer authenticates successfully.
4. Open **Settings** using the gear at the top right to choose resolution, frame rate, codec, picture size, and bitrate. **Save** applies your choices to the next stream; **Cancel** discards edits.
5. Tap an application to start streaming. Tap a running application to resume it. If a different application is already running, review the **Switch Applications?** confirmation. **Quit and Start** quits the running application on your computer before starting the selected one; unsaved progress may be lost. **Cancel** leaves it running.

Video settings include custom pixel dimensions and frame rate, fit/fill/integer scaling, and relative or absolute pointer mode. With Automatic bitrate off, use the slider or enter an exact bitrate. Invalid values keep the settings sheet open with an explanation so you can correct them or cancel.

On iPhone and at narrow iPad window sizes, the computer list opens the selected computer's library in a navigation stack. On a wider iPad window, the computer list and library appear side by side. Forms, controls, and text adapt to the window, orientation, appearance, and system text size.

The library displays a grid of cover art from your computer, with each game's name beneath its cover. The number of columns adapts to the available width; accessibility text sizes use one column with wrapping titles. Applications without usable artwork show a placeholder and remain playable. **Add Host** uses the same blue semibold text as the game titles.

To end an application on your computer, touch and hold its running tile, choose **Quit Remote Application**, and confirm. This is separate from disconnecting your device. Swiftlight checks the computer's current application again before quitting; if another application has taken its place, it asks you to review a new confirmation.

## Stream controls

Touch the video to move the pointer and tap to click. A connected physical game controller can provide game input. The stream fills the screen with the status bar and controls hidden initially.

| Action | Touch | Physical keyboard or VoiceOver |
| --- | --- | --- |
| Show or hide statistics | Tap with three fingers. | Press **Control–Option–Shift–S**, or use the **Game stream** element's **Show Statistics** / **Hide Statistics** custom action. |
| Open Stream Controls | Touch and hold with three fingers. | Press **Command–Escape**, activate **Game stream**, or use its **Stream Controls** custom action. |
| Disconnect locally | Swipe one finger inward from the left edge to about the middle of the screen, then release. | Open **Stream Controls** and choose **Disconnect**, or use the **Game stream** element's **Disconnect** custom action. |

The current automated iPad check could not open **Stream Controls** with
**Command–Escape**. Keyboard shortcut acceptance remains unresolved; use the touch
or accessibility controls. See the [current validation record](dev/shared-client-validation-2026-09-14.md).

**Stream Controls** also provides **Show statistics** and **Detail** controls for the current stream. These changes do not alter your saved preferences. While controls are open, game input is paused. With VoiceOver, visible statistics expose their labels and values as individual elements.

Disconnecting returns to the library and leaves the application running on your computer. Moving the app into the background ends the local stream. After a network or audio interruption, reconnect when the computer and device are ready.

HEVC and AV1 availability depends on the computer and the device's hardware. A simulator cannot establish hardware decoding support or physical device streaming performance.

## HDR and audio

In **Settings → Video**, **HDR** offers **Automatic**, **On**, and **Off**. Automatic negotiates HDR only when the computer, selected codec, and owning display support it. On requires compatible HDR support and reports an error if it is unavailable. Off requests standard dynamic range and remains the default for an existing installation without an HDR preference. Enable HDR on the computer before connecting. The Metal surface uses the shared HDR renderer and Apple's display tone mapping; display brightness and available HDR headroom remain system controlled.

In **Settings → Audio**, choose **Stereo**, **5.1**, or **7.1** separately from **Direct** or **System Spatial Audio**. Stereo uses Direct. Direct uses the output's available channels and downmixes when needed. For System Spatial Audio, select 5.1 or 7.1, configure the host/game for surround speakers, and use a compatible output such as supported AirPods. In Control Center, touch and hold the volume control to select available spatial playback options. The operating system controls head tracking. Stream Controls reports whether spatial playback is available on the current output; that capability is not proof that head tracking is active.

Audio and HDR settings apply to the next stream. System Spatial Audio uses additional audio buffering. A real audio-output change ends the local stream so sound does not unexpectedly continue through another device; reconnect after selecting the intended output.

Swiftlight declares Game Mode support. iOS/iPadOS decides when to activate it; a plist declaration alone does not establish activation.

## Performance and statistics settings

In **Settings → Performance**, **Frame pacing** offers **On decoded frame** (the default), which responds to newly decoded video, and **Display paced**, which follows screen refresh timing, including ProMotion. **Drawable buffers** offers **3 (default)** or **2**. These choices apply to the next stream. Neither option is a measured performance recommendation for your device; compare playback smoothness and timing on the same device and stream before choosing.

iPhone and iPad do not provide the Mac's separate VSync switch: the underlying `CAMetalLayer.displaySyncEnabled` control is unavailable on iOS/iPadOS. **On decoded frame** does not disable display synchronization.

Statistics start hidden by default. In **Settings → Stream Statistics**, choose **Show statistics by default**, **Detail**, and **Position**, then tap **Save** to use those choices for subsequent streams. **Cancel** discards all settings edits. A three-finger tap or an in-stream control changes only the current stream; the next stream uses the saved default again. See [Stream statistics](stream-statistics.md) for panel contents and measurement limits.

## Build and run

Open `Swiftlight.xcodeproj` and select **Swiftlight**. Prepare native dependencies for the intended destination before building:

```sh
# iPhone and iPad simulators
scripts/bootstrap-dependencies.sh --platform ios-simulator

# Physical iPhone and iPad devices and archives
scripts/bootstrap-dependencies.sh --platform ios
```

Choose an installed iPhone simulator, then an installed iPad simulator, and use **Product → Run** for each. For a physical device, choose your development team in Signing & Capabilities and select the connected device. Keep the same **Swiftlight** scheme when switching to **My Mac**. The app product is `Swiftlight.app` on every destination; the iOS build retains bundle identifier `net.edrisil.swiftlight.ios` and `App/Mobile-Info.plist`. Mac retains `net.edrisil.swiftlight` and `App/Info.plist`. Credentials and saved computers remain in their existing platform app storage and Keychain.

The shared **Swiftlight** scheme includes `SwiftlightUITests` for iPhone and iPad destinations. **Product → Test** exercises address rejection and cancellation, settings cancellation and persistence, and navigation with rotation and large text. A library check also inspects the grid in portrait, landscape, and accessibility text when a saved, paired computer is reachable and has at least two applications; it skips when those prerequisites are unavailable. Tests retain screenshots of the affected flows. Run the suite on both iPhone and iPad destinations, choosing light and dark appearance in Simulator for visual checks.

The native iOS adapter sources live in `Sources/mobile/`, alongside `Sources/desktop/`, `Sources/shared/` and the reserved `Sources/tv/` folder. The synchronized mobile folder belongs to the same app target; common app behavior lives in `Sources/shared/SwiftlightApp/`. Earlier validation reports retain the target and scheme names used for those runs. Follow the [current shared-app validation record](dev/shared-client-validation-2026-09-14.md) for evidence after target unification.

Live checks are opt-in. Prefix an `xcodebuild test` command with `TEST_RUNNER_SWIFTLIGHT_LIVE_UI_TESTS=1` to enable the gesture and remote-confirmation tests. They require a saved, paired, reachable host with an application already running. The gesture test resumes that application, toggles statistics, and disconnects locally; the confirmation test cancels both destructive prompts. Neither test confirms a remote quit or launches a different host application.

See [Xcode Cloud](dev/xcode-cloud.md) for simulator workflows, signed device archives, ad-hoc delivery, and TestFlight/release setup.

## Current scope and remaining validation

The mobile MVP includes real discovery, nonsecret saved-computer persistence, Keychain-backed identity and certificate pins, standard PIN pairing, authenticated application browsing with cover artwork, saved stream preferences, and the first full-screen streaming adapter. Bonjour is stopped in the background, cancelled host requests cannot publish into a newer selection, and input is released when the app loses focus or disconnects. Artwork requests pause during streaming and background work, and host changes clear the artwork cache.

Apollo OTP-link entry, on-screen gamepad controls, general hardware keyboard forwarding, and diagnostic export UI are not part of this mobile delivery. The keyboard shortcuts above control Swiftlight itself; they do not establish general keyboard input support for host applications.

The [September 14 physical iPad checks](dev/mobile-stream-controls-2026-09-14.md) verified live statistics show/hide, local edge-swipe disconnect, settings persistence, and remote-quit confirmations. Physical iPhone streaming, audio/controller routes, interruption recovery, manual accessibility acceptance, and matched frame-to-display measurements remain separate checks. Compilation and simulator UI tests do not establish those results. Do not interpret the deployment target as evidence that iOS/iPadOS 27 was built or tested: that requires an installed, compatible Xcode SDK and runtime.

## Apple design guidance

Reviewed on September 13–14, 2026, using Apple's current HIG and DocC content:

- [Designing for iOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ios) and [designing for iPadOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ipados): touch-accessible actions, system appearance, Dynamic Type, and window-size adaptation.
- [Split views](https://developer.apple.com/design/human-interface-guidelines/split-views) and [NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview): computer/library hierarchy in regular widths and standard stack navigation in compact widths.
- [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets), [sheet presentation](https://developer.apple.com/documentation/swiftui/view/sheet(ispresented:ondismiss:content:)), and [presentation sizing](https://developer.apple.com/documentation/swiftui/view/presentationsizing(_:)): focused native forms, leading Cancel, trailing Add/Save, and iPad form sizing.
- [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility): semantic colors and typography, comfortably sized touch controls, labels and hints, and an alternative VoiceOver action for stream controls.
- [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons), [lists](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables), and [toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars): Add Host is a native text button beneath My Computers with a full-row touch target; Settings uses the recognizable gear in the top toolbar.
- [Collections](https://developer.apple.com/design/human-interface-guidelines/collections): consistent cover proportions, adaptive columns, and persistent game names make the library browsable by touch without relying on hover.
- [Context menus](https://developer.apple.com/design/human-interface-guidelines/context-menus) and [action sheets](https://developer.apple.com/design/human-interface-guidelines/action-sheets): the running application's menu offers a destructive quit action, followed by a confirmation that explains the consequence and provides Cancel.
- [Gestures](https://developer.apple.com/design/human-interface-guidelines/gestures) and [going full screen](https://developer.apple.com/design/human-interface-guidelines/going-full-screen): stream gestures have discoverable instructions and alternative controls; immersive video hides system chrome while keeping controls reachable. The operating system retains control of system gestures and windowed presentation.
- [Game Mode declaration](https://developer.apple.com/documentation/bundleresources/information-property-list/lssupportsgamemode): declare support while leaving activation to the operating system.
- [EDR layer metadata](https://developer.apple.com/documentation/quartzcore/cametallayer/edrmetadata) and [extended-range content](https://developer.apple.com/documentation/quartzcore/cametallayer/wantsextendeddynamicrangecontent): enable extended-linear output and configure tone-mapping metadata before acquiring the drawable.
- [Multichannel content](https://developer.apple.com/documentation/avfaudio/avaudiosession/setsupportsmultichannelcontent(_:)) and [spatial playback capability changes](https://developer.apple.com/documentation/avfaudio/avaudiosession/spatialplaybackcapabilitieschangednotification): separate the requested audio layout from actual output capabilities and system spatial preferences.
- [Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators): connection feedback and Cancel remain available while waiting for the first decoded video frame; this transient UI is removed when streaming starts.

These design choices follow the reviewed guidance. Full accessibility acceptance still requires testing VoiceOver, Full Keyboard Access, contrast/transparency preferences, and relevant physical-device flows; screenshots alone do not establish it.
