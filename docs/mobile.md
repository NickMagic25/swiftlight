# iPhone and iPad MVP

The `SwiftlightMobile` Xcode scheme builds one universal app for iPhone and iPad, with iOS/iPadOS 26 as its minimum version. It shares host trust, settings, transport, audio, the MoonlightAppleVideo decoder, and the Metal renderer with the Mac client. The mobile experience is under development and does not yet provide all Mac features.

## Connect and play

1. Allow Local Network access when prompted. Use the same network as a computer running Sunshine or Apollo.
2. Choose a nearby computer, or tap **Add Host** beneath **My Computers** to enter its hostname or IP address. Custom HTTP ports and bracketed IPv6 addresses are supported.
3. Select **Pair Computer** and enter the displayed PIN in Sunshine or Apollo. The application library loads after the computer authenticates successfully.
4. Open **Settings** using the gear at the top right to choose resolution, frame rate, codec, picture size, and bitrate. **Save** applies your choices to the next stream; **Cancel** discards edits.
5. Tap an application to start streaming. Tap a running application to resume it. If a different application is already running, quit it on the computer before starting another.

On iPhone and at narrow iPad window sizes, the computer list opens the selected computer's library in a navigation stack. On a wider iPad window, the computer list and library appear side by side. Forms, controls, and text adapt to the window, orientation, appearance, and system text size.

The library displays a grid of cover art from your computer, with each game's name beneath its cover. The number of columns adapts to the available width; accessibility text sizes use one column with wrapping titles. Applications without usable artwork show a placeholder and remain playable. **Add Host** uses the same blue semibold text as the game titles.

## Stream controls

Touch the video to move the pointer and tap to click. A connected physical game controller can provide game input. Tap with three fingers to open **Stream Controls**; with VoiceOver, use the stream's **Stream Controls** custom action. A physical keyboard can also open controls with **Command–Escape**.

Stream controls are hidden initially. Disconnecting returns to the library and leaves the application running on your computer. Moving the app into the background ends the local stream. After a network or audio interruption, reconnect when the computer and device are ready.

The MVP requests standard dynamic range video and stereo audio. HEVC and AV1 availability depends on the computer and the device's hardware. A simulator cannot establish hardware decoding support or physical device streaming performance.

## Build and run

Open `Swiftlight.xcodeproj` and select **SwiftlightMobile**. Prepare native dependencies for the intended destination before building:

```sh
# iPhone and iPad simulators
scripts/bootstrap-dependencies.sh --platform ios-simulator

# Physical iPhone and iPad devices and archives
scripts/bootstrap-dependencies.sh --platform ios
```

Choose an installed iPhone simulator, then an installed iPad simulator, and use **Product → Run** for each. For a physical device, choose your development team in Signing & Capabilities and select the connected device. The mobile target's bundle identifier is `net.edrisil.swiftlight.ios`; credentials and saved computers remain in that app's storage and Keychain.

The shared mobile scheme includes `SwiftlightMobileUITests`. **Product → Test** exercises address rejection and cancellation, settings cancellation and persistence, and navigation with rotation and large text. A library check also inspects the grid in portrait, landscape, and accessibility text when a saved, paired computer is reachable and has at least two applications; it skips when those prerequisites are unavailable. Tests retain screenshots of the affected flows. Run the suite on both iPhone and iPad destinations, choosing light and dark appearance in Simulator for visual checks. These UI tests do not launch a host application or validate a live stream.

See [Xcode Cloud](dev/xcode-cloud.md) for simulator workflows, signed device archives, ad-hoc delivery, and TestFlight/release setup.

## Current scope and remaining validation

The mobile MVP includes real discovery, nonsecret saved-computer persistence, Keychain-backed identity and certificate pins, standard PIN pairing, authenticated application browsing with cover artwork, saved stream preferences, and the first full-screen streaming adapter. Bonjour is stopped in the background, cancelled host requests cannot publish into a newer selection, and input is released when the app loses focus or disconnects. Artwork requests pause during streaming and background work, and host changes clear the artwork cache.

Apollo OTP-link entry, remote application quitting, on-screen gamepad controls, general hardware keyboard forwarding, HDR, surround/spatial audio options, and the Mac statistics and diagnostic export UI are not part of this mobile delivery.

Compilation and simulator UI checks do not establish successful live video presentation, audio playback, touch/controller input, background recovery, or latency on a physical iPhone or iPad. Those require a suitable paired host and physical devices. Confirm each independently before describing a build as accepted for device streaming. Do not interpret the deployment target as evidence that iOS/iPadOS 27 was built or tested: that requires an installed, compatible Xcode SDK and runtime.

## Apple design guidance

Reviewed on September 13–14, 2026, using Apple's current HIG and DocC content:

- [Designing for iOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ios) and [designing for iPadOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ipados): touch-accessible actions, system appearance, Dynamic Type, and window-size adaptation.
- [Split views](https://developer.apple.com/design/human-interface-guidelines/split-views) and [NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview): computer/library hierarchy in regular widths and standard stack navigation in compact widths.
- [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets), [sheet presentation](https://developer.apple.com/documentation/swiftui/view/sheet(ispresented:ondismiss:content:)), and [presentation sizing](https://developer.apple.com/documentation/swiftui/view/presentationsizing(_:)): focused native forms, leading Cancel, trailing Add/Save, and iPad form sizing.
- [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility): semantic colors and typography, comfortably sized touch controls, labels and hints, and an alternative VoiceOver action for stream controls.
- [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons), [lists](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables), and [toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars): Add Host is a native text button beneath My Computers with a full-row touch target; Settings uses the recognizable gear in the top toolbar.
- [Collections](https://developer.apple.com/design/human-interface-guidelines/collections): consistent cover proportions, adaptive columns, and persistent game names make the library browsable by touch without relying on hover.
- [Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators): connection feedback and Cancel remain available while waiting for the first decoded video frame; this transient UI is removed when streaming starts.

These design choices follow the reviewed guidance. Full accessibility acceptance still requires testing VoiceOver, Full Keyboard Access, contrast/transparency preferences, and relevant physical-device flows; screenshots alone do not establish it.
