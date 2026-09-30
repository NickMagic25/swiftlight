# Appearance and application covers

Swiftlight uses native SwiftUI navigation, forms, menus, buttons and accessibility semantics, with a shared glass treatment for custom controls and floating surfaces. Cover artwork and streamed video remain the primary content. This follows Apple's distinction between content and the controls above it in the [Materials Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/materials).

## Shared glass and accessibility

[GlassStyle.swift](../../Sources/shared/SwiftlightApp/GlassStyle.swift) provides the common surface, button and artwork-highlight modifiers used by library actions, pairing, settings actions, connection status, stream controls and statistics. On macOS 26 and later, custom surfaces use genuine SwiftUI `glassEffect`; buttons use `.glass` or `.glassProminent`. Hovered or focused artwork uses a clear glass highlight with an accent outline, while labels and floating controls use regular glass. Standard system toolbars and form controls retain their native behavior. Apple's [custom Liquid Glass guide](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views) and [GlassProminentButtonStyle documentation](https://developer.apple.com/documentation/swiftui/glassprominentbuttonstyle) describe the APIs used.

Earlier supported macOS versions use `.regularMaterial` for custom surfaces and bordered/bordered-prominent buttons. Reduce Transparency selects an opaque semantic background, bordered buttons and an opaque artwork outline. Increased Contrast strengthens surface and selection outlines. Reduce Motion disables Swiftlight's animated cover transitions and press scaling, and disables interactive custom glass effects. Labels, help text and explicit Launch/Resume accessibility names remain available independently of the artwork.

The single `Swiftlight` app target compiles this shared styling implementation for Mac, iPhone and iPad destinations. Its iOS 26 availability branches apply to the implemented iPhone/iPad experience. The guards include later OS versions without relying on an OS 27-only API, but actual OS 27 validation still requires its SDK/runtime. The tvOS branch does not establish a TV app; the app target has no tvOS destination.

## Library covers and actions

The library requests real cover bytes from the selected paired host through the authenticated HTTPS `appasset` contract described in [host artwork](host-artwork-protocol.md). An adaptive grid displays covers in a 3:4 portrait frame, cropping with fill and clipping to rounded corners. On Mac, active hover or keyboard focus reveals the app title and Play or Resume action. Mobile keeps titles beneath covers and uses a single column at accessibility text sizes. An already-running app also has a persistent Resume badge. Each cover is a button; selecting it uses the existing launch/resume flow. Missing or rejected artwork leaves a titled system-symbol fallback usable. Right-click on Mac or touch and hold on mobile to access the running app's separately confirmed Quit Remote Application action.

The app follows Moonlight Qt's [placeholder-dimension heuristic](https://github.com/moonlight-stream/moonlight-qt/blob/d127908564e53e7888fa691f5e0004a1d75cef75/app/gui/AppView.qml#L97): original images sized 130 × 180, 628 × 888 or 200 × 266 are treated as placeholders. This is a compatibility heuristic, not image-content recognition. Swiftlight's app model lacks Qt's app-collector flag, so its exemption cannot be reproduced; genuine covers with those dimensions may be replaced by the titled fallback.

## Artwork resource limits

[AppArtworkStore.swift](../../Sources/shared/SwiftlightApp/AppArtworkStore.swift) keeps a memory-only, host-scoped cache. At most four requests/decodes are active, including cancelled work until it actually finishes. ImageIO thumbnail decoding runs off the main actor and limits the long edge to 512 pixels. Least-recently-used images are evicted when either 128 entries or 64 MiB of decoded pixel storage is exceeded. Encoded cover bytes are not persisted to disk.

The store also bounds pending identifiers and retry records. Failed covers do not start an automatic retry loop. Host changes clear cached images and retire the previous generation; unpairing, removal and trust changes cancel and invalidate pending work. A late result from an earlier host cannot replace the selected host's artwork. The host and UI layers independently enforce the encoded-byte and image-dimension limits documented in [host artwork](host-artwork-protocol.md).

## Validation scope

The initial Mac implementation record reported 69 Swift tests (44 XCTest and 25 host tests), a signed arm64 macOS 26.6.2 build, and 13 deterministic cache checks covering cancellation across host switches, stale-image rejection, cache accounting, retry bounds and thumbnail decoding. Its live appearance QA was blocked by a protected Keychain read followed by the Mac locking; see the historical [design QA record](../../design-qa.md). Those results describe that run. Later mobile coverage and remaining physical limits are recorded in the [mobile guide](../mobile.md). Automated tests and host protocol/image fixtures do not establish visual quality, real-host cover availability or live keyboard/focus behavior. Older-OS/accessibility fallbacks and additional displays require their own checks.

See [manual validation](manual-validation.md), [stream statistics](stream-statistics-implementation.md), [stream presentation](../stream-presentation.md) and the [acceptance matrix](acceptance-matrix.md) for the broader behavior and remaining gates.
