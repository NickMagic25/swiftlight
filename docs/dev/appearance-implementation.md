# Appearance and application covers

Swiftlight uses native SwiftUI navigation, forms, menus, buttons and accessibility semantics, with a shared glass treatment for custom controls and floating surfaces. Cover artwork and streamed video remain the primary content. This follows Apple's distinction between content and the controls above it in the [Materials Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/materials).

## Shared glass and accessibility

[GlassStyle.swift](../../Sources/SwiftlightApp/GlassStyle.swift) provides the common surface, button and artwork-highlight modifiers used by library actions, pairing, settings actions, connection status, stream controls and statistics. On macOS 26 and later, custom surfaces use genuine SwiftUI `glassEffect`; buttons use `.glass` or `.glassProminent`. Hovered or focused artwork uses a clear glass highlight with an accent outline, while labels and floating controls use regular glass. Standard system toolbars and form controls retain their native behavior. Apple's [custom Liquid Glass guide](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views) and [GlassProminentButtonStyle documentation](https://developer.apple.com/documentation/swiftui/glassprominentbuttonstyle) describe the APIs used.

Earlier supported macOS versions use `.regularMaterial` for custom surfaces and bordered/bordered-prominent buttons. Reduce Transparency selects an opaque semantic background, bordered buttons and an opaque artwork outline. Increased Contrast strengthens surface and selection outlines. Reduce Motion disables Swiftlight's animated cover transitions and press scaling, and disables interactive custom glass effects. Labels, help text and explicit Launch/Resume accessibility names remain available independently of the artwork.

The availability checks also name iOS 26 and tvOS 26, allowing the same SwiftUI styling policy to be reused by future Apple-platform adapters. These guards include later OS versions without relying on an OS 27-only API. They do not establish a completed iOS, iPadOS or tvOS app: the current application adapter remains macOS-specific.

## Library covers and actions

The library requests real cover bytes from the selected paired host through the authenticated HTTPS `appasset` contract described in [host artwork](host-artwork-protocol.md). An adaptive grid displays covers in a 3:4 portrait frame, cropping with fill and clipping to rounded corners. The active hover or keyboard-focus state reveals the app title and Play or Resume action. An already-running app also has a persistent Resume badge. Each cover is a button; selecting it uses the existing launch/resume flow. Missing or rejected artwork leaves a titled system-symbol fallback usable.

The app follows Moonlight Qt's [placeholder-dimension heuristic](https://github.com/moonlight-stream/moonlight-qt/blob/d127908564e53e7888fa691f5e0004a1d75cef75/app/gui/AppView.qml#L97): original images sized 130 × 180, 628 × 888 or 200 × 266 are treated as placeholders. This is a compatibility heuristic, not image-content recognition. Swiftlight's app model lacks Qt's app-collector flag, so its exemption cannot be reproduced; genuine covers with those dimensions may be replaced by the titled fallback.

## Artwork resource limits

[AppArtworkStore.swift](../../Sources/SwiftlightApp/AppArtworkStore.swift) keeps a memory-only, host-scoped cache. At most four requests/decodes are active, including cancelled work until it actually finishes. ImageIO thumbnail decoding runs off the main actor and limits the long edge to 512 pixels. Least-recently-used images are evicted when either 128 entries or 64 MiB of decoded pixel storage is exceeded. Encoded cover bytes are not persisted to disk.

The store also bounds pending identifiers and retry records. Failed covers do not start an automatic retry loop. Host changes clear cached images and retire the previous generation; unpairing, removal and trust changes cancel and invalidate pending work. A late result from an earlier host cannot replace the selected host's artwork. The host and UI layers independently enforce the encoded-byte and image-dimension limits documented in [host artwork](host-artwork-protocol.md).

## Validation scope

The integrated Swift suite passed 69 tests (44 XCTest and 25 host tests), and the application built and signed on arm64 macOS 26.6.2. Thirteen additional deterministic cache checks passed with `python3 scripts/validate-artwork-store.py`, including cancellation across host switches, stale-image rejection, cache accounting, retry bounds and thumbnail decoding. This is the only OS/environment validated for this implementation so far. Automated tests and host protocol/image fixtures do not establish visual quality, real-host cover availability or live keyboard/focus behavior. Live appearance QA is blocked by a protected Keychain read followed by the Mac locking; see the [design QA record](../../design-qa.md). Older-OS and accessibility fallbacks, additional displays, and future Apple-platform adapters also require their own checks.

See [manual validation](manual-validation.md), [stream statistics](stream-statistics-implementation.md), [stream presentation](../stream-presentation.md) and the [acceptance matrix](acceptance-matrix.md) for the broader behavior and remaining gates.
